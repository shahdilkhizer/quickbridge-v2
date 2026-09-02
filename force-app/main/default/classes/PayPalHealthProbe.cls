public inherited sharing class PayPalHealthProbe extends ConfiguredConnectorHealthProbe {
  protected override String connectorKey() { return 'paypal'; }
  protected override String defaultEndpoint() { return '/v1/notifications/webhooks'; }
}