/**
 * Provider-neutral work capability that delegates to the existing generic
 * runtime after the router has bound a connector key.
 */
public without sharing class MetadataConnectorWorkAdapter
  implements IntegrationWorkHandler, ConnectorBoundAdapter {
  private String boundConnectorKey;

  public void bindConnector(String connectorKey) {
    boundConnectorKey = MetadataConnectorAdapterSupport.requireConnectorKey(connectorKey);
  }

  public ConnectorExecutionResult handle(Integration_Work_Item__c item) {
    if (String.isBlank(boundConnectorKey)) {
      return ConnectorExecutionResult.failed(
        'The dynamic work adapter is not bound to a connector.',
        false,
        null
      );
    }
    return MetadataIntegrationWorkHandler.handleForConnector(boundConnectorKey, item);
  }
}