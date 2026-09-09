public with sharing class QuickbridgeRecordSyncController {

  public class SyncResult {
    @AuraEnabled public Boolean success;
    @AuraEnabled public String message;
    @AuraEnabled public String externalId;

    public SyncResult(Boolean success, String message, String externalId) {
      this.success = success;
      this.message = message;
      this.externalId = externalId;
    }
  }

  @AuraEnabled
  public static SyncResult syncToProvider(Id recordId, String connectorKey) {
    if (recordId == null) {
      return new SyncResult(false, 'Record ID is required.', null);
    }
    String connKey = String.isBlank(connectorKey) ? 'qbo' : connectorKey.toLowerCase();
    String sObjName = recordId.getSObjectType().getDescribe().getName();

    try {
      Integration_Operation__mdt operation = resolveOperation(connKey, sObjName, 'Outbound');
      if (operation == null) {
        return new SyncResult(false, 'No active Outbound operation configured for ' + sObjName + ' and ' + connKey.toUpperCase() + '.', null);
      }

      ConnectorExecutionRequest req = new ConnectorExecutionRequest();
      req.connectorKey = connKey;
      req.operationKey = operation.Operation_Key__c;
      req.direction = ConnectorExecutionRequest.DIRECTION_OUTBOUND;
      req.recordIds = new List<Id>{ recordId };

      GenericIntegrationRuntime.OperationDefinition def = GenericIntegrationRuntime.resolve(req);
      String query = GenericIntegrationRuntime.buildSourceQuery(def, req);

      List<Id> recordIds = new List<Id>{ recordId };
      List<SObject> records = Database.query(query);
      if (records.isEmpty()) {
        return new SyncResult(false, 'Record not found.', null);
      }

      String payload = GenericIntegrationRuntime.buildRequestBody(def, records, req);

      ConnectorHttpClient.RequestSpec spec = new ConnectorHttpClient.RequestSpec();
      spec.namedCredential = def.namedCredential;
      spec.relativeEndpoint = def.relativeEndpoint;
      spec.method = def.httpMethod;
      spec.headers = GenericIntegrationRuntime.headersFor(def);
      spec.body = payload;

      ConnectorHttpClient.Response resp = ConnectorHttpClient.send(spec);

      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        String extId = extractExternalId(resp.body, def.externalEntity);
        if (String.isNotBlank(extId) && String.isNotBlank(def.salesforceExternalIdField)) {
          SObject updateRec = recordId.getSObjectType().newSObject(recordId);
          updateRec.put(def.salesforceExternalIdField, extId);
          update updateRec;
        }
        return new SyncResult(true, 'Successfully synced to ' + connKey.toUpperCase() + (String.isNotBlank(extId) ? ' (ID: ' + extId + ')' : ''), extId);
      } else {
        String errDetail = extractErrorMessage(resp.body);
        return new SyncResult(false, 'Sync to ' + connKey.toUpperCase() + ' failed (HTTP ' + resp.statusCode + '): ' + errDetail, null);
      }
    } catch (Exception ex) {
      return new SyncResult(false, 'Error during sync: ' + ex.getMessage(), null);
    }
  }

  @AuraEnabled
  public static SyncResult syncFromProvider(Id recordId, String connectorKey) {
    if (recordId == null) {
      return new SyncResult(false, 'Record ID is required.', null);
    }
    String connKey = String.isBlank(connectorKey) ? 'qbo' : connectorKey.toLowerCase();
    String sObjName = recordId.getSObjectType().getDescribe().getName();

    try {
      Integration_Operation__mdt operation = resolveOperation(connKey, sObjName, 'Inbound');
      if (operation == null) {
        return new SyncResult(false, 'No active Inbound operation configured for ' + sObjName + ' and ' + connKey.toUpperCase() + '.', null);
      }

      ConnectorExecutionRequest req = new ConnectorExecutionRequest();
      req.connectorKey = connKey;
      req.operationKey = operation.Operation_Key__c;
      req.direction = ConnectorExecutionRequest.DIRECTION_INBOUND;

      GenericIntegrationRuntime.OperationDefinition def = GenericIntegrationRuntime.resolve(req);
      String extFieldName = def.salesforceExternalIdField;
      if (String.isBlank(extFieldName)) {
        return new SyncResult(false, 'External ID field is not defined for ' + operation.Operation_Key__c + '.', null);
      }

      String query = 'SELECT Id, ' + extFieldName + ' FROM ' + sObjName + ' WHERE Id = :recordId LIMIT 1';
      SObject rec = Database.query(query);
      Object extVal = rec.get(extFieldName);
      if (extVal == null || String.isBlank(String.valueOf(extVal))) {
        return new SyncResult(false, 'This record is not yet linked to ' + connKey.toUpperCase() + ' (' + extFieldName + ' is blank). Please sync to ' + connKey.toUpperCase() + ' first.', null);
      }
      String extId = String.valueOf(extVal);

      ConnectorHttpClient.RequestSpec spec = new ConnectorHttpClient.RequestSpec();
      spec.namedCredential = def.namedCredential;
      spec.relativeEndpoint = '/' + def.externalEntity.toLowerCase() + '/' + extId;
      spec.method = 'GET';
      spec.headers = GenericIntegrationRuntime.headersFor(def);

      ConnectorHttpClient.Response resp = ConnectorHttpClient.send(spec);

      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        // Adjust responseCollectionPath for single entity get
        Object parsed = GenericIntegrationRuntime.parseResponseBody(resp.body);
        if (parsed instanceof Map<String, Object>) {
          Map<String, Object> pMap = (Map<String, Object>) parsed;
          if (!pMap.containsKey('QueryResponse')) {
            def.responseCollectionPath = def.externalEntity;
          }
        }
        ConnectorExecutionResult persistRes = GenericIntegrationRuntime.persistInbound(def, resp.body);
        if (persistRes != null && persistRes.hasFailures()) {
          return new SyncResult(false, 'Inbound persist failed: ' + persistRes.errorSummary, extId);
        }
        return new SyncResult(true, 'Successfully refreshed from ' + connKey.toUpperCase() + ' (ID: ' + extId + ')', extId);
      } else {
        String errDetail = extractErrorMessage(resp.body);
        return new SyncResult(false, 'Refresh from ' + connKey.toUpperCase() + ' failed (HTTP ' + resp.statusCode + '): ' + errDetail, extId);
      }
    } catch (Exception ex) {
      return new SyncResult(false, 'Error during refresh: ' + ex.getMessage(), null);
    }
  }

  private static Integration_Operation__mdt resolveOperation(String connectorKey, String sObjName, String direction) {
    List<Integration_Operation__mdt> ops = [
      SELECT Id, Operation_Key__c, Salesforce_Object__c, External_Entity__c, Direction__c, Active__c
      FROM Integration_Operation__mdt
      WHERE Connector_Key__c = :connectorKey
        AND Salesforce_Object__c = :sObjName
        AND Active__c = true
    ];
    for (Integration_Operation__mdt op : ops) {
      String dir = GenericIntegrationRuntime.normalizeDirectionForHandler(op.Direction__c);
      if (direction == 'Outbound' && (dir == 'Outbound' || dir == 'Bidirectional')) {
        return op;
      }
      if (direction == 'Inbound' && (dir == 'Inbound' || dir == 'Bidirectional')) {
        return op;
      }
    }
    return ops.isEmpty() ? null : ops[0];
  }

  private static String extractExternalId(String body, String entityName) {
    if (String.isBlank(body)) return null;
    try {
      Object parsed = JSON.deserializeUntyped(body);
      if (parsed instanceof Map<String, Object>) {
        Map<String, Object> pMap = (Map<String, Object>) parsed;
        Object entityObj = String.isNotBlank(entityName) ? pMap.get(entityName) : null;
        if (entityObj == null && String.isNotBlank(entityName)) {
          entityObj = pMap.get(entityName.toLowerCase());
        }
        if (entityObj instanceof Map<String, Object>) {
          return String.valueOf(((Map<String, Object>) entityObj).get('Id'));
        }
        if (pMap.containsKey('Id')) {
          return String.valueOf(pMap.get('Id'));
        }
      }
    } catch (Exception ex) {}
    return null;
  }

  private static String extractErrorMessage(String body) {
    if (String.isBlank(body)) return 'Empty response';
    try {
      Object parsed = JSON.deserializeUntyped(body);
      if (parsed instanceof Map<String, Object>) {
        Map<String, Object> pMap = (Map<String, Object>) parsed;
        if (pMap.containsKey('Fault')) {
          Map<String, Object> fault = (Map<String, Object>) pMap.get('Fault');
          if (fault.containsKey('Error')) {
            List<Object> errList = (List<Object>) fault.get('Error');
            if (errList != null && !errList.isEmpty()) {
              Map<String, Object> firstErr = (Map<String, Object>) errList[0];
              return String.valueOf(firstErr.get('Message')) + (firstErr.containsKey('Detail') ? ': ' + String.valueOf(firstErr.get('Detail')) : '');
            }
          }
        }
      }
    } catch (Exception ex) {}
    return body.length() > 200 ? body.substring(0, 200) : body;
  }
}
