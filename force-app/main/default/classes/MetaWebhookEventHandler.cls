public without sharing class MetaWebhookEventHandler implements WebhookEventHandler {
  public ConnectorExecutionResult handle(String body, Map<String, String> headers) {
    String secret = ConnectorSecretService.getActiveSecret('meta', 'webhookSigningSecret');
    if (!WebhookWorkService.verifyHexHmac(
      'HmacSHA256', body,
      WebhookWorkService.header(headers, 'X-Hub-Signature-256'),
      'sha256=', secret
    )) {
      return ConnectorExecutionResult.failed('Webhook signature verification failed.', false, null);
    }
    String eventId = WebhookWorkService.jsonString(body, 'entry.0.id');
    if (String.isBlank(eventId)) {
      eventId = EncodingUtil.convertToHex(
        Crypto.generateDigest('SHA-256', Blob.valueOf(body == null ? '' : body))
      );
    }
    return WebhookWorkService.enqueue('meta', 'WebhookEvent', eventId, body);
  }
}