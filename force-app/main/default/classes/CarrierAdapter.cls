public interface CarrierAdapter {
  ConnectorExecutionResult validateAddress(Map<String, Object> payload);
  ConnectorExecutionResult quoteRates(Map<String, Object> payload);
  ConnectorExecutionResult createShipment(Map<String, Object> payload);
  ConnectorExecutionResult recoverLabel(Map<String, Object> payload);
  ConnectorExecutionResult createReturnLabel(Map<String, Object> payload);
  ConnectorExecutionResult voidShipment(Map<String, Object> payload);
  ConnectorExecutionResult synchronizeTracking(Map<String, Object> payload);
}