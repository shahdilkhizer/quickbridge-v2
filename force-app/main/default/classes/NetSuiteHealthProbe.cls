public inherited sharing class NetSuiteHealthProbe extends ConfiguredConnectorHealthProbe {
  protected override String connectorKey() { return 'netsuite'; }
  protected override String defaultEndpoint() { return '/services/rest/record/v1/metadata-catalog'; }
}