public abstract without sharing class MetadataScheduledOperationAdapter
  implements ScheduledOperationAdapter {
  protected abstract String connectorKey();

  public ConnectorExecutionResult execute(Scheduled_Integration_Job__c job) {
    if (job == null || job.Id == null || String.isBlank(job.Lease_Token__c)) {
      return ConnectorExecutionResult.failed(
        'A claimed scheduled integration job is required.',
        false,
        null
      );
    }
    Integration_Operation__mdt operation = resolveOperation(job);
    ConnectorExecutionRequest request = new ConnectorExecutionRequest();
    request.connectorKey = connectorKey();
    request.operationKey = operation.Operation_Key__c;
    request.direction = normalize(operation.Direction__c) == 'outbound'
      ? ConnectorExecutionRequest.DIRECTION_OUTBOUND
      : ConnectorExecutionRequest.DIRECTION_INBOUND;
    request.salesforceObject = operation.Salesforce_Object__c;
    request.externalEntity = operation.External_Entity__c;
    request.scheduleId = job.Id;
    request.leaseToken = job.Lease_Token__c;
    request.correlationKey = String.valueOf(job.Id);
    request.scopeSize = request.direction == ConnectorExecutionRequest.DIRECTION_OUTBOUND
      ? (normalize(operation.Request_Cardinality__c) == 'collection' ? 200 : 50)
      : 1;
    request.validate();

    ConnectorExecutionResult result = ConnectorExecutionResult.success();
    result.asyncJobId = request.direction == ConnectorExecutionRequest.DIRECTION_OUTBOUND
      ? Database.executeBatch(new OutboundIntegrationHandler(request), request.scopeSize)
      : Database.executeBatch(new InboundIntegrationHandler(request), 1);
    return result;
  }

  private Integration_Operation__mdt resolveOperation(
    Scheduled_Integration_Job__c job
  ) {
    List<Integration_Operation__mdt> operations = [
      SELECT Operation_Key__c, Direction__c, Salesforce_Object__c,
        External_Entity__c, Request_Cardinality__c
      FROM Integration_Operation__mdt
      WHERE Connector_Key__c = :connectorKey()
        AND Active__c = true
    ];
    String requested = normalize(job.Source_Object__c);
    String requestedDirection = normalize(job.Direction__c);
    for (Integration_Operation__mdt operation : operations) {
      Boolean operationMatches = requested == normalize(operation.Operation_Key__c) ||
        requested == normalize(operation.Salesforce_Object__c) ||
        requested == normalize(operation.External_Entity__c);
      Boolean directionMatches = String.isBlank(requestedDirection) ||
        requestedDirection == normalize(operation.Direction__c) ||
        (requestedDirection == 'in' && normalize(operation.Direction__c) == 'inbound') ||
        (requestedDirection == 'out' && normalize(operation.Direction__c) == 'outbound');
      if (operationMatches && directionMatches) return operation;
    }
    throw new MetadataScheduledOperationException(
      'No active operation matches the scheduled object and direction.'
    );
  }

  private static String normalize(String value) {
    return String.isBlank(value)
      ? ''
      : value.trim().toLowerCase().replaceAll('[^a-z0-9]', '');
  }

  public class MetadataScheduledOperationException extends Exception {}
}