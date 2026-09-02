public abstract without sharing class RestPaymentProviderAdapter
  implements PaymentProviderAdapter {
  protected abstract String connectorKey();
  protected abstract String endpoint(String operation, PaymentCapabilityRequest request);
  protected abstract String body(String operation, PaymentCapabilityRequest request);

  protected virtual String contentType() { return 'application/json'; }
  protected virtual String referencePath() { return 'id'; }
  protected virtual String statusPath() { return 'status'; }
  protected virtual String actionTokenPath() { return 'client_secret'; }

  public PaymentCapabilityResult initializePayment(PaymentCapabilityRequest request) {
    return send('initialize', request, false);
  }
  public PaymentCapabilityResult executePayment(PaymentCapabilityRequest request) {
    return send('execute', request, true);
  }
  public PaymentCapabilityResult recoverPayment(PaymentCapabilityRequest request) {
    return send('recover', request, true);
  }
  public PaymentCapabilityResult refundPayment(PaymentCapabilityRequest request) {
    return send('refund', request, true);
  }

  private PaymentCapabilityResult send(
    String operation,
    PaymentCapabilityRequest request,
    Boolean requireIdempotency
  ) {
    String validationError = validateRequest(request, operation, requireIdempotency);
    if (validationError != null) return failed(validationError, false, null, null);
    ConnectorHttpClient.RequestSpec spec = new ConnectorHttpClient.RequestSpec();
    spec.namedCredential = ConnectorConfigService.namedCredentialFor(connectorKey());
    spec.relativeEndpoint = endpoint(operation, request);
    spec.method = operation == 'recover' ? 'GET' : 'POST';
    spec.body = operation == 'recover' ? null : body(operation, request);
    spec.headers.put('Accept', 'application/json');
    if (spec.body != null) spec.headers.put('Content-Type', contentType());
    if (String.isNotBlank(request.idempotencyKey)) {
      spec.headers.put('Idempotency-Key', request.idempotencyKey.left(255));
    }
    try {
      return fromResponse(ConnectorHttpClient.send(spec));
    } catch (Exception submissionFailure) {
      if (operation == 'execute') {
        try {
          PaymentCapabilityResult recovered = recoverPayment(request);
          if (recovered.successful || recovered.requiresAction) return recovered;
        } catch (Exception ignored) {
        }
      }
      return failed(submissionFailure.getMessage(), true, null, null);
    }
  }

  private String validateRequest(
    PaymentCapabilityRequest request,
    String operation,
    Boolean requireIdempotency
  ) {
    if (request == null) return 'A payment request is required.';
    if (!normalize(request.connectorKey).equals(normalize(connectorKey()))) {
      return 'The payment request does not match the selected provider.';
    }
    if (requireIdempotency && String.isBlank(request.idempotencyKey)) {
      return 'A stable idempotency key is required for payment mutations.';
    }
    if (
      operation != 'recover' && operation != 'refund' &&
      (request.amount == null || request.amount <= 0)
    ) {
      return 'A positive payment amount is required.';
    }
    if (operation == 'execute' && String.isBlank(request.providerToken)) {
      return 'A browser-generated provider token is required.';
    }
    Set<String> prohibited = new Set<String>{
      'pan', 'cardnumber', 'cvv', 'cvc', 'securitycode', 'expiry',
      'expirationdate', 'trackdata'
    };
    if (request.attributes != null) {
      for (String key : request.attributes.keySet()) {
        if (key != null && prohibited.contains(normalize(key))) {
          return 'Raw card data must never be sent to Salesforce.';
        }
      }
    }
    return null;
  }

  private PaymentCapabilityResult fromResponse(
    ConnectorHttpClient.Response response
  ) {
    if (response == null || !response.successful) {
      return failed(
        response == null ? 'The payment provider returned no response.' : response.errorSummary,
        response != null && response.retryable,
        response == null ? null : response.statusCode,
        null
      );
    }
    PaymentCapabilityResult result = new PaymentCapabilityResult();
    result.successful = true;
    result.httpStatusCode = response.statusCode;
    result.providerReference = stringAt(response.body, referencePath());
    result.status = stringAt(response.body, statusPath());
    result.clientActionToken = stringAt(response.body, actionTokenPath());
    String normalizedStatus = normalize(result.status);
    result.requiresAction = normalizedStatus.contains('requiresaction') ||
      normalizedStatus.contains('pendingpayeraction') ||
      normalizedStatus.contains('3dsecure');
    return result;
  }

  public static String jsonBody(Map<String, Object> values) {
    return JSON.serialize(values == null ? new Map<String, Object>() : values);
  }

  public static String urlEncoded(Map<String, String> values) {
    List<String> keys = new List<String>(values.keySet());
    keys.sort();
    List<String> pairs = new List<String>();
    for (String key : keys) {
      if (values.get(key) != null) {
        pairs.add(
          EncodingUtil.urlEncode(key, 'UTF-8') + '=' +
          EncodingUtil.urlEncode(values.get(key), 'UTF-8')
        );
      }
    }
    return String.join(pairs, '&');
  }

  private static String stringAt(String bodyValue, String path) {
    Object value = ConnectorHealthProbeSupport.jsonValue(bodyValue, path);
    return value == null ? null : String.valueOf(value);
  }

  private static PaymentCapabilityResult failed(
    String message,
    Boolean retryable,
    Integer statusCode,
    String statusValue
  ) {
    PaymentCapabilityResult result = new PaymentCapabilityResult();
    result.errorSummary = ConnectorExecutionResult.sanitizeError(message);
    result.retryable = retryable == true;
    result.httpStatusCode = statusCode;
    result.status = statusValue;
    return result;
  }

  private static String normalize(String value) {
    return String.isBlank(value)
      ? ''
      : value.trim().toLowerCase().replaceAll('[^a-z0-9]', '');
  }
}