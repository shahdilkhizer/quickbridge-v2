public without sharing class HostedPaymentSupport {
  public static ConnectorHttpClient.Response post(
    String connectorKey,
    String endpoint,
    String body,
    String contentType,
    String idempotencyKey
  ) {
    ConnectorHttpClient.RequestSpec spec = new ConnectorHttpClient.RequestSpec();
    spec.namedCredential = ConnectorConfigService.namedCredentialFor(connectorKey);
    spec.relativeEndpoint = endpoint;
    spec.method = 'POST';
    spec.body = body;
    spec.headers.put('Accept', 'application/json');
    spec.headers.put('Content-Type', contentType);
    if (String.isNotBlank(idempotencyKey)) {
      spec.headers.put('Idempotency-Key', idempotencyKey.left(255));
    }
    return ConnectorHttpClient.send(spec);
  }

  public static HostedPaymentResult failure(ConnectorHttpClient.Response response) {
    HostedPaymentResult result = new HostedPaymentResult();
    result.retryable = response != null && response.retryable;
    result.httpStatusCode = response == null ? null : response.statusCode;
    result.errorSummary = ConnectorExecutionResult.sanitizeError(
      response == null ? 'The payment provider returned no response.' : response.errorSummary
    );
    return result;
  }

  public static Map<String, Object> objectBody(ConnectorHttpClient.Response response) {
    if (response == null || String.isBlank(response.body)) return new Map<String, Object>();
    try {
      return (Map<String, Object>) JSON.deserializeUntyped(response.body);
    } catch (Exception error) {
      throw new AuraHandledException('The payment provider returned malformed JSON.');
    }
  }

  public static String stringValue(Map<String, Object> values, String key) {
    Object value = values == null ? null : values.get(key);
    return value == null ? null : String.valueOf(value);
  }
}