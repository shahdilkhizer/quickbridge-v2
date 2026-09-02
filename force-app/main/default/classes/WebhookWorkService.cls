public without sharing class WebhookWorkService {
  public static ConnectorExecutionResult enqueue(
    String connectorKey,
    String operationKey,
    String eventId,
    String body
  ) {
    if (String.isBlank(eventId)) {
      return ConnectorExecutionResult.failed(
        'A provider event identifier is required.',
        false,
        null
      );
    }
    IntegrationWorkRequest request = new IntegrationWorkRequest();
    request.connectorKey = connectorKey;
    request.operationKey = operationKey;
    request.sourceObject = 'Webhook';
    request.sourceExternalId = eventId.left(255);
    request.payload = body;
    request.lockKey = connectorKey.toLowerCase() + ':webhook:' + eventId.left(180);
    request.maximumAttempts = 5;
    List<Id> workIds = IntegrationWorkService.enqueue(
      new List<IntegrationWorkRequest>{ request }
    );
    ConnectorExecutionResult result = ConnectorExecutionResult.success();
    result.processedCount = 1;
    result.successfulCount = workIds.isEmpty() ? 0 : 1;
    result.failedCount = workIds.isEmpty() ? 1 : 0;
    if (workIds.isEmpty()) result.addError('The webhook could not be queued.');
    return result;
  }

  public static String header(Map<String, String> headers, String name) {
    if (headers == null || String.isBlank(name)) return null;
    for (String key : headers.keySet()) {
      if (key != null && key.equalsIgnoreCase(name)) return headers.get(key);
    }
    return null;
  }

  public static String jsonString(String body, String path) {
    Object value = ConnectorHealthProbeSupport.jsonValue(body, path);
    return value == null ? null : String.valueOf(value);
  }

  public static Boolean verifyHexHmac(
    String algorithm,
    String body,
    String supplied,
    String prefix,
    String secret
  ) {
    if (String.isBlank(supplied) || String.isBlank(secret)) return false;
    String candidate = supplied.trim().toLowerCase();
    if (String.isNotBlank(prefix) && candidate.startsWith(prefix.toLowerCase())) {
      candidate = candidate.substring(prefix.length());
    }
    if (!HmacRequestVerifier.isHexValue(candidate)) return false;
    String expected = EncodingUtil.convertToHex(
      Crypto.generateMac(
        algorithm,
        Blob.valueOf(body == null ? '' : body),
        Blob.valueOf(secret)
      )
    ).toLowerCase();
    return candidate == expected;
  }
}