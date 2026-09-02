public without sharing class IntegrationErrorLogService {
  private static final Integer MESSAGE_LIMIT = 131000;
  private static final Integer HISTORY_LIMIT = 131000;

  public class Failure {
    public Id workItemId;
    public Id recordId;
    public String connectorKey;
    public String operationKey;
    public String category;
    public String message;
    public Integer httpStatusCode;
    public Boolean retryable;
    public Integer retryCount;
    public Integer maximumAttempts;
    public String dmlOperation;
    public String classMethod;
  }

  public static void logFailures(List<Failure> failures) {
    if (failures == null || failures.isEmpty()) {
      return;
    }
    Map<String, Failure> byReference = new Map<String, Failure>();
    for (Failure failure : failures) {
      if (failure == null || failure.recordId == null) {
        continue;
      }
      byReference.put(referenceFor(failure), failure);
    }
    if (byReference.isEmpty()) {
      return;
    }

    Map<String, Error_Log__c> existingByReference = new Map<String, Error_Log__c>();
    for (Error_Log__c row : [
      SELECT
        Id,
        External_Reference__c,
        Retry_History_Notes__c
      FROM Error_Log__c
      WHERE External_Reference__c IN :byReference.keySet()
    ]) {
      existingByReference.put(row.External_Reference__c, row);
    }

    List<Error_Log__c> inserts = new List<Error_Log__c>();
    List<Error_Log__c> updates = new List<Error_Log__c>();
    Map<String, Error_Log__c> rowByReference = new Map<String, Error_Log__c>();
    for (String referenceValue : byReference.keySet()) {
      Failure failure = byReference.get(referenceValue);
      Error_Log__c row = existingByReference.get(referenceValue);
      Boolean isInsert = row == null;
      row = isInsert ? new Error_Log__c() : row;
      applyFailure(row, failure, referenceValue);
      rowByReference.put(referenceValue, row);
      if (isInsert) {
        inserts.add(row);
      } else {
        updates.add(row);
      }
    }

    if (!inserts.isEmpty()) {
      Database.insert(inserts, false);
    }
    if (!updates.isEmpty()) {
      Database.update(updates, false);
    }

    Set<Id> errorLogIds = new Set<Id>();
    for (Error_Log__c row : rowByReference.values()) {
      if (row.Id != null) {
        errorLogIds.add(row.Id);
      }
    }
    Set<String> existingLinkKeys = new Set<String>();
    if (!errorLogIds.isEmpty()) {
      for (Error_Log_Link__c link : [
        SELECT Error_Log__c, Linked_Record_Id__c
        FROM Error_Log_Link__c
        WHERE Error_Log__c IN :errorLogIds
      ]) {
        existingLinkKeys.add(
          String.valueOf(link.Error_Log__c) + ':' + link.Linked_Record_Id__c
        );
      }
    }

    List<Error_Log_Link__c> links = new List<Error_Log_Link__c>();
    for (String referenceValue : rowByReference.keySet()) {
      Error_Log__c row = rowByReference.get(referenceValue);
      Failure failure = byReference.get(referenceValue);
      if (row.Id == null) {
        continue;
      }
      String linkKey = String.valueOf(row.Id) + ':' + String.valueOf(failure.recordId);
      if (existingLinkKeys.contains(linkKey)) {
        continue;
      }
      links.add(
        new Error_Log_Link__c(
          Error_Log__c = row.Id,
          Linked_Object_API_Name__c = failure.recordId.getSObjectType().getDescribe().getName(),
          Linked_Record_Id__c = String.valueOf(failure.recordId),
          Relationship_Role__c = 'Source'
        )
      );
    }
    if (!links.isEmpty()) {
      Database.insert(links, false);
    }
  }

  public static void markResolved(Id workItemId, Set<Id> recordIds) {
    if (recordIds == null || recordIds.isEmpty()) {
      return;
    }
    Set<String> references = new Set<String>();
    for (Id recordId : recordIds) {
      references.add(referenceFor(workItemId, recordId));
    }
    List<Error_Log__c> rows = [
      SELECT Id, Retry_Status__c
      FROM Error_Log__c
      WHERE External_Reference__c IN :references
    ];
    for (Error_Log__c row : rows) {
      row.Retry_Status__c = 'Success';
      row.Is_Retryable__c = false;
    }
    if (!rows.isEmpty()) {
      Database.update(rows, false);
    }
  }

  public static String sanitizeForUser(String message) {
    return sanitize(message);
  }

  private static void applyFailure(
    Error_Log__c row,
    Failure failure,
    String referenceValue
  ) {
    row.External_Reference__c = referenceValue.left(255);
    row.Error_Category__c = bounded(failure.category, 255, 'Integration Failure');
    row.Error_Message__c = sanitize(failure.message).left(MESSAGE_LIMIT);
    row.Http_Status_Code__c = failure.httpStatusCode;
    row.Is_Retryable__c = failure.retryable == true;
    row.Retry_Count__c = failure.retryCount == null ? 0 : failure.retryCount;
    row.Retry_Status__c = retryStatus(failure);
    row.Class_Method_Name__c = bounded(failure.classMethod, 255, null);
    row.Source_Object__c = failure.recordId.getSObjectType().getDescribe().getName();
    row.Source_Record_Id__c = String.valueOf(failure.recordId);
    row.Action_Source_Object__c = row.Source_Object__c;
    row.Action_Source_Record_Id__c = row.Source_Record_Id__c;
    row.Dml_Operation__c = bounded(failure.dmlOperation, 255, null);
    row.Raw_Payload__c = null;
    row.Stack_Trace__c = null;
    row.Retry_History_Notes__c = appendHistory(
      row.Retry_History_Notes__c,
      row.Retry_Count__c,
      row.Error_Message__c
    );
    applyTypedLookup(row, failure.recordId);
  }

  private static void applyTypedLookup(Error_Log__c row, Id recordId) {
    String objectName = recordId.getSObjectType().getDescribe().getName();
    Map<String, String> lookupByObject = new Map<String, String>{
      'Account' => 'Account__c',
      'Product2' => 'Product__c',
      'Order' => 'Order__c',
      'OrderItem' => 'Order_Item__c',
      'Invoice__c' => 'Invoice__c',
      'Purchase_Order__c' => 'Purchase_Order__c',
      'Credit_Memo__c' => 'Credit_Memo__c'
    };
    String lookupField = lookupByObject.get(objectName);
    if (String.isNotBlank(lookupField)) {
      row.put(lookupField, recordId);
    }
  }

  private static String retryStatus(Failure failure) {
    Integer attempts = failure.retryCount == null ? 0 : failure.retryCount;
    Integer maximum = failure.maximumAttempts == null ? 5 : failure.maximumAttempts;
    return failure.retryable == true && attempts < maximum
      ? 'Retrying'
      : 'Failed';
  }

  private static String appendHistory(
    String currentHistory,
    Decimal retryCount,
    String message
  ) {
    String entry = String.valueOf(System.now()) +
      ' attempt ' +
      String.valueOf(retryCount == null ? 0 : retryCount.intValue()) +
      ': ' +
      message;
    String combined = String.isBlank(currentHistory)
      ? entry
      : currentHistory + '\n' + entry;
    return combined.right(Math.min(HISTORY_LIMIT, combined.length()));
  }

  private static String referenceFor(Failure failure) {
    return referenceFor(failure.workItemId, failure.recordId);
  }

  private static String referenceFor(Id workItemId, Id recordId) {
    return String.valueOf(workItemId == null ? 'direct' : workItemId) +
      ':' +
      String.valueOf(recordId);
  }

  private static String sanitize(String message) {
    String safeMessage = String.isBlank(message)
      ? 'Integration processing failed.'
      : message;
    safeMessage = safeMessage.replaceAll('(?i)bearer\\s+[a-z0-9._~+\\-/]+=*', 'Bearer [REDACTED]');
    safeMessage = safeMessage.replaceAll('(?i)(token|secret|password|authorization)\\s*[:=]\\s*[^,;\\s]+', '$1=[REDACTED]');
    return safeMessage;
  }

  private static String bounded(String value, Integer limitValue, String fallback) {
    String resolved = String.isBlank(value) ? fallback : value;
    return String.isBlank(resolved) ? null : resolved.left(limitValue);
  }
}