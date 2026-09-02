public inherited sharing class UPSHealthProbe extends ConfiguredConnectorHealthProbe {
  protected override String connectorKey() { return 'ups'; }
  protected override String defaultEndpoint() { return '/health'; }
}