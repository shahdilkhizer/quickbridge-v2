public without sharing class IntegrationWorkService {
  public static final String STATUS_PENDING = 'Pending';
  public static final String STATUS_PROCESSING = 'Processing';
  public static final String STATUS_RETRY = 'Retry';
  public static final String STATUS_COMPLETED = 'Completed';
  public static final String STATUS_FAILED = 'Failed';
  public static final Integer DEFAULT_MAX_ATTEMPTS = 5;

  public static List<Id> enqueue(List<IntegrationWorkRequest> requests) {
    if (requests == null || requests.isEmpty()) {
      return new List<Id>();
    }
    Map<String, IntegrationWorkRequest> requestByKey =
      new Map<String, IntegrationWorkRequest>();
    for (IntegrationWorkRequest request : requests) {
      validate(request);
      requestByKey.put(uniqueKey(request), request);
    }

    Map<String, Integration_Work_Item__c> existingByKey =
      new Map<String, Integration_Work_Item__c>();
    for (Integration_Work_Item__c row : [
      SELECT
        Id,
        Unique_Key__c,
        Status__c,
        Coalesced_Count__c,
        Needs_Reprocess__c
      FROM Integration_Work_Item__c
      WHERE Unique_Key__c IN :requestByKey.keySet()
      FOR UPDATE
    ]) {
      existingByKey.put(row.Unique_Key__c, row);
    }

    List<Integration_Work_Item__c> inserts = new List<Integration_Work_Item__c>();
    List<Integration_Work_Item__c> updates = new List<Integration_Work_Item__c>();
    Datetime nowValue = System.now();
    for (String keyValue : requestByKey.keySet()) {
      IntegrationWorkRequest request = requestByKey.get(keyValue);
      Integration_Work_Item__c row = existingByKey.get(keyValue);
      if (row == null) {
        row = new Integration_Work_Item__c(Unique_Key__c = keyValue);
        applyRequest(row, request, nowValue);
        inserts.add(row);
        existingByKey.put(keyValue, row);
      } else {
        Decimal coalescedCount = row.Coalesced_Count__c == null
          ? 0
          : row.Coalesced_Count__c;
        row.Coalesced_Count__c = coalescedCount + 1;
        if (row.Status__c == STATUS_PROCESSING) {
          row.Needs_Reprocess__c = true;
        } else {
          applyRequest(row, request, nowValue);
          row.Status__c = STATUS_PENDING;
          row.Next_Attempt_At__c = nowValue;
          row.Last_Error__c = null;
        }
        updates.add(row);
      }
    }

    if (!inserts.isEmpty()) {
      Database.insert(inserts, false);
    }
    if (!updates.isEmpty()) {
      Database.update(updates, false);
    }

    List<Id> ids = new List<Id>();
    Map<String, Set<Id>> outcomeIdsByContext = new Map<String, Set<Id>>();
    Map<String, IntegrationWorkRequest> sampleByContext =
      new Map<String, IntegrationWorkRequest>();
    for (String keyValue : existingByKey.keySet()) {
      Integration_Work_Item__c row = existingByKey.get(keyValue);
      IntegrationWorkRequest request = requestByKey.get(keyValue);
      if (row.Id != null) {
        ids.add(row.Id);
      }
      if (request.sourceRecordId != null) {
        String contextKey = request.sourceRecordId.getSObjectType().getDescribe().getName() +
          ':' + request.connectorKey.toLowerCase() + ':' + request.operationKey.toLowerCase();
        if (!outcomeIdsByContext.containsKey(contextKey)) {
          outcomeIdsByContext.put(contextKey, new Set<Id>());
          sampleByContext.put(contextKey, request);
        }
        outcomeIdsByContext.get(contextKey).add(request.sourceRecordId);
      }
    }
    for (String contextKey : outcomeIdsByContext.keySet()) {
      Set<Id> recordIds = outcomeIdsByContext.get(contextKey);
      if (!recordIds.isEmpty()) {
        IntegrationWorkRequest sample = sampleByContext.get(contextKey);
        IntegrationOutcomeService.markPending(
          recordIds,
          sample.connectorKey,
          sample.operationKey
        );
      }
    }
    return ids;
  }

  public static void markBatchRunning(Id workItemId, String token, Id batchJobId) {
    if (workItemId == null) {
      return;
    }
    List<Integration_Work_Item__c> rows = [
      SELECT Id, Status__c, Processor_Token__c
      FROM Integration_Work_Item__c
      WHERE Id = :workItemId
      LIMIT 1
      FOR UPDATE
    ];
    if (
      rows.isEmpty() ||
      rows[0].Status__c != STATUS_PROCESSING ||
      rows[0].Processor_Token__c != token
    ) {
      return;
    }
    rows[0].Processor_Job_Id__c = String.valueOf(batchJobId);
    rows[0].Lease_Expires_At__c = System.now().addMinutes(10);
    update rows[0];
  }

  public static void complete(
    Id workItemId,
    ConnectorExecutionRequest request,
    ConnectorExecutionResult result
  ) {
    if (workItemId == null || request == null) {
      return;
    }
    List<Integration_Work_Item__c> rows = [
      SELECT
        Id,
        Status__c,
        Attempt_Count__c,
        Max_Attempts__c,
        Needs_Reprocess__c,
        Source_Salesforce_Id__c
      FROM Integration_Work_Item__c
      WHERE Id = :workItemId
      LIMIT 1
      FOR UPDATE
    ];
    if (rows.isEmpty()) {
      return;
    }
    Integration_Work_Item__c row = rows[0];
    Set<Id> recordIds = new Set<Id>();
    if (request.recordIds != null) {
      recordIds.addAll(request.recordIds);
    }
    if (result != null && !result.hasFailures()) {
      row.Status__c = row.Needs_Reprocess__c == true
        ? STATUS_PENDING
        : STATUS_COMPLETED;
      row.Completed_At__c = System.now();
      row.Last_Error__c = null;
      row.Next_Attempt_At__c = row.Needs_Reprocess__c == true
        ? System.now()
        : null;
      row.Needs_Reprocess__c = false;
      IntegrationOutcomeService.markSuccess(
        recordIds,
        request.connectorKey,
        request.operationKey
      );
      IntegrationErrorLogService.markResolved(workItemId, recordIds);
      ConnectorConfigService.updateHealth(request.connectorKey, 'Ready');
    } else {
      Integer attempts = row.Attempt_Count__c == null
        ? 1
        : row.Attempt_Count__c.intValue();
      Integer maximum = row.Max_Attempts__c == null
        ? DEFAULT_MAX_ATTEMPTS
        : row.Max_Attempts__c.intValue();
      Boolean retry = result != null &&
        result.retryable == true &&
        attempts < maximum;
      row.Status__c = retry ? STATUS_RETRY : STATUS_FAILED;
      row.Last_Error__c = safeError(result);
      row.Next_Attempt_At__c = retry
        ? System.now().addSeconds(retryDelay(result, attempts))
        : null;
      Set<Id> failedRecordIds = result != null &&
        result.retryRecordIds != null &&
        !result.retryRecordIds.isEmpty()
        ? new Set<Id>(result.retryRecordIds)
        : new Set<Id>(recordIds);
      Set<Id> successfulRecordIds = new Set<Id>(recordIds);
      successfulRecordIds.removeAll(failedRecordIds);
      if (!successfulRecordIds.isEmpty()) {
        IntegrationOutcomeService.markSuccess(
          successfulRecordIds,
          request.connectorKey,
          request.operationKey
        );
      }
      IntegrationOutcomeService.markFailure(
        failedRecordIds,
        request.connectorKey,
        request.operationKey
      );
      List<IntegrationErrorLogService.Failure> failures =
        new List<IntegrationErrorLogService.Failure>();
      for (Id recordId : failedRecordIds) {
        IntegrationErrorLogService.Failure failure =
          new IntegrationErrorLogService.Failure();
        failure.workItemId = workItemId;
        failure.recordId = recordId;
        failure.connectorKey = request.connectorKey;
        failure.operationKey = request.operationKey;
        failure.category = String.isBlank(result == null ? null : result.errorCategory)
          ? (retry ? 'Transient Integration Failure' : 'Integration Failure')
          : result.errorCategory;
        failure.message = row.Last_Error__c;
        failure.httpStatusCode = result == null ? null : result.httpStatusCode;
        failure.retryable = retry;
        failure.retryCount = attempts;
        failure.maximumAttempts = maximum;
        failure.dmlOperation = result == null ? null : result.dmlOperation;
        failure.classMethod = String.isBlank(result == null ? null : result.classMethod)
          ? 'IntegrationWorkService.complete'
          : result.classMethod;
        failures.add(failure);
      }
      IntegrationErrorLogService.logFailures(failures);
      ConnectorConfigService.updateHealth(
        request.connectorKey,
        retry ? 'Warning' : 'Unavailable'
      );
    }
    row.Processor_Token__c = null;
    row.Processor_Job_Id__c = null;
    row.Lease_Expires_At__c = null;
    Database.update(row, false);
    releaseLocks(workItemId, row.Status__c);
  }

  public static void manualRetry(Id workItemId) {
    Integration_Work_Item__c row = [
      SELECT Id, Status__c, Source_Salesforce_Id__c, Integration__c, Operation__c
      FROM Integration_Work_Item__c
      WHERE Id = :workItemId
      LIMIT 1
      FOR UPDATE
    ];
    if (row.Status__c != STATUS_FAILED && row.Status__c != STATUS_RETRY) {
      throw new AuraHandledException('Only failed or retrying work can be replayed.');
    }
    row.Status__c = STATUS_PENDING;
    row.Attempt_Count__c = 0;
    row.Next_Attempt_At__c = System.now();
    row.Last_Error__c = null;
    update row;
    if (String.isNotBlank(row.Source_Salesforce_Id__c)) {
      IntegrationOutcomeService.markPending(
        new Set<Id>{ Id.valueOf(row.Source_Salesforce_Id__c) },
        row.Integration__c,
        row.Operation__c
      );
    }
  }

  private static void applyRequest(
    Integration_Work_Item__c row,
    IntegrationWorkRequest request,
    Datetime nowValue
  ) {
    row.Integration__c = request.connectorKey.toLowerCase();
    row.Operation__c = request.operationKey;
    row.Source_Object__c = request.sourceObject;
    row.Source_Record_Id__c = request.sourceRecordId == null
      ? null
      : String.valueOf(request.sourceRecordId);
    row.Source_Salesforce_Id__c = request.sourceRecordId == null
      ? null
      : String.valueOf(request.sourceRecordId);
    row.Source_External_Id__c = request.sourceExternalId;
    row.Payload__c = request.payload;
    row.Payload_Hash__c = payloadHash(request.payload);
    row.Lock_Key__c = String.isBlank(request.lockKey)
      ? row.Unique_Key__c
      : request.lockKey.left(255);
    row.Status__c = STATUS_PENDING;
    row.Attempt_Count__c = 0;
    row.Max_Attempts__c = request.maximumAttempts == null
      ? DEFAULT_MAX_ATTEMPTS
      : Math.max(1, Math.min(10, request.maximumAttempts));
    row.Last_Enqueued_At__c = nowValue;
    row.Last_Dispatch_Requested_At__c = nowValue;
    row.Next_Attempt_At__c = nowValue;
    row.Needs_Reprocess__c = false;
  }

  private static void validate(IntegrationWorkRequest request) {
    if (
      request == null ||
      String.isBlank(request.connectorKey) ||
      String.isBlank(request.operationKey) ||
      String.isBlank(request.sourceObject) ||
      (request.sourceRecordId == null && String.isBlank(request.sourceExternalId))
    ) {
      throw new IntegrationWorkException(
        'Connector, operation, source object, and a source record or external identifier are required.'
      );
    }
    if (
      !Pattern.matches('^[A-Za-z0-9_-]{1,80}$', request.connectorKey) ||
      !Pattern.matches('^[A-Za-z0-9_-]{1,80}$', request.operationKey)
    ) {
      throw new IntegrationWorkException('Connector or operation key is invalid.');
    }
  }

  private static String uniqueKey(IntegrationWorkRequest request) {
    String raw = request.connectorKey.toLowerCase() +
      ':' +
      request.operationKey.toLowerCase() +
      ':' +
      (request.sourceRecordId == null
        ? 'external:' + request.sourceExternalId
        : 'record:' + String.valueOf(request.sourceRecordId));
    return raw.length() <= 255
      ? raw
      : EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(raw)));
  }

  private static String payloadHash(String payload) {
    return String.isBlank(payload)
      ? null
      : EncodingUtil.convertToHex(
          Crypto.generateDigest('SHA-256', Blob.valueOf(payload))
        );
  }

  private static Integer retryDelay(
    ConnectorExecutionResult result,
    Integer attempts
  ) {
    if (result != null && result.retryDelaySeconds != null) {
      return Math.max(1, Math.min(3600, result.retryDelaySeconds));
    }
    Integer exponential = 60 * (Integer) Math.pow(2, Math.max(0, attempts - 1));
    Integer jitter = Math.mod(Math.abs(Crypto.getRandomInteger()), 30);
    return Math.min(3600, exponential + jitter);
  }

  private static String safeError(ConnectorExecutionResult result) {
    String message = result == null ? null : result.errorSummary;
    return String.isBlank(message)
      ? 'Integration processing failed.'
      : message.left(131000);
  }

  private static void releaseLocks(Id workItemId, String finalStatus) {
    List<Integration_Work_Lock__c> locks = [
      SELECT Id
      FROM Integration_Work_Lock__c
      WHERE Work_Item__c = :workItemId
    ];
    for (Integration_Work_Lock__c lockRow : locks) {
      lockRow.Status__c = 'Released';
      lockRow.Processor_Token__c = null;
      lockRow.Processor_Job_Id__c = null;
      lockRow.Lease_Expires_At__c = null;
    }
    if (!locks.isEmpty()) {
      Database.update(locks, false);
    }
  }

  public class IntegrationWorkException extends Exception {}
}