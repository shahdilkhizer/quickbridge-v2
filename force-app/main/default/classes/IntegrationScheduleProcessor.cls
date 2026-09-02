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
        Lease_Token__c
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
    ConnectorExecutionRequest request = new ConnectorExecutionRequest();
    request.connectorKey = IntegrationScheduleDispatcher.normalizeConnector(
      job.Integration_Type__c
    );
    request.operationKey = job.Source_Object__c;
    request.direction = job.Direction__c == 'Out'
      ? ConnectorExecutionRequest.DIRECTION_OUTBOUND
      : ConnectorExecutionRequest.DIRECTION_INBOUND;
    request.scheduleId = job.Id;
    request.leaseToken = leaseToken;
    request.correlationKey = String.valueOf(job.Id);
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
}