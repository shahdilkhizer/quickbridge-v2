public without sharing class IntegrationEventApi {
  private static Boolean dispatching = false;
  private static List<Integration_Operation__mdt> operationCache;
  @TestVisible private static List<Integration_Operation__mdt> testOperations;

  public static Boolean controlsRecordSave(String connectorKey) {
    return new Set<String>{ 'qbo', 'shopify', 'klaviyo' }.contains(
      String.isBlank(connectorKey) ? '' : connectorKey.trim().toLowerCase()
    );
  }

  public static Boolean supportsRecordSave(String connectorKey, String direction) {
    return controlsRecordSave(connectorKey) && allowsOutbound(direction);
  }

  private static List<Integration_Operation__mdt> operations() {
    if (Test.isRunningTest() && testOperations != null) return testOperations;
    if (operationCache == null) {
      operationCache = [
        SELECT Connector_Key__c, Operation_Key__c, Salesforce_Object__c, Direction__c,
          External_Entity__c, Salesforce_External_Id_Field__c, Active__c, Run_On_Record_Save__c
        FROM Integration_Operation__mdt WHERE Active__c = true
      ];
    }
    return operationCache;
  }

  public static void dispatch(
    String objectApiName, String eventName, List<SObject> newRecords,
    Map<Id, SObject> oldRecords
  ) {
    if (dispatching || String.isBlank(objectApiName) ||
        !new Set<String>{ 'afterInsert', 'afterUpdate', 'afterDelete' }.contains(eventName) ||
        newRecords == null || newRecords.isEmpty()) return;
    validateObject(objectApiName, newRecords);
    dispatching = true;
    try {
      List<Integration_Operation__mdt> eligible = new List<Integration_Operation__mdt>();
      Set<String> keys = new Set<String>();
      for (Integration_Operation__mdt operation : operations()) {
        if (operation.Active__c != true || !allowsOutbound(operation.Direction__c)) continue;
        if (controlsRecordSave(operation.Connector_Key__c) &&
            operation.Run_On_Record_Save__c != true) continue;
        eligible.add(operation);
        keys.add(operation.Connector_Key__c.toLowerCase());
      }
      if (eligible.isEmpty()) return;
      // One connector query per dispatch; never cache mutable activation state.
      Set<String> active = ConnectorConfigService.activeConnectorKeys(keys);
      if (active.isEmpty()) return;
      GenericIntegrationRuntime.primeMappingCache(active);
      List<IntegrationWorkRequest> requests = new List<IntegrationWorkRequest>();
      for (Integration_Operation__mdt operation : eligible) {
        if (!active.contains(operation.Connector_Key__c.toLowerCase())) continue;
        Boolean direct = isSameObject(operation.Salesforce_Object__c, objectApiName);
        if (!direct && !GenericIntegrationRuntime.hasRecordSaveChildObject(operation, objectApiName)) continue;
        List<GenericIntegrationRuntime.MappingRule> mappings =
          GenericIntegrationRuntime.recordSaveMappings(
            operation, controlsRecordSave(operation.Connector_Key__c)
          );
        Set<String> watched = new Set<String>();
        // Group child fields by parent relationship; one parent's flag governs all its lines.
        Map<String, Set<String>> watchedByParent = new Map<String, Set<String>>();
        for (GenericIntegrationRuntime.MappingRule mapping : mappings) {
          if (!allowsOutbound(mapping.direction)) continue;
          if (direct && (String.isBlank(mapping.salesforceObject) ||
              isSameObject(mapping.salesforceObject, objectApiName))) {
            addWatchedField(watched, mapping.salesforceField);
          }
          if (isSameObject(mapping.salesforceObject, objectApiName) &&
              String.isNotBlank(mapping.parentSalesforceField)) {
            if (!watchedByParent.containsKey(mapping.parentSalesforceField)) {
              watchedByParent.put(mapping.parentSalesforceField, new Set<String>());
            }
            addWatchedField(watchedByParent.get(mapping.parentSalesforceField), mapping.salesforceField);
          }
        }
        if (direct) {
          for (SObject recordValue : newRecords) {
            if (recordValue.Id != null && qualifies(recordValue, oldRecords, eventName, watched)) {
              requests.add(requestFor(operation.Connector_Key__c, operation.Operation_Key__c,
                objectApiName, recordValue.Id));
            }
          }
        }
        for (String parentField : watchedByParent.keySet()) {
          for (SObject recordValue : newRecords) {
            if (!qualifies(recordValue, oldRecords, eventName, watchedByParent.get(parentField))) continue;
            SObject sourceValue = eventName == 'afterDelete' && oldRecords != null
              ? oldRecords.get(recordValue.Id) : recordValue;
            Id parentId = sourceValue == null ? null : (Id) sourceValue.get(parentField);
            if (parentId != null) requests.add(requestFor(operation.Connector_Key__c,
              operation.Operation_Key__c, operation.Salesforce_Object__c, parentId));
          }
        }
      }
      if (!requests.isEmpty()) IntegrationWorkService.enqueue(requests);
    } finally {
      dispatching = false;
    }
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
    Map<String, Schema.SObjectField> sObjectFields = newRecord.getSObjectType().getDescribe().fields.getMap();
    for (String fieldName : watchedFields) {
      if (!sObjectFields.containsKey(fieldName.toLowerCase())) {
        continue;
      }
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

  private static Boolean isSameObject(String left, String right) {
    if (String.isBlank(left) && String.isBlank(right)) return true;
    if (String.isBlank(left) || String.isBlank(right)) return false;
    return left.toLowerCase().replace('quickbridgetlg__', '') ==
           right.toLowerCase().replace('quickbridgetlg__', '');
  }

  private static Boolean allowsOutbound(String direction) {
    String normalized = String.isBlank(direction) ? '' : direction.trim().toLowerCase();
    return normalized == 'outbound' ||
      normalized == 'bidirectional' ||
      normalized == 'both';
  }

  private static String operationKey(String connectorKey, String operationKey) {
    return connectorKey.toLowerCase() + ':' + operationKey.toLowerCase();
  }

  public class IntegrationEventException extends Exception {}
}