/**
 * Health adapter whose endpoint and optional identity checks are configuration
 * values. Blank configuration fails closed through the shared health result.
 */
public inherited sharing class MetadataConnectorHealthProbe
  extends ConfiguredConnectorHealthProbe implements ConnectorBoundAdapter {
  private String boundConnectorKey;

  public void bindConnector(String connectorKey) {
    boundConnectorKey = MetadataConnectorAdapterSupport.requireConnectorKey(connectorKey);
  }

  protected override String connectorKey() {
    return boundConnectorKey;
  }

  protected override String defaultEndpoint() {
    return null;
  }

  protected override String identityPath() {
    return ConnectorConfigService.getConfigValue(boundConnectorKey, 'healthIdentityPath');
  }

  protected override String expectedIdentityConfigKey() {
    return ConnectorConfigService.getConfigValue(boundConnectorKey, 'healthIdentityConfigKey');
  }

  public override ConnectorHealthProbeResult probe(
    Connector_Instance__c connectorInstance
  ) {
    if (
      String.isBlank(boundConnectorKey) ||
      connectorInstance == null ||
      !MetadataConnectorAdapterSupport.matches(
        boundConnectorKey,
        connectorInstance.Connector_Key__c
      )
    ) {
      return ConnectorHealthProbeResult.failed(
        'Error',
        'The dynamic health adapter is not bound to the requested connector.',
        null,
        false
      );
    }
    return super.probe(connectorInstance);
  }
}