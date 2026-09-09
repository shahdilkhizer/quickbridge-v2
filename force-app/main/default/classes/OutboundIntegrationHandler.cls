/**
 * Additive generic outbound integration runtime.
 *
 * The handler owns HTTP execution and delegates configuration, payload
 * construction, response mapping, and security validation to the generic
 * runtime support class. No provider-specific Apex class is resolved here.
 */
public without sharing class OutboundIntegrationHandler
  implements Database.Batchable<SObject>, Database.AllowsCallouts, Database.Stateful {
  private static final Integer MAX_RETRY_ATTEMPTS = 5;

  private ConnectorExecutionRequest request;
  private ConnectorExecutionResult aggregateResult;

  public OutboundIntegrationHandler(ConnectorExecutionRequest requestValue) {
    request = requestValue;
    aggregateResult = ConnectorExecutionResult.success();
  }

  public Database.QueryLocator start(Database.BatchableContext context) {
    try {
      GenericIntegrationRuntime.OperationDefinition definition = validateRequest();
      if (request.scheduleId != null) {
        Boolean leaseAccepted = ConnectorScheduleService.markRunning(
          request.scheduleId,
          request.leaseToken,
          context == null ? null : context.getJobId()
        );
        if (!leaseAccepted) {
          throw new OutboundIntegrationHandlerException(
            'Generic outbound execution no longer owns the schedule lease.'
          );
        }
      }
      Map<String, Object> bindVariables = new Map<String, Object>{
        'recordIds' => request.recordIds,
        'sinceValue' => request.sinceValue != null
          ? request.sinceValue
          : System.now().addDays(-30)
      };
      return Database.getQueryLocatorWithBinds(
        GenericIntegrationRuntime.buildSourceQuery(definition, request),
        bindVariables,
        AccessLevel.SYSTEM_MODE
      );
    } catch (Exception exceptionValue) {
      aggregateResult = ConnectorExecutionResult.failed(
        exceptionValue.getMessage(),
        false,
        null
      );
      return Database.getQueryLocator('SELECT Id FROM Account WHERE Id = NULL');
    }
  }

  public void execute(Database.BatchableContext context, List<SObject> scope) {
    if (scope == null || scope.isEmpty() || aggregateResult.hasFailures()) {
      return;
    }
    if (scope.size() > 100) {
      aggregateResult.mergeFrom(
        ConnectorExecutionResult.failed(
          'Generic outbound scope cannot exceed 100 records because each record may require a callout.',
          false,
          null
        )
      );
      return;
    }

    try {
      GenericIntegrationRuntime.OperationDefinition definition = validateRequest();
      SObjectAccessDecision readableDecision = Security.stripInaccessible(
        AccessType.READABLE,
        scope
      );
      scope = readableDecision.getRecords();
      Boolean collectionRequest = normalize(definition.requestCardinality) == 'collection';
      if (collectionRequest) {
        sendCollection(definition, scope);
      } else {
        sendRecords(definition, scope);
      }
      renewScheduleLease(context);
    } catch (Exception exceptionValue) {
      aggregateResult.mergeFrom(
        ConnectorExecutionResult.failed(
          exceptionValue.getMessage(),
          false,
          null
        )
      );
    }
  }

  public void finish(Database.BatchableContext context) {
    if (aggregateResult == null) {
      aggregateResult = ConnectorExecutionResult.failed(
        'Generic outbound execution returned no result.',
        false,
        null
      );
    }
    if (request != null && request.workItemId != null) {
      IntegrationWorkService.complete(
        request.workItemId,
        request,
        aggregateResult
      );
      return;
    }
    if (shouldRetry()) {
      scheduleRetry();
      return;
    }
    if (aggregateResult.hasFailures()) {
      completeFailure(aggregateResult.errorSummary);
      return;
    }
    ConnectorScheduleService.complete(
      request == null ? null : request.scheduleId,
      request == null ? null : request.leaseToken,
      aggregateResult
    );
  }

  private void sendCollection(
    GenericIntegrationRuntime.OperationDefinition definition,
    List<SObject> scope
  ) {
    ConnectorHttpClient.Response response = send(definition, scope);
    if (!response.successful) {
      ConnectorExecutionResult failure = failureFor(definition, response);
      failure.retryRecordIds.addAll(idsFrom(scope));
      aggregateResult.mergeFrom(failure);
      return;
    }
    ConnectorExecutionResult responseResult =
      normalize(definition.responseContentType) == 'binary'
        ? successfulResult(scope.size())
        : GenericIntegrationRuntime.persistOutboundResponse(
            definition,
            scope,
            response.body
          );
    aggregateResult.mergeFrom(responseResult);
    if (responseResult.hasFailures()) {
      aggregateResult.retryRecordIds.addAll(idsFrom(scope));
    }
  }

  private void sendRecords(
    GenericIntegrationRuntime.OperationDefinition definition,
    List<SObject> scope
  ) {
    List<SObject> successfulRecords = new List<SObject>();
    List<String> successfulBodies = new List<String>();
    for (SObject recordValue : scope) {
      ConnectorHttpClient.Response response;
      try {
        response = send(definition, new List<SObject>{ recordValue });
      } catch (Exception exceptionValue) {
        IntegrationRetryPolicy.RetryDecision retryDecision =
          IntegrationRetryPolicy.classify(exceptionValue);
        ConnectorExecutionResult failure = ConnectorExecutionResult.failed(
          exceptionValue.getMessage(),
          retryDecision.retryable,
          null
        );
        failure.httpStatusCode = retryDecision.httpStatusCode;
        failure.errorCategory = retryDecision.reasonCode;
        failure.classMethod = 'OutboundIntegrationHandler.sendRecords';
        failure.retryRecordIds.add(recordValue.Id);
        aggregateResult.mergeFrom(failure);
        continue;
      }
      if (!response.successful) {
        ConnectorExecutionResult failure = failureFor(definition, response);
        failure.retryRecordIds.add(recordValue.Id);
        aggregateResult.mergeFrom(failure);
        continue;
      }
      successfulRecords.add(recordValue);
      successfulBodies.add(response.body);
      aggregateResult.processedCount++;
      aggregateResult.successfulCount++;
    }

    if (!successfulRecords.isEmpty()) {
      ConnectorExecutionResult responseResult =
        normalize(definition.responseContentType) == 'binary'
          ? successfulResult(successfulRecords.size())
          : GenericIntegrationRuntime.persistOutboundResponses(
              definition,
              successfulRecords,
              successfulBodies
            );
      aggregateResult.failedCount += responseResult.failedCount;
      aggregateResult.successfulCount -= responseResult.failedCount;
      aggregateResult.addError(responseResult.errorSummary);
      if (responseResult.hasFailures()) {
        aggregateResult.retryRecordIds.addAll(idsFrom(successfulRecords));
      }
    }
  }

  private ConnectorHttpClient.Response send(
    GenericIntegrationRuntime.OperationDefinition definition,
    List<SObject> records
  ) {
    ConnectorHttpClient.RequestSpec requestSpec = new ConnectorHttpClient.RequestSpec();
    requestSpec.namedCredential = definition.namedCredential;
    requestSpec.relativeEndpoint = ConnectorHttpClient.appendQuery(
      definition.relativeEndpoint,
      GenericIntegrationRuntime.queryParametersFor(definition, request)
    );
    requestSpec.approvedBaseUrl = definition.approvedBaseUrl;
    requestSpec.method = String.isBlank(definition.httpMethod)
      ? 'POST'
      : definition.httpMethod.trim().toUpperCase();
    requestSpec.headers = GenericIntegrationRuntime.headersFor(definition);
    requestSpec.timeoutMilliseconds = definition.timeoutMilliseconds;
    requestSpec.pageNumber = request.pageNumber == null ? 1 : request.pageNumber;
    requestSpec.maximumPages = definition.maximumPages;
    if (
      requestSpec.method != 'GET' &&
      requestSpec.method != 'DELETE'
    ) {
      requestSpec.body = GenericIntegrationRuntime.buildRequestBody(
        definition,
        records,
        request
      );
    }
    return ConnectorHttpClient.send(requestSpec);
  }

  private GenericIntegrationRuntime.OperationDefinition validateRequest() {
    if (request == null) {
      throw new OutboundIntegrationHandlerException('Generic outbound request is required.');
    }
    if (GenericIntegrationRuntime.normalizeDirectionForHandler(request.direction) != 'Outbound') {
      throw new OutboundIntegrationHandlerException('Outbound handler requires an outbound operation.');
    }
    GenericIntegrationRuntime.validateRequestLimits(request);
    return GenericIntegrationRuntime.resolve(request);
  }

  private ConnectorExecutionResult failureFor(
    GenericIntegrationRuntime.OperationDefinition definition,
    ConnectorHttpClient.Response response
  ) {
    ConnectorExecutionResult failure = ConnectorExecutionResult.failed(
      response.errorSummary,
      GenericIntegrationRuntime.isRetryable(definition, response.statusCode),
      GenericIntegrationRuntime.retryDelaySeconds(definition, response)
    );
    failure.httpStatusCode = response.statusCode;
    failure.errorCategory = IntegrationRetryPolicy.classify(response.statusCode).reasonCode;
    failure.classMethod = 'OutboundIntegrationHandler.send';
    return failure;
  }

  private void renewScheduleLease(Database.BatchableContext context) {
    if (
      request == null ||
      request.scheduleId == null ||
      !ConnectorScheduleService.hasLeaseRefreshCapacity()
    ) {
      return;
    }
    if (
      !ConnectorScheduleService.markRunning(
        request.scheduleId,
        request.leaseToken,
        context == null ? null : context.getJobId()
      )
    ) {
      aggregateResult.mergeFrom(
        ConnectorExecutionResult.failed(
          'Generic outbound execution lost the schedule lease.',
          false,
          null
        )
      );
    }
  }

  private Boolean shouldRetry() {
    return request != null &&
      aggregateResult != null &&
      aggregateResult.retryable == true &&
      aggregateResult.retryRecordIds != null &&
      !aggregateResult.retryRecordIds.isEmpty() &&
      (request.retryAttempt == null || request.retryAttempt < MAX_RETRY_ATTEMPTS);
  }

  private void scheduleRetry() {
    Integer attempt = request.retryAttempt == null ? 0 : request.retryAttempt;
    ConnectorExecutionRequest retryRequest = copyRequest(request);
    retryRequest.recordIds = new List<Id>(aggregateResult.retryRecordIds);
    retryRequest.retryAttempt = attempt + 1;
    Integer delaySeconds = aggregateResult.retryDelaySeconds == null
      ? 60
      : Math.max(1, aggregateResult.retryDelaySeconds);
    if (delaySeconds > 3600) {
      completeFailure('Generic outbound retry delay exceeds one hour.');
      return;
    }
    Integer delayMinutes = Math.max(1, (Integer) Math.ceil(delaySeconds / 60.0));
    Id retryJobId = System.scheduleBatch(
      new OutboundIntegrationHandler(retryRequest),
      retryJobName(),
      delayMinutes,
      normalizedScopeSize()
    );
    ConnectorScheduleService.markRunning(
      request.scheduleId,
      request.leaseToken,
      retryJobId,
      delayMinutes * 60
    );
  }

  private void completeFailure(String message) {
    ConnectorScheduleService.completeFailure(
      request == null ? null : request.scheduleId,
      request == null ? null : request.leaseToken,
      ConnectorExecutionResult.sanitizeError(message)
    );
  }

  private static ConnectorExecutionResult successfulResult(Integer countValue) {
    ConnectorExecutionResult result = ConnectorExecutionResult.success();
    result.processedCount = countValue == null ? 0 : countValue;
    result.successfulCount = result.processedCount;
    return result;
  }

  private static List<Id> idsFrom(List<SObject> records) {
    List<Id> result = new List<Id>();
    for (SObject recordValue : records == null ? new List<SObject>() : records) {
      if (recordValue != null && recordValue.Id != null) {
        result.add(recordValue.Id);
      }
    }
    return result;
  }

  private Integer normalizedScopeSize() {
    if (request == null || request.scopeSize == null || request.scopeSize < 1) {
      return 1;
    }
    return Math.min(100, request.scopeSize);
  }

  private static ConnectorExecutionRequest copyRequest(
    ConnectorExecutionRequest source
  ) {
    ConnectorExecutionRequest result = new ConnectorExecutionRequest();
    result.connectorKey = source.connectorKey;
    result.operationKey = source.operationKey;
    result.direction = source.direction;
    result.salesforceObject = source.salesforceObject;
    result.externalEntity = source.externalEntity;
    result.recordIds = source.recordIds == null
      ? new List<Id>()
      : new List<Id>(source.recordIds);
    result.cursor = source.cursor;
    result.sinceValue = source.sinceValue;
    result.initialSync = source.initialSync;
    result.scopeSize = source.scopeSize;
    result.payload = source.payload;
    result.correlationKey = source.correlationKey;
    result.scheduleId = source.scheduleId;
    result.workItemId = source.workItemId;
    result.leaseToken = source.leaseToken;
    result.pageNumber = source.pageNumber;
    result.retryAttempt = source.retryAttempt;
    return result;
  }

  private static String retryJobName() {
    String seed = String.valueOf(Datetime.now().getTime()) + ':' + Math.random();
    String suffix = EncodingUtil.convertToHex(
        Crypto.generateDigest('SHA-256', Blob.valueOf(seed))
      )
      .substring(0, 10);
    return 'GenericOutboundRetry_' + Datetime.now().getTime() + '_' + suffix;
  }

  private static String normalize(String value) {
    return String.isBlank(value) ? '' : value.toLowerCase().replaceAll('[^a-z0-9]', '');
  }

  public class OutboundIntegrationHandlerException extends Exception {}
}