public without sharing class IntegrationScheduleDispatcher {
  public static final Integer MAX_DISPATCH_SIZE = 20;
  public static final Integer LEASE_MINUTES = 10;
  private static Map<String, String> connectorKeyByAlias;

  public static Integer dispatchDue() {
    Integer available = Limits.getLimitQueueableJobs() - Limits.getQueueableJobs();
    return dispatchDue(Math.min(MAX_DISPATCH_SIZE, available));
  }

  public static Integer dispatchDue(Integer availableCapacity) {
    if (availableCapacity == null || availableCapacity <= 0) {
      return 0;
    }
    Integer dispatchSize = Math.min(MAX_DISPATCH_SIZE, availableCapacity);
    Datetime nowValue = System.now();
    List<Scheduled_Integration_Job__c> dueJobs = [
      SELECT
        Id,
        Status__c,
        Integration_Type__c,
        Source_Object__c,
        Direction__c,
        Lease_Token__c,
        Lease_Expires_At__c,
        Next_Run_At__c
      FROM Scheduled_Integration_Job__c
      WHERE
        (Status__c IN ('Ready', 'Active', 'Failed')
        AND (Next_Run_At__c = NULL OR Next_Run_At__c <= :nowValue))
        OR (Status__c IN ('Claimed', 'Running')
        AND Lease_Expires_At__c < :nowValue)
      LIMIT :dispatchSize
      FOR UPDATE
    ];
    if (dueJobs.isEmpty()) {
      return 0;
    }

    Set<String> resourceKeys=new Set<String>();
    for(Integration_Operation__mdt operation:[SELECT Connector_Key__c,Resource_Contract_JSON__c FROM Integration_Operation__mdt WHERE Active__c=true]) {
      if(String.isNotBlank(operation.Resource_Contract_JSON__c)) resourceKeys.add(operation.Connector_Key__c.toLowerCase());
    }
    Set<String> activeResources=ConnectorConfigService.activeConnectorKeys(resourceKeys);
    List<Scheduled_Integration_Job__c> enabledJobs=new List<Scheduled_Integration_Job__c>();
    for(Scheduled_Integration_Job__c job:dueJobs) {
      String key=normalizeConnector(job.Integration_Type__c);
      if(!resourceKeys.contains(key) || activeResources.contains(key)) enabledJobs.add(job);
    }
    dueJobs=enabledJobs;
    if(dueJobs.isEmpty()) return 0;

    for (Scheduled_Integration_Job__c job : dueJobs) {
      job.Status__c = 'Claimed';
      job.Lease_Token__c = newLeaseToken(job.Id);
      job.Lease_Expires_At__c = leaseExpiresAt(nowValue);
      job.Last_Claimed_At__c = nowValue;
      job.Last_Error__c = null;
    }
    Database.SaveResult[] claimResults = Database.update(dueJobs, false);

    List<Scheduled_Integration_Job__c> updates =
      new List<Scheduled_Integration_Job__c>();
    Integer enqueued = 0;
    for (Integer index = 0; index < dueJobs.size(); index++) {
      if (!claimResults[index].isSuccess()) {
        continue;
      }
      Scheduled_Integration_Job__c job = dueJobs[index];
      try {
        Id processorId = System.enqueueJob(
          new IntegrationScheduleProcessor(job.Id, job.Lease_Token__c)
        );
        job.Processor_Job_Id__c = String.valueOf(processorId);
        updates.add(job);
        enqueued++;
      } catch (Exception enqueueException) {
        job.Status__c = 'Ready';
        job.Lease_Token__c = null;
        job.Lease_Expires_At__c = null;
        job.Processor_Job_Id__c = null;
        job.Next_Run_At__c = nowValue.addMinutes(1);
        job.Last_Error__c = safeError(
          'Unable to enqueue scheduled integration: ' + enqueueException.getMessage()
        );
        updates.add(job);
      }
    }
    if (!updates.isEmpty()) {
      Database.update(updates, false);
    }
    return enqueued;
  }

  public static Datetime leaseExpiresAt(Datetime baseTime) {
    return (baseTime == null ? System.now() : baseTime).addMinutes(LEASE_MINUTES);
  }

  public static void completeRun(
    Id scheduleId,
    String leaseToken,
    Boolean success,
    String errorMessage
  ) {
    if (scheduleId == null || String.isBlank(leaseToken)) {
      return;
    }
    List<Scheduled_Integration_Job__c> rows = [
      SELECT
        Id,
        Status__c,
        Lease_Token__c,
        Frequency_Value__c,
        Frequency_Type__c,
        Integration_Type__c
      FROM Scheduled_Integration_Job__c
      WHERE Id = :scheduleId
      LIMIT 1
      FOR UPDATE
    ];
    if (rows.isEmpty()) {
      return;
    }
    Scheduled_Integration_Job__c job = rows[0];
    if (
      !new Set<String>{ 'Claimed', 'Running' }.contains(job.Status__c) ||
      job.Lease_Token__c != leaseToken
    ) {
      return;
    }
    Datetime nowValue = System.now();
    job.Lease_Token__c = null;
    job.Lease_Expires_At__c = null;
    job.Processor_Job_Id__c = null;
    job.Last_Run_At__c = nowValue;
    if (success == true) {
      job.Status__c = 'Active';
      job.Last_Dispatched_At__c = nowValue;
      job.Last_Error__c = null;
      job.Next_Run_At__c = calculateNextRun(
        job.Frequency_Value__c,
        job.Frequency_Type__c,
        nowValue
      );
      ConnectorConfigService.updateHealth(
        normalizeConnector(job.Integration_Type__c),
        'Ready'
      );
    } else {
      job.Status__c = 'Failed';
      job.Last_Error__c = safeError(errorMessage);
      job.Next_Run_At__c = calculateNextRun(
        job.Frequency_Value__c,
        job.Frequency_Type__c,
        nowValue
      );
      ConnectorConfigService.updateHealth(
        normalizeConnector(job.Integration_Type__c),
        'Unavailable'
      );
    }
    Database.update(job, false);
  }

  public static Datetime calculateNextRun(
    Decimal frequencyValue,
    String frequencyType,
    Datetime baseTime
  ) {
    Integer amount = frequencyValue == null
      ? 1
      : Math.max(1, frequencyValue.intValue());
    Datetime baseValue = baseTime == null ? System.now() : baseTime;
    if (frequencyType == 'Minutes') return baseValue.addMinutes(amount);
    if (frequencyType == 'Hours') return baseValue.addHours(amount);
    if (frequencyType == 'Days') return baseValue.addDays(amount);
    if (frequencyType == 'Weeks') return baseValue.addDays(amount * 7);
    if (frequencyType == 'Months') return baseValue.addMonths(amount);
    return baseValue.addHours(amount);
  }

  public static String normalizeConnector(String integrationType) {
    String normalized = String.isBlank(integrationType)
      ? ''
      : integrationType.trim().toLowerCase();
    if (connectorKeyByAlias == null) {
      connectorKeyByAlias = new Map<String, String>();
      for (Integration_Connector__mdt connector : [
        SELECT Connector_Key__c, Integration_Type__c, Aliases__c
        FROM Integration_Connector__mdt
        WHERE Enabled__c = true
      ]) {
        String connectorKey = normalizeToken(connector.Connector_Key__c);
        connectorKeyByAlias.put(connectorKey, connectorKey);
        connectorKeyByAlias.put(
          normalizeToken(connector.Integration_Type__c),
          connectorKey
        );
        for (String aliasValue : aliases(connector.Aliases__c)) {
          connectorKeyByAlias.put(aliasValue, connectorKey);
        }
      }
    }
    return connectorKeyByAlias.containsKey(normalized)
      ? connectorKeyByAlias.get(normalized)
      : normalizeToken(normalized);
  }

  private static Set<String> aliases(String csvValue) {
    Set<String> result = new Set<String>();
    if (String.isBlank(csvValue)) return result;
    for (String aliasValue : csvValue.split(',')) {
      result.add(normalizeToken(aliasValue));
    }
    return result;
  }

  private static String normalizeToken(String value) {
    return String.isBlank(value) ? '' : value.trim().toLowerCase();
  }

  private static String newLeaseToken(Id scheduleId) {
    String seed = String.valueOf(scheduleId) +
      ':' +
      UserInfo.getOrganizationId() +
      ':' +
      String.valueOf(System.now().getTime()) +
      ':' +
      String.valueOf(Crypto.getRandomInteger());
    return EncodingUtil.convertToHex(
      Crypto.generateDigest('SHA-256', Blob.valueOf(seed))
    );
  }

  private static String safeError(String message) {
    return String.isBlank(message)
      ? 'Scheduled integration failed.'
      : message.left(32768);
  }
}