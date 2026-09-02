public without sharing class IntegrationOutcomeService {
  public static final String SUCCESS_FIELD = 'Integration_Success__c';
  public static final String ERROR_FIELD = 'Integration_Error__c';
  public static final String CONNECTOR_FIELD = 'Last_Integration__c';
  public static final String OPERATION_FIELD = 'Last_Integration_Operation__c';
  public static final String ATTEMPT_FIELD = 'Last_Integration_Attempt_At__c';
  public static final String SUCCESS_AT_FIELD = 'Last_Integration_Success_At__c';

  public static final Set<String> SYSTEM_FIELDS = new Set<String>{
    SUCCESS_FIELD.toLowerCase(),
    ERROR_FIELD.toLowerCase(),
    CONNECTOR_FIELD.toLowerCase(),
    OPERATION_FIELD.toLowerCase(),
    ATTEMPT_FIELD.toLowerCase(),
    SUCCESS_AT_FIELD.toLowerCase()
  };

  public static void markPending(
    Set<Id> recordIds,
    String connectorKey,
    String operationKey
  ) {
    updateOutcomes(recordIds, connectorKey, operationKey, false, false, false);
  }

  public static void markSuccess(
    Set<Id> recordIds,
    String connectorKey,
    String operationKey
  ) {
    updateOutcomes(recordIds, connectorKey, operationKey, true, false, true);
  }

  public static void markFailure(
    Set<Id> recordIds,
    String connectorKey,
    String operationKey
  ) {
    updateOutcomes(recordIds, connectorKey, operationKey, false, true, false);
  }

  private static void updateOutcomes(
    Set<Id> recordIds,
    String connectorKey,
    String operationKey,
    Boolean success,
    Boolean error,
    Boolean stampSuccess
  ) {
    if (recordIds == null || recordIds.isEmpty()) {
      return;
    }
    Map<Schema.SObjectType, List<SObject>> updatesByType =
      new Map<Schema.SObjectType, List<SObject>>();
    Datetime nowValue = System.now();
    for (Id recordId : recordIds) {
      if (recordId == null) {
        continue;
      }
      Schema.SObjectType objectType = recordId.getSObjectType();
      Map<String, Schema.SObjectField> fields = objectType.getDescribe().fields.getMap();
      if (!supportsOutcomes(fields)) {
        continue;
      }
      SObject updateRecord = objectType.newSObject(recordId);
      updateRecord.put(SUCCESS_FIELD, success);
      updateRecord.put(ERROR_FIELD, error);
      updateRecord.put(CONNECTOR_FIELD, bounded(connectorKey, 80));
      updateRecord.put(OPERATION_FIELD, bounded(operationKey, 100));
      updateRecord.put(ATTEMPT_FIELD, nowValue);
      if (stampSuccess) {
        updateRecord.put(SUCCESS_AT_FIELD, nowValue);
      }
      if (!updatesByType.containsKey(objectType)) {
        updatesByType.put(objectType, new List<SObject>());
      }
      updatesByType.get(objectType).add(updateRecord);
    }

    // These six fields are owned exclusively by the background runtime. System
    // mode makes the outcome contract independent of the initiating user's FLS;
    // the UI controller still enforces CRUD/FLS before exposing the values.
    for (Schema.SObjectType objectType : updatesByType.keySet()) {
      List<SObject> systemRecords = updatesByType.get(objectType);
      if (!systemRecords.isEmpty()) {
        Database.update(systemRecords, false, AccessLevel.SYSTEM_MODE);
      }
    }
  }

  private static Boolean supportsOutcomes(
    Map<String, Schema.SObjectField> fields
  ) {
    return fields.containsKey(SUCCESS_FIELD) &&
      fields.containsKey(ERROR_FIELD) &&
      fields.containsKey(CONNECTOR_FIELD) &&
      fields.containsKey(OPERATION_FIELD) &&
      fields.containsKey(ATTEMPT_FIELD) &&
      fields.containsKey(SUCCESS_AT_FIELD);
  }

  private static String bounded(String value, Integer length) {
    return String.isBlank(value) ? null : value.left(length);
  }
}