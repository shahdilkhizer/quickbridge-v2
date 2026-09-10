/**
 * Additive generic inbound integration runtime.
 *
 * Provider-specific batches are intentionally not referenced here. Operation
 * transport, pagination, response paths, mappings, and persistence are read
 * from Integration_Operation__mdt and Integration_Operation_Mapping__mdt.
 */
public without sharing class InboundIntegrationHandler
  implements Database.Batchable<Integer>, Database.AllowsCallouts, Database.Stateful {
  private static final Integer MAX_RETRY_ATTEMPTS = 5;

  private ConnectorExecutionRequest request;
  private ConnectorExecutionResult aggregateResult;
  private Integer maximumPages;

  public InboundIntegrationHandler(ConnectorExecutionRequest requestValue) {
    request = requestValue;
    aggregateResult = ConnectorExecutionResult.success();
    maximumPages = ConnectorHttpClient.DEFAULT_MAX_PAGES;
  }

  public Iterable<Integer> start(Database.BatchableContext context) {
    try {
      GenericIntegrationRuntime.OperationDefinition definition = validateRequest();
      maximumPages = definition.maximumPages;
      if (String.isNotBlank(definition.resourceContractJson) && !GenericResourceRateLimit.reserve(request.connectorKey, 1)) {
        aggregateResult = ConnectorExecutionResult.failed('Connector transport capacity is reserved; retry next minute.', true, 60);
        return new List<Integer>();
      }
      if (request.scheduleId != null) {
        Boolean leaseAccepted = ConnectorScheduleService.markRunning(
          request.scheduleId,
          request.leaseToken,
          context == null ? null : context.getJobId()
        );
        if (!leaseAccepted) {
          throw new InboundIntegrationHandlerException(
            'Generic inbound execution no longer owns the schedule lease.'
          );
        }
      }
      return new List<Integer>{ 1 };
    } catch (Exception exceptionValue) {
      aggregateResult = ConnectorExecutionResult.failed(
        exceptionValue.getMessage(),
        false,
        null
      );
      return new List<Integer>();
    }
  }

  public void execute(Database.BatchableContext context, List<Integer> scope) {
    if (scope == null || scope.isEmpty() || aggregateResult.hasFailures()) {
      return;
    }
    try {
      GenericIntegrationRuntime.OperationDefinition definition = validateRequest();
      ConnectorHttpClient.RequestSpec requestSpec = new ConnectorHttpClient.RequestSpec();
      requestSpec.namedCredential = definition.namedCredential;
      requestSpec.relativeEndpoint = ConnectorHttpClient.appendQuery(
        definition.relativeEndpoint,
        GenericIntegrationRuntime.queryParametersFor(definition, request)
      );
      if (String.isNotBlank(request.cursor) && definition.paginationType == 'linkheader') {
        requestSpec.relativeEndpoint = request.cursor;
      }
      requestSpec.approvedBaseUrl = definition.approvedBaseUrl;
      requestSpec.method = String.isBlank(definition.httpMethod)
        ? 'GET'
        : definition.httpMethod;
      requestSpec.headers = GenericIntegrationRuntime.headersFor(definition);
      requestSpec.timeoutMilliseconds = definition.timeoutMilliseconds;
      requestSpec.pageNumber = request.pageNumber == null ? 1 : request.pageNumber;
      requestSpec.maximumPages = definition.maximumPages;
      if (String.isNotBlank(request.payload)) {
        requestSpec.body = request.payload;
      }

      ConnectorHttpClient.Response response = ConnectorHttpClient.send(requestSpec);
      if (!response.successful) {
        aggregateResult.mergeFrom(
          ConnectorExecutionResult.failed(
            response.errorSummary,
            GenericIntegrationRuntime.isRetryable(definition, response.statusCode),
            GenericIntegrationRuntime.retryDelaySeconds(definition, response)
          )
        );
      } else {
        ConnectorExecutionResult pageResult =
          normalize(definition.responseContentType) == 'binary'
            ? successfulBinaryResult()
            : GenericIntegrationRuntime.persistInbound(definition, response.body);
        if (!pageResult.hasFailures()) {
          pageResult.nextCursor = GenericIntegrationRuntime.nextCursor(
            definition,
            response,
            request,
            normalize(definition.responseContentType) == 'binary'
              ? 1
              : GenericIntegrationRuntime.responseRows(definition, response.body).size()
          );
        }
        aggregateResult.mergeFrom(pageResult);
      }
      renewScheduleLease(context);
    } catch (Exception exceptionValue) {
      GenericIntegrationRuntime.OperationDefinition definition;
      try {
        definition = validateRequest();
      } catch (Exception ignored) {
        definition = null;
      }
      aggregateResult.mergeFrom(
        ConnectorExecutionResult.failed(
          exceptionValue.getMessage(),
          definition != null &&
            (GenericIntegrationRuntime.isRetryable(definition, null) ||
            IntegrationRetryPolicy.isRetryable(exceptionValue)),
          definition == null ? null : GenericIntegrationRuntime.retryDelaySeconds(definition, null)
        )
      );
    }
  }

  public void finish(Database.BatchableContext context) {
    if (aggregateResult == null) {
      completeFailure('Generic inbound execution returned no result.');
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

    if (String.isNotBlank(aggregateResult.nextCursor)) {
      Integer currentPage = request.pageNumber == null ? 1 : request.pageNumber;
      if (aggregateResult.nextCursor == request.cursor) {
        completeFailure('Generic inbound pagination returned a repeated cursor.');
        return;
      }
      if (currentPage >= maximumPages) {
        completeFailure(
          'Generic inbound pagination exceeded ' + maximumPages + ' pages.'
        );
        return;
      }
      ConnectorExecutionRequest nextRequest = copyRequest(request);
      nextRequest.cursor = aggregateResult.nextCursor;
      nextRequest.pageNumber = currentPage + 1;
      nextRequest.retryAttempt = 0;
      Id nextJobId = Database.executeBatch(
        new InboundIntegrationHandler(nextRequest),
        1
      );
      if (
        request.scheduleId != null &&
        !ConnectorScheduleService.markRunning(
          request.scheduleId,
          request.leaseToken,
          nextJobId
        )
      ) {
        completeFailure('Generic inbound execution lost the schedule lease.');
      }
      return;
    }
    if (request != null && request.scheduleId != null && request.syncStartedAt != null) {
      List<Scheduled_Integration_Job__c> checkpointRows = [SELECT Id, Lease_Token__c FROM Scheduled_Integration_Job__c WHERE Id = :request.scheduleId FOR UPDATE];
      if (checkpointRows.isEmpty() || checkpointRows[0].Lease_Token__c != request.leaseToken) {
        completeFailure('Inbound checkpoint no longer owns the schedule lease.');
        return;
      }
      checkpointRows[0].Sync_Watermark__c = request.syncStartedAt;
      update checkpointRows;
    }
    ConnectorScheduleService.completeSuccess(
      request == null ? null : request.scheduleId,
      request == null ? null : request.leaseToken
    );
  }

  public class EventResponse {
    public Integer statusCode { get; private set; }
    public String message { get; private set; }
    public String idempotencyKey { get; private set; }
    public ConnectorExecutionResult result { get; private set; }

    private EventResponse(
      Integer statusValue,
      String messageValue,
      String idempotencyValue,
      ConnectorExecutionResult resultValue
    ) {
      statusCode = statusValue;
      message = messageValue;
      idempotencyKey = idempotencyValue;
      result = resultValue;
    }
  }

  public static EventResponse receiveEvent(
    String connectorKey,
    String operationKey,
    String payload,
    Map<String, String> headers
  ) {
    Boolean signatureConfigured = false;
    try {
      ConnectorExecutionRequest eventRequest = new ConnectorExecutionRequest();
      eventRequest.connectorKey = connectorKey;
      eventRequest.operationKey = operationKey;
      eventRequest.direction = ConnectorExecutionRequest.DIRECTION_INBOUND;
      eventRequest.payload = payload;
      GenericIntegrationRuntime.validateRequestLimits(eventRequest);
      GenericIntegrationRuntime.OperationDefinition definition =
        GenericIntegrationRuntime.resolve(eventRequest);
      signatureConfigured = String.isNotBlank(definition.inboundSignatureHeader);
      GenericIntegrationRuntime.validateInboundEvent(definition, payload, headers);

      String idempotencyKey = null;
      Object parsed = null;
      if (String.isNotBlank(definition.inboundIdempotencyPath)) {
        parsed = GenericIntegrationRuntime.parseResponseBody(payload);
        Object idempotencyValue = GenericIntegrationRuntime.valueAtPath(
          parsed,
          definition.inboundIdempotencyPath
        );
        if (idempotencyValue == null || String.isBlank(String.valueOf(idempotencyValue))) {
          throw new InboundIntegrationHandlerException(
            'Configured inbound idempotency path returned no value.'
          );
        }
        idempotencyKey =
          connectorKey + ':' + operationKey + ':' + String.valueOf(idempotencyValue);
        List<Integration_Work_Item__c> existing = [
          SELECT Id
          FROM Integration_Work_Item__c
          WHERE Unique_Key__c = :idempotencyKey
          LIMIT 1
        ];
        if (!existing.isEmpty()) {
          ConnectorExecutionResult duplicateResult = ConnectorExecutionResult.success();
          duplicateResult.processedCount = 1;
          duplicateResult.successfulCount = 1;
          return new EventResponse(200, 'Duplicate event ignored.', idempotencyKey, duplicateResult);
        }
      }

      ConnectorExecutionResult result = normalize(definition.responseContentType) == 'binary'
        ? successfulBinaryResult()
        : GenericIntegrationRuntime.persistInbound(definition, payload);
      if (!result.hasFailures() && String.isNotBlank(idempotencyKey)) {
        Integration_Work_Item__c workItem = new Integration_Work_Item__c(
          Unique_Key__c = idempotencyKey,
          Integration__c = connectorKey,
          Operation__c = operationKey,
          Status__c = 'Completed',
          Completed_At__c = System.now(),
          Payload_Hash__c = EncodingUtil.convertToHex(
            Crypto.generateDigest('SHA-256', Blob.valueOf(payload == null ? '' : payload))
          ),
          Payload__c = payload
        );
        SObjectAccessDecision workItemDecision = Security.stripInaccessible(
          AccessType.CREATABLE,
          new List<SObject>{ workItem }
        );
        Database.insert(workItemDecision.getRecords(), false);
      }
      return new EventResponse(
        result.hasFailures() ? 500 : 200,
        result.hasFailures() ? result.errorSummary : 'Inbound event processed.',
        idempotencyKey,
        result
      );
    } catch (Exception exceptionValue) {
      ConnectorExecutionResult result = ConnectorExecutionResult.failed(
        exceptionValue.getMessage(),
        false,
        null
      );
      Integer statusCode = signatureConfigured ||
        (exceptionValue.getMessage() != null &&
        (exceptionValue.getMessage().contains('signature') ||
        exceptionValue.getMessage().contains('timestamp')))
        ? 401
        : 500;
      return new EventResponse(statusCode, result.errorSummary, null, result);
    }
  }

  private GenericIntegrationRuntime.OperationDefinition validateRequest() {
    if (request == null) {
      throw new InboundIntegrationHandlerException('Generic inbound request is required.');
    }
    if (GenericIntegrationRuntime.normalizeDirectionForHandler(request.direction) != 'Inbound') {
      throw new InboundIntegrationHandlerException('Inbound handler requires an inbound operation.');
    }
    GenericIntegrationRuntime.validateRequestLimits(request);
    return GenericIntegrationRuntime.resolve(request);
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
          'Generic inbound execution lost the schedule lease.',
          false,
          null
        )
      );
    }
  }

  private Boolean shouldRetry() {
    return request != null &&
      aggregateResult != null &&
      aggregateResult.hasFailures() &&
      aggregateResult.retryable == true &&
      (request.retryAttempt == null || request.retryAttempt < MAX_RETRY_ATTEMPTS);
  }

  private void scheduleRetry() {
    Integer attempt = request.retryAttempt == null ? 0 : request.retryAttempt;
    ConnectorExecutionRequest retryRequest = copyRequest(request);
    retryRequest.retryAttempt = attempt + 1;
    Integer delaySeconds = aggregateResult.retryDelaySeconds == null
      ? 60
      : Math.max(1, aggregateResult.retryDelaySeconds);
    if (delaySeconds > 3600) {
      completeFailure('Generic inbound retry delay exceeds one hour.');
      return;
    }
    Integer delayMinutes = Math.max(1, (Integer) Math.ceil(delaySeconds / 60.0));
    Id retryJobId = System.scheduleBatch(
      new InboundIntegrationHandler(retryRequest),
      retryJobName(),
      delayMinutes,
      1
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

  private static ConnectorExecutionResult successfulBinaryResult() {
    ConnectorExecutionResult result = ConnectorExecutionResult.success();
    result.processedCount = 1;
    result.successfulCount = 1;
    return result;
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
    result.syncStartedAt = source.syncStartedAt;
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
    return 'GenericInboundRetry_' + Datetime.now().getTime() + '_' + suffix;
  }

  private static String normalize(String value) {
    return String.isBlank(value) ? '' : value.toLowerCase().replaceAll('[^a-z0-9]', '');
  }

  public class InboundIntegrationHandlerException extends Exception {}
}