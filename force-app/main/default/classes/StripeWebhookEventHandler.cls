public without sharing class StripeWebhookEventHandler implements WebhookEventHandler {
  public ConnectorExecutionResult handle(String body, Map<String, String> headers) {
    String signature = WebhookWorkService.header(headers, 'Stripe-Signature');
    Map<String, String> parts = new Map<String, String>();
    if (String.isNotBlank(signature)) {
      for (String part : signature.split(',')) {
        List<String> pair = part.split('=', 2);
        if (pair.size() == 2) parts.put(pair[0].trim(), pair[1].trim());
      }
    }
    HmacRequestVerifier.Result verified = HmacRequestVerifier.verify(
      body,
      parts.get('v1'),
      parts.get('t'),
      ConnectorSecretService.getActiveSecret('stripe', 'webhookSigningSecret'),
      300
    );
    if (!verified.ok) {
      return ConnectorExecutionResult.failed(verified.message, false, null);
    }
    return WebhookWorkService.enqueue(
      'stripe',
      'WebhookEvent',
      WebhookWorkService.jsonString(body, 'id'),
      body
    );
  }
}