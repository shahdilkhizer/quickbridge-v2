/** Bulk inbound mapping and replay. Inherited sharing plus user-mode lookups and CRUD/FLS checked DML. */
public inherited sharing class GenericInboundResourcePersistence {
  public static ConnectorExecutionResult persist(GenericIntegrationRuntime.OperationDefinition definition, String body, Boolean enqueueFailures) {
    GenericResourceContract contract = GenericResourceContract.parse(definition.resourceContractJson);
    List<Object> source = GenericIntegrationRuntime.responseRows(definition, body);
    ConnectorExecutionResult result = ConnectorExecutionResult.success();
    List<SObject> parents = new List<SObject>();
    List<Map<String, Object>> accepted = new List<Map<String, Object>>();
    List<IntegrationWorkRequest> failures = new List<IntegrationWorkRequest>();
    ResourceOrderContext orderContext = contract.graphProfile == 'SalesOrderLines'
      ? new ResourceOrderContext(definition, contract, source) : null;
    Set<String> identities = new Set<String>();
    for (Object raw : source) {
      Map<String, Object> row = raw instanceof Map<String, Object> ? (Map<String, Object>)raw : null;
      try {
        GenericResourceContract.require(row != null, 'Inbound resource contains a non-object row.');
        String identity = identity(definition, row);
        GenericResourceContract.require(String.isNotBlank(identity) && !identities.contains(identity), 'Missing or duplicate inbound identity.');
        identities.add(identity);
        if (orderContext != null) orderContext.prepare(row);
        SObject parent=mapRecord(definition, definition.salesforceObject, row);
        GenericResourceContract.require(parent.get(definition.salesforceExternalIdField)!=null &&
          String.valueOf(parent.get(definition.salesforceExternalIdField))==identity,'Inbound mapping must preserve the resource external identity.');
        parents.add(parent);
        accepted.add(row);
      } catch (Exception error) { fail(definition, row, error.getMessage(), result, failures); }
    }
    if (!parents.isEmpty()) {
      SObjectAccessDecision access = Security.stripInaccessible(AccessType.UPSERTABLE, parents);
      GenericResourceContract.require(access.getRemovedFields().isEmpty(), 'Inbound mappings include fields without write access.');
      Schema.SObjectField externalField = parents[0].getSObjectType().getDescribe().fields.getMap().get(definition.salesforceExternalIdField);
      Boolean prior = IntegrationEventApi.suppressDispatch;
      IntegrationEventApi.suppressDispatch = true;
      try {
        Database.UpsertResult[] saved = Database.upsert(access.getRecords(), externalField, false);
        List<Id> parentIds = new List<Id>();
        List<Map<String, Object>> parentRows = new List<Map<String, Object>>();
        for (Integer i=0; i<saved.size(); i++) {
          if (saved[i].isSuccess()) {
            result.processedCount++; result.successfulCount++;
            parentIds.add(saved[i].getId()); parentRows.add(accepted[i]);
          } else fail(definition, accepted[i], errors(saved[i].getErrors()), result, failures);
        }
        if (orderContext != null) orderContext.persistChildren(parentIds, parentRows, result, failures);
      } finally { IntegrationEventApi.suppressDispatch = prior; }
    }
    if (!failures.isEmpty()) {
      if (enqueueFailures) IntegrationWorkService.enqueue(failures);
      List<IntegrationErrorLogService.Failure> logs = new List<IntegrationErrorLogService.Failure>();
      for (IntegrationWorkRequest work : failures) {
        IntegrationErrorLogService.Failure log = new IntegrationErrorLogService.Failure();
        log.connectorKey=work.connectorKey; log.operationKey=work.operationKey; log.sourceObject=work.sourceObject;
        log.externalId=work.sourceExternalId; log.category='INBOUND_RESOURCE_FAILURE';
        log.message=result.errorSummary; log.retryable=false; logs.add(log);
      }
      IntegrationErrorLogService.logFailures(logs);
    }
    return result;
  }

  public static SObject mapRecord(GenericIntegrationRuntime.OperationDefinition definition, String objectName, Map<String,Object> row) {
    Schema.SObjectType objectType = ConnectorExecutionRequest.resolveSObjectType(objectName);
    SObject target = objectType.newSObject();
    Map<String,Schema.SObjectField> fields = objectType.getDescribe().fields.getMap();
    for (GenericIntegrationRuntime.MappingRule rule : definition.mappings) {
      if (!objectName.equalsIgnoreCase(rule.salesforceObject) ||
        !new Set<String>{'inbound','both','bidirectional'}.contains(rule.direction == null ? '' : rule.direction.toLowerCase())) continue;
      Object value = GenericIntegrationRuntime.valueAtPath(row, rule.externalPath);
      if (value == null && String.isNotBlank(rule.defaultValue)) value = rule.defaultValue;
      GenericResourceContract.require(value != null || rule.required != true, 'Required inbound field is missing: ' + rule.salesforceField);
      if (value != null || rule.nullBehavior == 'Include') {
        GenericIntegrationRuntime.putCoerced(target, rule.salesforceField,
          GenericIntegrationRuntime.transform(value, rule.transform), fields);
      }
    }
    return target;
  }

  public static String identity(GenericIntegrationRuntime.OperationDefinition definition, Map<String,Object> row) {
    Object value = row == null ? null : GenericIntegrationRuntime.valueAtPath(row, definition.responseIdPath);
    return value == null ? null : String.valueOf(value);
  }
  public static String errors(List<Database.Error> errors) {
    List<String> messages = new List<String>();
    for (Database.Error error : errors) messages.add(String.valueOf(error.getStatusCode()));
    return String.join(messages, ', ');
  }
  public static void fail(GenericIntegrationRuntime.OperationDefinition definition, Map<String,Object> row, String message,
    ConnectorExecutionResult result, List<IntegrationWorkRequest> failures) {
    result.processedCount++; result.failedCount++; result.addError(message);
    result.errorCategory = 'INBOUND_RESOURCE_FAILURE';
    String externalId = identity(definition, row);
    if (String.isBlank(externalId)) return;
    IntegrationWorkRequest work = new IntegrationWorkRequest();
    work.connectorKey = definition.connectorKey; work.operationKey = definition.operationKey;
    work.sourceObject = definition.salesforceObject; work.sourceExternalId = externalId;
    work.lifecycleAction = 'InboundReplay'; work.maximumAttempts = 1;
    // Only the external ID is stored. Replay retrieves the current remote row, never a PII payload.
    failures.add(work);
  }
}