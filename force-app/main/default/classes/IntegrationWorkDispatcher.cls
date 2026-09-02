public without sharing class IntegrationWorkDispatcher {
  private static final Integer DEFAULT_DISPATCH_LIMIT = 20;
  private static final Integer LEASE_MINUTES = 10;

  public static Integer dispatchDueWork() {
    Integer available = Limits.getLimitQueueableJobs() - Limits.getQueueableJobs();
    return dispatchDueWork(Math.min(DEFAULT_DISPATCH_LIMIT, available));
  }

  public static Integer dispatchDueWork(Integer availableCapacity) {
    if (availableCapacity == null || availableCapacity <= 0) {
      return 0;
    }
    Integer dispatchLimit = Math.min(DEFAULT_DISPATCH_LIMIT, availableCapacity);
    Datetime nowValue = System.now();
    List<Integration_Work_Item__c> candidates = [
      SELECT
        Id,
        Status__c,
        Lock_Key__c,
        Attempt_Count__c,
        Max_Attempts__c,
        Processor_Token__c,
        Lease_Expires_At__c
      FROM Integration_Work_Item__c
      WHERE
        (Status__c IN ('Pending', 'Retry')
        AND (Next_Attempt_At__c = NULL OR Next_Attempt_At__c <= :nowValue))
        OR (Status__c = 'Processing' AND Lease_Expires_At__c < :nowValue)
      LIMIT :dispatchLimit
      FOR UPDATE
    ];
    if (candidates.isEmpty()) {
      return 0;
    }

    for (Integration_Work_Item__c row : candidates) {
      row.Status__c = IntegrationWorkService.STATUS_PROCESSING;
      row.Processor_Token__c = leaseToken(row.Id);
      row.Lease_Expires_At__c = nowValue.addMinutes(LEASE_MINUTES);
      row.Processing_Started_At__c = nowValue;
      row.Last_Attempt_At__c = nowValue;
      Decimal attempts = row.Attempt_Count__c == null ? 0 : row.Attempt_Count__c;
      row.Attempt_Count__c = attempts + 1;
      row.Last_Error__c = null;
    }
    Database.SaveResult[] claimResults = Database.update(candidates, false);

    List<Integration_Work_Item__c> claimed = new List<Integration_Work_Item__c>();
    for (Integer index = 0; index < candidates.size(); index++) {
      if (claimResults[index].isSuccess()) {
        claimed.add(candidates[index]);
      }
    }
    createOrRenewLocks(claimed, nowValue);

    List<Integration_Work_Item__c> processorUpdates =
      new List<Integration_Work_Item__c>();
    Integer enqueued = 0;
    for (Integration_Work_Item__c row : claimed) {
      try {
        Id jobId = System.enqueueJob(
          new IntegrationWorkProcessor(row.Id, row.Processor_Token__c)
        );
        row.Processor_Job_Id__c = String.valueOf(jobId);
        processorUpdates.add(row);
        enqueued++;
      } catch (Exception enqueueException) {
        row.Status__c = IntegrationWorkService.STATUS_RETRY;
        row.Next_Attempt_At__c = nowValue.addMinutes(1);
        row.Last_Error__c = safeMessage(enqueueException.getMessage());
        row.Processor_Token__c = null;
        row.Lease_Expires_At__c = null;
        processorUpdates.add(row);
      }
    }
    if (!processorUpdates.isEmpty()) {
      Database.update(processorUpdates, false);
    }
    return enqueued;
  }

  private static void createOrRenewLocks(
    List<Integration_Work_Item__c> items,
    Datetime nowValue
  ) {
    List<Integration_Work_Lock__c> locks = new List<Integration_Work_Lock__c>();
    for (Integration_Work_Item__c item : items) {
      String lockKey = String.isBlank(item.Lock_Key__c)
        ? String.valueOf(item.Id)
        : item.Lock_Key__c;
      locks.add(
        new Integration_Work_Lock__c(
          Name = lockKey.left(80),
          Lock_Key__c = lockKey.left(255),
          Work_Item__c = item.Id,
          Status__c = 'Locked',
          Processor_Token__c = item.Processor_Token__c,
          Lease_Expires_At__c = nowValue.addMinutes(LEASE_MINUTES)
        )
      );
    }
    if (!locks.isEmpty()) {
      Database.upsert(locks, Integration_Work_Lock__c.Fields.Lock_Key__c, false);
    }
  }

  private static String leaseToken(Id workItemId) {
    String seed = String.valueOf(workItemId) +
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

  private static String safeMessage(String message) {
    return String.isBlank(message)
      ? 'Unable to enqueue integration work.'
      : message.left(131000);
  }
}