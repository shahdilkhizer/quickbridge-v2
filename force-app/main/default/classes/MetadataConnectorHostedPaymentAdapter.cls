/**
 * Generic hosted-payment adapter. It only accepts a provider-neutral hosted
 * payment request and obtains all transport details from connector configuration.
 */
public without sharing class MetadataConnectorHostedPaymentAdapter
  implements HostedPaymentProviderAdapter, ConnectorBoundAdapter {
  private String boundConnectorKey;

  public void bindConnector(String connectorKey) {
    boundConnectorKey = MetadataConnectorAdapterSupport.requireConnectorKey(connectorKey);
  }

  public HostedPaymentResult createHostedPayment(HostedPaymentRequest request) {
    String validationError = validate(request);
    if (validationError != null) return failed(validationError, false, null);
    String endpoint = ConnectorConfigService.getConfigValue(
      boundConnectorKey,
      'hostedPaymentPath'
    );
    if (String.isBlank(endpoint)) {
      return failed('The hosted payment endpoint is not configured.', false, null);
    }
    ConnectorHttpClient.RequestSpec specification =
      new ConnectorHttpClient.RequestSpec();
    specification.namedCredential = ConnectorConfigService.namedCredentialFor(
      boundConnectorKey
    );
    specification.relativeEndpoint = endpoint;
    specification.method = 'POST';
    specification.headers.put('Accept', 'application/json');
    specification.headers.put('Content-Type', 'application/json');
    specification.headers.put('Idempotency-Key', request.idempotencyKey.left(255));
    specification.body = JSON.serialize(new Map<String, Object>{
      'sourceRecordId' => request.sourceRecordId,
      'amount' => request.amount,
      'currencyCode' => request.currencyCode,
      'referenceNumber' => request.referenceNumber,
      'customerEmail' => request.customerEmail,
      'customerName' => request.customerName,
      'description' => request.description,
      'dueDate' => request.dueDate,
      'idempotencyKey' => request.idempotencyKey
    });
    try {
      ConnectorHttpClient.Response response = ConnectorHttpClient.send(specification);
      if (response == null || !response.successful) {
        return failed(
          response == null ? 'The hosted payment provider returned no response.' :
            response.errorSummary,
          response != null && response.retryable,
          response == null ? null : response.statusCode
        );
      }
      HostedPaymentResult result = new HostedPaymentResult();
      result.successful = true;
      result.httpStatusCode = response.statusCode;
      result.providerReference = stringAt(response.body, responsePath('hostedPaymentReferencePath', 'id'));
      result.status = stringAt(response.body, responsePath('hostedPaymentStatusPath', 'status'));
      result.hostedUrl = stringAt(response.body, responsePath('hostedPaymentUrlPath', 'url'));
      result.formToken = stringAt(response.body, responsePath('hostedPaymentFormTokenPath', 'formToken'));
      result.launchMode = String.isBlank(result.hostedUrl) ? 'form' : 'redirect';
      return result;
    } catch (Exception failure) {
      return failed(failure.getMessage(), true, null);
    }
  }

  private String validate(HostedPaymentRequest request) {
    if (String.isBlank(boundConnectorKey)) return 'The dynamic hosted payment adapter is not bound.';
    if (request == null) return 'A hosted payment request is required.';
    if (!MetadataConnectorAdapterSupport.matches(boundConnectorKey, request.connectorKey)) {
      return 'The hosted payment request does not match the selected provider.';
    }
    if (request.amount == null || request.amount <= 0) {
      return 'A positive hosted payment amount is required.';
    }
    if (String.isBlank(request.customerEmail)) {
      return 'A hosted payment customer email is required.';
    }
    if (String.isBlank(request.idempotencyKey)) {
      return 'A stable idempotency key is required for hosted payments.';
    }
    return null;
  }

  private String responsePath(String fieldKey, String defaultValue) {
    String value = ConnectorConfigService.getConfigValue(boundConnectorKey, fieldKey);
    return String.isBlank(value) ? defaultValue : value;
  }

  private static String stringAt(String body, String path) {
    Object value = ConnectorHealthProbeSupport.jsonValue(body, path);
    return value == null ? null : String.valueOf(value);
  }

  private static HostedPaymentResult failed(
    String message,
    Boolean retryable,
    Integer statusCode
  ) {
    HostedPaymentResult result = new HostedPaymentResult();
    result.retryable = retryable == true;
    result.httpStatusCode = statusCode;
    result.errorSummary = ConnectorExecutionResult.sanitizeError(message);
    return result;
  }
}