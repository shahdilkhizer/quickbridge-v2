public inherited sharing class ShopifyHealthProbe implements ConnectorHealthProbe {
  public ConnectorHealthProbeResult probe(
    Connector_Instance__c connectorInstance
  ) {
    try {
      String expectedDomain = ConnectorConfigService.getConfigValue(
        'shopify',
        'storeDomain'
      );
      GenericResourceContract contract = new GenericResourceContract();
      contract.versionConfig = 'apiVersion'; contract.defaultVersion = '2026-07';
      String apiVersion = contract.version('shopify');
      ConnectorHttpClient.Response response = ConnectorHttpClient.send(
        ConnectorHealthProbeSupport.request(
          connectorInstance,
          '/admin/api/' + apiVersion + '/shop.json'
        )
      );
      String actualDomain = String.valueOf(
        ConnectorHealthProbeSupport.jsonValue(
          response.body,
          'shop.myshopify_domain'
        )
      );
      Boolean matches =
        response.successful &&
        String.isNotBlank(expectedDomain) &&
        expectedDomain.equalsIgnoreCase(actualDomain);
      if (!matches) return ConnectorHealthProbeSupport.fromResponse(response, false);
      String returnedVersion = response.header('X-Shopify-API-Version');
      if (String.isNotBlank(returnedVersion) && returnedVersion != apiVersion) {
        return ConnectorHealthProbeResult.failed('Unavailable', 'Shopify substituted a different API version.', response.statusCode, false);
      }
      ConnectorHttpClient.Response scopeResponse = ConnectorHttpClient.send(
        ConnectorHealthProbeSupport.request(connectorInstance, '/admin/oauth/access_scopes.json'));
      if (!scopeResponse.successful) return ConnectorHealthProbeSupport.fromResponse(scopeResponse, false);
      Set<String> granted = new Set<String>();
      Object rawScopes = ConnectorHealthProbeSupport.jsonValue(scopeResponse.body, 'access_scopes');
      if (rawScopes instanceof List<Object>) for (Object raw : (List<Object>)rawScopes) {
        Object handle = GenericIntegrationRuntime.valueAtPath(raw, 'handle');
        if (handle != null) granted.add(String.valueOf(handle));
      }
      Set<String> required = new Set<String>{'write_customers','write_products','write_orders'};
      String startDate = ConnectorConfigService.getConfigValue('shopify','startDate');
      if (String.isNotBlank(startDate) && Date.valueOf(startDate) < Date.today().addDays(-60)) required.add('read_all_orders');
      required.removeAll(granted);
      if (!required.isEmpty()) return ConnectorHealthProbeResult.failed('Authentication Required',
        'Reauthorize Shopify with required scopes: ' + String.join(new List<String>(required), ', '), 403, false);
      return ConnectorHealthProbeResult.ready();
    } catch (Exception failure) {
      return ConnectorHealthProbeSupport.fromException(failure);
    }
  }
}