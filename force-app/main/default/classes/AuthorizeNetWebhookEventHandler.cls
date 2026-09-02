public without sharing class AuthorizeNetWebhookEventHandler implements WebhookEventHandler {
  public ConnectorExecutionResult handle(String body, Map<String, String> headers) {
    String secret = ConnectorSecretService.getActiveSecret(
      'authorizenet',
      'webhookSigningSecret'
    );
    if (!WebhookWorkService.verifyHexHmac(
      'HmacSHA512', body,
      WebhookWorkService.header(headers, 'X-ANET-Signature'),
      'sha512=', secret
    )) {
      return ConnectorExecutionResult.failed('Webhook signature verification failed.', false, null);
    }
    return WebhookWorkService.enqueue(
      'authorizenet',
      'WebhookEvent',
      WebhookWorkService.jsonString(body, 'notificationId'),
      body
    );
  }
}