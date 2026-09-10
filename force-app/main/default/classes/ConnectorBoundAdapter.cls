/**
 * Internal binding contract for provider-neutral capability adapters.
 * The router is the only component that binds a connector key.
 */
public interface ConnectorBoundAdapter {
  void bindConnector(String connectorKey);
}