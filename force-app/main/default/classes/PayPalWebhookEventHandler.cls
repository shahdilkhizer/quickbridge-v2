public without sharing class PayPalWebhookEventHandler implements WebhookEventHandler {
  public ConnectorExecutionResult handle(String body, Map<String, String> headers) {
    String webhookId = ConnectorConfigService.getConfigValue('paypal', 'webhookId');
    if (String.isBlank(webhookId)) {
      return ConnectorExecutionResult.failed('PayPal webhook identity is not configured.', false, null);
    }
    ConnectorHttpClient.RequestSpec spec = new ConnectorHttpClient.RequestSpec();
    spec.namedCredential = ConnectorConfigService.namedCredentialFor('paypal');
    spec.relativeEndpoint = '/v1/notifications/verify-webhook-signature';
    spec.method = 'POST';
    spec.headers.put('Content-Type', 'application/json');
    spec.body = JSON.serialize(new Map<String, Object>{
      'auth_algo' => WebhookWorkService.header(headers, 'PAYPAL-AUTH-ALGO'),
      'cert_url' => WebhookWorkService.header(headers, 'PAYPAL-CERT-URL'),
      'transmission_id' => WebhookWorkService.header(headers, 'PAYPAL-TRANSMISSION-ID'),
      'transmission_sig' => WebhookWorkService.header(headers, 'PAYPAL-TRANSMISSION-SIG'),
      'transmission_time' => WebhookWorkService.header(headers, 'PAYPAL-TRANSMISSION-TIME'),
      'webhook_id' => webhookId,
      'webhook_event' => JSON.deserializeUntyped(body)
    });
    ConnectorHttpClient.Response verification = ConnectorHttpClient.send(spec);
    String status = WebhookWorkService.jsonString(
      verification == null ? null : verification.body,
      'verification_status'
    );
    if (verification == null || !verification.successful || status != 'SUCCESS') {
      return ConnectorExecutionResult.failed('PayPal webhook signature verification failed.', false, null);
    }
    return WebhookWorkService.enqueue(
      'paypal',
      'WebhookEvent',
      WebhookWorkService.jsonString(body, 'id'),
      body
    );
  }
}