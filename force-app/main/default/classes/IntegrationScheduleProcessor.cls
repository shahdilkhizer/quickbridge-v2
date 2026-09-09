public without sharing class IntegrationScheduleProcessor
  implements Queueable, Database.AllowsCallouts {
  private Id scheduleId;
  private String leaseToken;

  public IntegrationScheduleProcessor(Id scheduleId, String leaseToken) {
    this.scheduleId = scheduleId;
    this.leaseToken = leaseToken;
  }

  public void execute(QueueableContext context) {
    List<Scheduled_Integration_Job__c> rows = [
      SELECT
        Id,
        Integration_Type__c,
        Source_Object__c,
        Direction__c,
        Status__c,
        Lease_Token__c,
        Last_Run_At__c,
        Created_DateTime__c
      FROM Scheduled_Integration_Job__c
      WHERE Id = :scheduleId
      LIMIT 1
    ];
    if (
      rows.isEmpty() ||
      rows[0].Status__c != 'Claimed' ||
      rows[0].Lease_Token__c != leaseToken
    ) {
      return;
    }
    Scheduled_Integration_Job__c job = rows[0];
    String connectorKey = IntegrationScheduleDispatcher.normalizeConnector(
      job.Integration_Type__c
    );
    String rawDirection = GenericIntegrationRuntime.normalizeDirectionForHandler(job.Direction__c);
    Integration_Operation__mdt matchedOp = resolveOperation(
      connectorKey,
      job.Source_Object__c,
      rawDirection
    );

    ConnectorExecutionRequest request = new ConnectorExecutionRequest();
    request.connectorKey = connectorKey;
    request.operationKey = matchedOp != null ? matchedOp.Operation_Key__c : job.Source_Object__c;
    request.direction = matchedOp != null
      ? GenericIntegrationRuntime.normalizeDirectionForHandler(matchedOp.Direction__c)
      : (rawDirection == 'Inbound' ? ConnectorExecutionRequest.DIRECTION_INBOUND : ConnectorExecutionRequest.DIRECTION_OUTBOUND);
    request.salesforceObject = matchedOp != null ? matchedOp.Salesforce_Object__c : job.Source_Object__c;
    request.externalEntity = matchedOp != null ? matchedOp.External_Entity__c : null;
    request.scheduleId = job.Id;
    request.leaseToken = leaseToken;
    request.correlationKey = String.valueOf(job.Id);
    request.sinceValue = job.Last_Run_At__c != null
      ? job.Last_Run_At__c.addMinutes(-10)
      : (job.Created_DateTime__c != null ? job.Created_DateTime__c.addDays(-1) : System.now().addDays(-7));
    request.scopeSize = request.direction == ConnectorExecutionRequest.DIRECTION_OUTBOUND
      ? 50
      : 1;
    try {
      if (
        ConnectorCapabilityRouter.hasCapability(
          request.connectorKey,
          'scheduler.operation'
        )
      ) {
        ConnectorExecutionResult scheduledResult =
          ConnectorCapabilityRouter.scheduledAdapter(request.connectorKey)
            .execute(job);
        if (scheduledResult != null && scheduledResult.asyncJobId != null) {
          if (!ConnectorScheduleService.markRunning(
            scheduleId,
            leaseToken,
            scheduledResult.asyncJobId
          )) {
            ConnectorScheduleService.completeFailure(
              scheduleId,
              leaseToken,
              'The schedule lease changed before execution could start.'
            );
          }
        } else if (scheduledResult != null && !scheduledResult.hasFailures()) {
          IntegrationScheduleDispatcher.completeRun(
            scheduleId,
            leaseToken,
            true,
            null
          );
        } else {
          ConnectorScheduleService.completeFailure(
            scheduleId,
            leaseToken,
            scheduledResult == null
              ? 'The scheduled adapter returned no result.'
              : scheduledResult.errorSummary
          );
        }
        return;
      }
      GenericIntegrationRuntime.OperationDefinition definition =
        GenericIntegrationRuntime.resolve(request);
      request.salesforceObject = definition.salesforceObject;
      request.externalEntity = definition.externalEntity;
      Id batchJobId = request.direction == ConnectorExecutionRequest.DIRECTION_OUTBOUND
        ? Database.executeBatch(new OutboundIntegrationHandler(request), request.scopeSize)
        : Database.executeBatch(new InboundIntegrationHandler(request), 1);
      if (!ConnectorScheduleService.markRunning(scheduleId, leaseToken, batchJobId)) {
        ConnectorScheduleService.completeFailure(
          scheduleId,
          leaseToken,
          'The schedule lease changed before execution could start.'
        );
      }
    } catch (Exception exceptionValue) {
      ConnectorScheduleService.completeFailure(
        scheduleId,
        leaseToken,
        exceptionValue.getMessage()
      );
    }
  }

  private static Integration_Operation__mdt resolveOperation(
    String connectorKey,
    String sourceObject,
    String normalizedDirection
  ) {
    List<Integration_Operation__mdt> operations = [
      SELECT
        Operation_Key__c,
        Direction__c,
        Salesforce_Object__c,
        External_Entity__c,
        Request_Cardinality__c
      FROM Integration_Operation__mdt
      WHERE Connector_Key__c = :connectorKey
        AND Active__c = true
    ];
    String requested = GenericIntegrationRuntime.normalize(sourceObject);
    for (Integration_Operation__mdt operation : operations) {
      Boolean operationMatches = requested == GenericIntegrationRuntime.normalize(operation.Operation_Key__c) ||
        requested == GenericIntegrationRuntime.normalize(operation.Salesforce_Object__c) ||
        requested == GenericIntegrationRuntime.normalize(operation.External_Entity__c);
      String opDir = GenericIntegrationRuntime.normalizeDirectionForHandler(operation.Direction__c);
      Boolean directionMatches = String.isBlank(normalizedDirection) ||
        normalizedDirection == opDir ||
        opDir == 'Bidirectional';
      if (operationMatches && directionMatches) {
        return operation;
      }
    }
    return null;
  }
}