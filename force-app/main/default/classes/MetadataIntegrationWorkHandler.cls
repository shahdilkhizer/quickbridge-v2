public abstract without sharing class MetadataIntegrationWorkHandler
  implements IntegrationWorkHandler {
  protected abstract String connectorKey();

  public ConnectorExecutionResult handle(Integration_Work_Item__c item) {
    if (item == null || String.isBlank(item.Operation__c)) {
      return ConnectorExecutionResult.failed(
        'Integration work item and operation are required.',
        false,
        null
      );
    }
    if (!normalize(item.Integration__c).equals(normalize(connectorKey()))) {
      return ConnectorExecutionResult.failed(
        'The work item does not belong to the selected connector.',
        false,
        null
      );
    }

    ConnectorExecutionRequest request = requestFor(item);
    GenericIntegrationRuntime.OperationDefinition definition =
      GenericIntegrationRuntime.resolve(request);
    request.salesforceObject = definition.salesforceObject;
    request.externalEntity = definition.externalEntity;
    request.validate();

    ConnectorExecutionResult result = ConnectorExecutionResult.success();
    result.asyncJobId = request.direction == ConnectorExecutionRequest.DIRECTION_OUTBOUND
      ? Database.executeBatch(new OutboundIntegrationHandler(request), request.scopeSize)
      : Database.executeBatch(new InboundIntegrationHandler(request), 1);
    return result;
  }

  protected virtual ConnectorExecutionRequest requestFor(
    Integration_Work_Item__c item
  ) {
    Integration_Operation__mdt operation = operationFor(item.Operation__c);
    ConnectorExecutionRequest request = new ConnectorExecutionRequest();
    request.connectorKey = connectorKey();
    request.operationKey = operation.Operation_Key__c;
    request.direction = normalizedDirection(operation.Direction__c);
    request.salesforceObject = operation.Salesforce_Object__c;
    request.externalEntity = operation.External_Entity__c;
    request.workItemId = item.Id;
    request.correlationKey = String.valueOf(item.Id);
    request.payload = item.Payload__c;
    request.retryAttempt = item.Attempt_Count__c == null
      ? 0
      : item.Attempt_Count__c.intValue();
    request.scopeSize = request.direction == ConnectorExecutionRequest.DIRECTION_OUTBOUND
      ? boundedScope(operation.Request_Cardinality__c)
      : 1;
    if (String.isNotBlank(item.Source_Salesforce_Id__c)) {
      request.recordIds.add(Id.valueOf(item.Source_Salesforce_Id__c));
    }
    return request;
  }

  private Integration_Operation__mdt operationFor(String operationKey) {
    List<Integration_Operation__mdt> rows = [
      SELECT Operation_Key__c, Direction__c, Salesforce_Object__c,
        External_Entity__c, Request_Cardinality__c
      FROM Integration_Operation__mdt
      WHERE Connector_Key__c = :connectorKey()
        AND Operation_Key__c = :operationKey
        AND Active__c = true
      LIMIT 1
    ];
    if (rows.isEmpty()) {
      throw new MetadataIntegrationWorkException(
        'No active metadata operation is configured for this work item.'
      );
    }
    return rows[0];
  }

  private static String normalizedDirection(String value) {
    String normalized = normalize(value);
    if (normalized == 'outbound') return ConnectorExecutionRequest.DIRECTION_OUTBOUND;
    if (normalized == 'inbound') return ConnectorExecutionRequest.DIRECTION_INBOUND;
    throw new MetadataIntegrationWorkException(
      'A work item must resolve to one bounded direction.'
    );
  }

  private static Integer boundedScope(String cardinality) {
    return normalize(cardinality) == 'collection' ? 200 : 50;
  }

  private static String normalize(String value) {
    return String.isBlank(value)
      ? ''
      : value.trim().toLowerCase().replaceAll('[^a-z0-9]', '');
  }

  public class MetadataIntegrationWorkException extends Exception {}
}