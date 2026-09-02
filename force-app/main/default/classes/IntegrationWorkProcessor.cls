public without sharing class IntegrationWorkProcessor
  implements Queueable, Database.AllowsCallouts {
  private Id workItemId;
  private String processorToken;

  public IntegrationWorkProcessor(Id workItemId, String processorToken) {
    this.workItemId = workItemId;
    this.processorToken = processorToken;
  }

  public void execute(QueueableContext context) {
    List<Integration_Work_Item__c> rows = [
      SELECT
        Id,
        Integration__c,
        Operation__c,
        Source_Object__c,
        Source_Salesforce_Id__c,
        Payload__c,
        Status__c,
        Processor_Token__c,
        Attempt_Count__c
      FROM Integration_Work_Item__c
      WHERE Id = :workItemId
      LIMIT 1
    ];
    if (rows.isEmpty()) {
      return;
    }
    Integration_Work_Item__c item = rows[0];
    if (
      item.Status__c != IntegrationWorkService.STATUS_PROCESSING ||
      item.Processor_Token__c != processorToken
    ) {
      return;
    }

    ConnectorExecutionRequest request = buildRequest(item);
    try {
      if (
        ConnectorCapabilityRouter.hasCapability(
          item.Integration__c,
          'work.' + item.Operation__c
        )
      ) {
        ConnectorExecutionResult capabilityResult =
          ConnectorCapabilityRouter.workHandler(
              item.Integration__c,
              item.Operation__c
            )
            .handle(item);
        if (capabilityResult != null && capabilityResult.asyncJobId != null) {
          IntegrationWorkService.markBatchRunning(
            item.Id,
            processorToken,
            capabilityResult.asyncJobId
          );
        } else {
          IntegrationWorkService.complete(
            item.Id,
            request,
            capabilityResult == null
              ? ConnectorExecutionResult.failed(
                  'The connector work adapter returned no result.',
                  false,
                  null
                )
              : capabilityResult
          );
        }
        return;
      }
      request.validate();
      Integer scopeSize = Math.max(1, Math.min(50, request.scopeSize));
      Id batchJobId = Database.executeBatch(
        new OutboundIntegrationHandler(request),
        scopeSize
      );
      IntegrationWorkService.markBatchRunning(
        item.Id,
        processorToken,
        batchJobId
      );
    } catch (Exception exceptionValue) {
      ConnectorExecutionResult failureResult = ConnectorExecutionResult.failed(
        exceptionValue.getMessage(),
        IntegrationRetryPolicy.isRetryable(exceptionValue),
        null
      );
      IntegrationWorkService.complete(item.Id, request, failureResult);
    }
  }

  private static ConnectorExecutionRequest buildRequest(
    Integration_Work_Item__c item
  ) {
    ConnectorExecutionRequest request = new ConnectorExecutionRequest();
    request.connectorKey = item.Integration__c;
    request.operationKey = item.Operation__c;
    request.direction = ConnectorExecutionRequest.DIRECTION_OUTBOUND;
    request.salesforceObject = item.Source_Object__c;
    request.workItemId = item.Id;
    request.correlationKey = String.valueOf(item.Id);
    request.payload = item.Payload__c;
    request.retryAttempt = item.Attempt_Count__c == null
      ? 0
      : item.Attempt_Count__c.intValue();
    request.scopeSize = 50;
    if (String.isNotBlank(item.Source_Salesforce_Id__c)) {
      request.recordIds.add(Id.valueOf(item.Source_Salesforce_Id__c));
    }
    return request;
  }
}