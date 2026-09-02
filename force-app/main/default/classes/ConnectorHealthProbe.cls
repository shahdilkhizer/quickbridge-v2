public interface ConnectorHealthProbe {
  ConnectorHealthProbeResult probe(Connector_Instance__c connectorInstance);
}