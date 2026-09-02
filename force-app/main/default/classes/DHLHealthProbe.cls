public inherited sharing class DHLHealthProbe extends ConfiguredConnectorHealthProbe {
  protected override String connectorKey() { return 'dhl'; }
  protected override String defaultEndpoint() { return '/health'; }
}