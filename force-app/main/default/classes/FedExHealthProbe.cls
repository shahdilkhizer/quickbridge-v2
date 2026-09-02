public inherited sharing class FedExHealthProbe extends ConfiguredConnectorHealthProbe {
  protected override String connectorKey() { return 'fedex'; }
  protected override String defaultEndpoint() { return '/health'; }
}