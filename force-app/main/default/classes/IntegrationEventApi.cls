public without sharing class IntegrationEventApi {
  private static Boolean dispatching = false;

  public static void dispatch(
    String objectApiName,
    String eventName,
    List<SObject> newRecords,
    Map<Id, SObject> oldRecords
  ) {
    if (
      dispatching ||
      String.isBlank(objectApiName) ||
      !new Set<String>{ 'afterInsert', 'afterUpdate', 'afterDelete' }.contains(
        eventName
      )
    ) {
      return;
    }
    List<SObject> records = newRecords == null ? new List<SObject>() : newRecords;
    if (records.isEmpty()) {
      return;
    }
    validateObject(objectApiName, records);
    dispatching = true;
    try {
      List<IntegrationWorkRequest> requests = new List<IntegrationWorkRequest>();
      requests.addAll(
        directRequests(objectApiName, eventName, records, oldRecords)
      );
      requests.addAll(
        parentRequests(objectApiName, eventName, records, oldRecords)
      );
      if (!requests.isEmpty()) {
        IntegrationWorkService.enqueue(requests);
      }
    } finally {
      dispatching = false;
    }
  }

  private static List<IntegrationWorkRequest> directRequests(
    String objectApiName,
    String eventName,
    List<SObject> records,
    Map<Id, SObject> oldRecords
  ) {
    List<IntegrationWorkRequest> requests = new List<IntegrationWorkRequest>();
    List<Integration_Operation__mdt> operations = [
      SELECT
        Connector_Key__c,
        Operation_Key__c,
        Salesforce_Object__c,
        Direction__c
      FROM Integration_Operation__mdt
      WHERE Active__c = true AND Salesforce_Object__c = :objectApiName
    ];
    if (operations.isEmpty()) {
      return requests;
    }
    Map<String, Set<String>> watchedByOperation = watchedFields(operations);
    for (Integration_Operation__mdt operation : operations) {
      if (!allowsOutbound(operation.Direction__c)) {
        continue;
      }
      if (!ConnectorConfigService.isActive(operation.Connector_Key__c)) {
        continue;
      }
      String keyValue = operationKey(
        operation.Connector_Key__c,
        operation.Operation_Key__c
      );
      Set<String> watched = watchedByOperation.get(keyValue);
      for (SObject recordValue : records) {
        if (
          qualifies(recordValue, oldRecords, eventName, watched) &&
          recordValue.Id != null
        ) {
          requests.add(
            requestFor(
              operation.Connector_Key__c,
              operation.Operation_Key__c,
              objectApiName,
              recordValue.Id
            )
          );
        }
      }
    }
    return requests;
  }

  private static List<IntegrationWorkRequest> parentRequests(
    String objectApiName,
    String eventName,
    List<SObject> records,
    Map<Id, SObject> oldRecords
  ) {
    List<IntegrationWorkRequest> requests = new List<IntegrationWorkRequest>();
    List<Integration_Operation_Mapping__mdt> mappings = [
      SELECT
        Connector_Key__c,
        Operation_Key__c,
        Salesforce_Object__c,
        Salesforce_Field__c,
        Parent_Salesforce_Field__c,
        Direction__c
      FROM Integration_Operation_Mapping__mdt
      WHERE
        Active__c = true
        AND Salesforce_Object__c = :objectApiName
        AND Parent_Salesforce_Field__c != NULL
    ];
    if (mappings.isEmpty()) {
      return requests;
    }
    Map<String, Set<String>> watchedByOperation = new Map<String, Set<String>>();
    Map<String, String> parentFieldByOperation = new Map<String, String>();
    for (Integration_Operation_Mapping__mdt mapping : mappings) {
      if (!allowsOutbound(mapping.Direction__c)) {
        continue;
      }
      String keyValue = operationKey(mapping.Connector_Key__c, mapping.Operation_Key__c);
      if (!watchedByOperation.containsKey(keyValue)) {
        watchedByOperation.put(keyValue, new Set<String>());
      }
      addWatchedField(watchedByOperation.get(keyValue), mapping.Salesforce_Field__c);
      parentFieldByOperation.put(keyValue, mapping.Parent_Salesforce_Field__c);
    }

    Set<String> keys = watchedByOperation.keySet();
    if (keys.isEmpty()) {
      return requests;
    }
    Map<String, Integration_Operation__mdt> operationsByKey =
      new Map<String, Integration_Operation__mdt>();
    for (Integration_Operation__mdt operation : [
      SELECT
        Connector_Key__c,
        Operation_Key__c,
        Salesforce_Object__c,
        Direction__c
      FROM Integration_Operation__mdt
      WHERE Active__c = true
    ]) {
      String keyValue = operationKey(operation.Connector_Key__c, operation.Operation_Key__c);
      if (keys.contains(keyValue) && allowsOutbound(operation.Direction__c)) {
        operationsByKey.put(keyValue, operation);
      }
    }

    for (String keyValue : operationsByKey.keySet()) {
      Integration_Operation__mdt operation = operationsByKey.get(keyValue);
      if (!ConnectorConfigService.isActive(operation.Connector_Key__c)) {
        continue;
      }
      String parentField = parentFieldByOperation.get(keyValue);
      for (SObject recordValue : records) {
        if (!qualifies(recordValue, oldRecords, eventName, watchedByOperation.get(keyValue))) {
          continue;
        }
        SObject sourceValue = recordValue;
        if (eventName == 'afterDelete' && oldRecords != null) {
          sourceValue = oldRecords.get(recordValue.Id);
        }
        Id parentId = sourceValue == null ? null : (Id) sourceValue.get(parentField);
        if (parentId != null) {
          requests.add(
            requestFor(
              operation.Connector_Key__c,
              operation.Operation_Key__c,
              operation.Salesforce_Object__c,
              parentId
            )
          );
        }
      }
    }
    return requests;
  }

  private static Map<String, Set<String>> watchedFields(
    List<Integration_Operation__mdt> operations
  ) {
    Set<String> connectors = new Set<String>();
    Set<String> operationKeys = new Set<String>();
    Map<String, Set<String>> watched = new Map<String, Set<String>>();
    for (Integration_Operation__mdt operation : operations) {
      connectors.add(operation.Connector_Key__c);
      operationKeys.add(operation.Operation_Key__c);
      watched.put(
        operationKey(operation.Connector_Key__c, operation.Operation_Key__c),
        new Set<String>()
      );
    }
    for (Integration_Operation_Mapping__mdt mapping : [
      SELECT Connector_Key__c, Operation_Key__c, Salesforce_Field__c, Direction__c
      FROM Integration_Operation_Mapping__mdt
      WHERE
        Active__c = true
        AND Connector_Key__c IN :connectors
        AND Operation_Key__c IN :operationKeys
    ]) {
      String keyValue = operationKey(mapping.Connector_Key__c, mapping.Operation_Key__c);
      if (watched.containsKey(keyValue) && allowsOutbound(mapping.Direction__c)) {
        addWatchedField(watched.get(keyValue), mapping.Salesforce_Field__c);
      }
    }
    return watched;
  }

  @TestVisible
  private static Boolean qualifies(
    SObject newRecord,
    Map<Id, SObject> oldRecords,
    String eventName,
    Set<String> watchedFields
  ) {
    if (eventName == 'afterInsert' || eventName == 'afterDelete') {
      return true;
    }
    SObject oldRecord = oldRecords == null ? null : oldRecords.get(newRecord.Id);
    if (oldRecord == null || watchedFields == null || watchedFields.isEmpty()) {
      return oldRecord == null;
    }
    for (String fieldName : watchedFields) {
      if (newRecord.get(fieldName) != oldRecord.get(fieldName)) {
        return true;
      }
    }
    return false;
  }

  @TestVisible
  private static void addWatchedField(Set<String> fields, String fieldPath) {
    if (fields == null || String.isBlank(fieldPath) || fieldPath.contains('.')) {
      return;
    }
    if (!IntegrationOutcomeService.SYSTEM_FIELDS.contains(fieldPath.toLowerCase())) {
      fields.add(fieldPath);
    }
  }

  private static IntegrationWorkRequest requestFor(
    String connectorKey,
    String operationKey,
    String sourceObject,
    Id sourceRecordId
  ) {
    IntegrationWorkRequest request = new IntegrationWorkRequest();
    request.connectorKey = connectorKey;
    request.operationKey = operationKey;
    request.sourceObject = sourceObject;
    request.sourceRecordId = sourceRecordId;
    request.lockKey = connectorKey.toLowerCase() +
      ':' +
      operationKey.toLowerCase() +
      ':' +
      String.valueOf(sourceRecordId);
    request.maximumAttempts = 5;
    return request;
  }

  private static void validateObject(String objectApiName, List<SObject> records) {
    Schema.SObjectType configuredType = ConnectorExecutionRequest.resolveSObjectType(
      objectApiName
    );
    if (configuredType == null) {
      throw new IntegrationEventException('Unsupported Salesforce object.');
    }
    for (SObject recordValue : records) {
      if (recordValue != null && recordValue.getSObjectType() != configuredType) {
        throw new IntegrationEventException('Trigger records do not match the configured object.');
      }
    }
  }

  private static Boolean allowsOutbound(String direction) {
    String normalized = String.isBlank(direction) ? '' : direction.toLowerCase();
    return normalized == 'outbound' ||
      normalized == 'bidirectional' ||
      normalized == 'both';
  }

  private static String operationKey(String connectorKey, String operationKey) {
    return connectorKey.toLowerCase() + ':' + operationKey.toLowerCase();
  }

  public class IntegrationEventException extends Exception {}
}