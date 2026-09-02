public abstract without sharing class RestCarrierAdapter implements CarrierAdapter {
  protected abstract String connectorKey();
  protected abstract String defaultEndpoint(String operation);

  public ConnectorExecutionResult validateAddress(Map<String, Object> payload) {
    return send('addressValidation', 'POST', payload, false);
  }
  public ConnectorExecutionResult quoteRates(Map<String, Object> payload) {
    return send('rateQuote', 'POST', payload, false);
  }
  public ConnectorExecutionResult createShipment(Map<String, Object> payload) {
    return send('createShipment', 'POST', payload, true);
  }
  public ConnectorExecutionResult recoverLabel(Map<String, Object> payload) {
    return send('recoverLabel', 'POST', payload, true);
  }
  public ConnectorExecutionResult createReturnLabel(Map<String, Object> payload) {
    return send('createReturn', 'POST', payload, true);
  }
  public ConnectorExecutionResult voidShipment(Map<String, Object> payload) {
    return send('voidShipment', 'POST', payload, true);
  }
  public ConnectorExecutionResult synchronizeTracking(Map<String, Object> payload) {
    return send('tracking', 'POST', payload, false);
  }

  private ConnectorExecutionResult send(
    String operation,
    String method,
    Map<String, Object> payload,
    Boolean requireIdempotency
  ) {
    Map<String, Object> safePayload = payload == null
      ? new Map<String, Object>()
      : payload;
    rejectSecrets(safePayload);
    String idempotencyKey = stringValue(safePayload.get('idempotencyKey'));
    if (requireIdempotency && String.isBlank(idempotencyKey)) {
      return ConnectorExecutionResult.failed(
        'A stable idempotency key is required for carrier mutations.',
        false,
        null
      );
    }
    String endpoint = ConnectorConfigService.getConfigValue(
      connectorKey(),
      operation + 'Path'
    );
    if (String.isBlank(endpoint)) endpoint = defaultEndpoint(operation);
    ConnectorHttpClient.RequestSpec spec = new ConnectorHttpClient.RequestSpec();
    spec.namedCredential = ConnectorConfigService.namedCredentialFor(connectorKey());
    spec.relativeEndpoint = endpoint;
    spec.method = method;
    spec.body = JSON.serialize(safePayload);
    spec.headers.put('Accept', 'application/json');
    spec.headers.put('Content-Type', 'application/json');
    if (String.isNotBlank(idempotencyKey)) {
      spec.headers.put('Idempotency-Key', idempotencyKey.left(255));
    }
    try {
      return resultFrom(ConnectorHttpClient.send(spec));
    } catch (Exception submissionFailure) {
      if (requireIdempotency && String.isNotBlank(idempotencyKey)) {
        ConnectorExecutionResult recovered = lookupAfterAmbiguousFailure(
          operation,
          idempotencyKey
        );
        if (recovered != null) return recovered;
      }
      ConnectorExecutionResult result = ConnectorExecutionResult.failed(
        submissionFailure.getMessage(),
        true,
        null
      );
      result.errorCategory = 'Carrier Transport';
      return result;
    }
  }

  private ConnectorExecutionResult lookupAfterAmbiguousFailure(
    String operation,
    String idempotencyKey
  ) {
    String lookupPath = ConnectorConfigService.getConfigValue(
      connectorKey(),
      operation + 'LookupPath'
    );
    if (String.isBlank(lookupPath)) return null;
    lookupPath = lookupPath.replace(
      '{idempotencyKey}',
      EncodingUtil.urlEncode(idempotencyKey, 'UTF-8')
    );
    ConnectorHttpClient.RequestSpec lookup = new ConnectorHttpClient.RequestSpec();
    lookup.namedCredential = ConnectorConfigService.namedCredentialFor(connectorKey());
    lookup.relativeEndpoint = lookupPath;
    lookup.method = 'GET';
    lookup.headers.put('Accept', 'application/json');
    try {
      ConnectorExecutionResult recovered = resultFrom(
        ConnectorHttpClient.send(lookup)
      );
      return recovered.hasFailures() ? null : recovered;
    } catch (Exception ignored) {
      return null;
    }
  }

  private static ConnectorExecutionResult resultFrom(
    ConnectorHttpClient.Response response
  ) {
    if (response != null && response.successful) {
      ConnectorExecutionResult result = ConnectorExecutionResult.success();
      result.processedCount = 1;
      result.successfulCount = 1;
      result.httpStatusCode = response.statusCode;
      return result;
    }
    ConnectorExecutionResult failure = ConnectorExecutionResult.failed(
      response == null ? 'The carrier returned no response.' : response.errorSummary,
      response != null && response.retryable,
      response == null ? null : response.retryAfterSeconds
    );
    failure.httpStatusCode = response == null ? null : response.statusCode;
    failure.errorCategory = 'Carrier API';
    return failure;
  }

  private static void rejectSecrets(Map<String, Object> payload) {
    Set<String> forbidden = new Set<String>{
      'password', 'secret', 'token', 'accesstoken', 'authorization',
      'clientsecret', 'apikey'
    };
    for (String key : payload.keySet()) {
      if (key != null && forbidden.contains(key.toLowerCase().replaceAll('[^a-z0-9]', ''))) {
        throw new RestCarrierAdapterException(
          'Credentials must be supplied by the External Credential, not the carrier payload.'
        );
      }
    }
  }

  private static String stringValue(Object value) {
    return value == null ? null : String.valueOf(value);
  }

  public class RestCarrierAdapterException extends Exception {}
}