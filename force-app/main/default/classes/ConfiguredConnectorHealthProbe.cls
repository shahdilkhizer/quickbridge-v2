public abstract inherited sharing class ConfiguredConnectorHealthProbe
  implements ConnectorHealthProbe {
  protected abstract String connectorKey();
  protected abstract String defaultEndpoint();

  protected virtual String identityPath() { return null; }
  protected virtual String expectedIdentityConfigKey() { return null; }

  public ConnectorHealthProbeResult probe(
    Connector_Instance__c connectorInstance
  ) {
    try {
      String endpoint = ConnectorConfigService.getConfigValue(
        connectorKey(),
        'healthPath'
      );
      if (String.isBlank(endpoint)) endpoint = defaultEndpoint();
      ConnectorHttpClient.Response response = ConnectorHttpClient.send(
        ConnectorHealthProbeSupport.request(connectorInstance, endpoint)
      );
      Boolean identityMatches = response != null && response.successful;
      String path = identityPath();
      String expectedKey = expectedIdentityConfigKey();
      if (
        identityMatches &&
        String.isNotBlank(path) &&
        String.isNotBlank(expectedKey)
      ) {
        String expected = ConnectorConfigService.getConfigValue(
          connectorKey(),
          expectedKey
        );
        Object actual = ConnectorHealthProbeSupport.jsonValue(
          response.body,
          path
        );
        identityMatches = String.isBlank(expected) ||
          (actual != null && String.valueOf(actual).equalsIgnoreCase(expected));
      }
      return ConnectorHealthProbeSupport.fromResponse(
        response,
        identityMatches
      );
    } catch (Exception failure) {
      return ConnectorHealthProbeSupport.fromException(failure);
    }
  }
}