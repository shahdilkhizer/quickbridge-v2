/**
 * Generic carrier adapter. Each operation path is configuration-driven
 * (<operation>Path); mutation idempotency and payload safety are enforced by
 * RestCarrierAdapter.
 */
public without sharing class MetadataConnectorCarrierAdapter
  extends RestCarrierAdapter implements ConnectorBoundAdapter {
  private String boundConnectorKey;

  public void bindConnector(String connectorKey) {
    boundConnectorKey = MetadataConnectorAdapterSupport.requireConnectorKey(connectorKey);
  }

  protected override String connectorKey() {
    return boundConnectorKey;
  }

  protected override String defaultEndpoint(String operation) {
    return null;
  }
}