public inherited sharing class ShopifyHealthProbe implements ConnectorHealthProbe {
  public ConnectorHealthProbeResult probe(
    Connector_Instance__c connectorInstance
  ) {
    try {
      String expectedDomain = ConnectorConfigService.getConfigValue(
        'shopify',
        'storeDomain'
      );
      ConnectorHttpClient.Response response = ConnectorHttpClient.send(
        ConnectorHealthProbeSupport.request(
          connectorInstance,
          '/admin/api/2026-07/shop.json'
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
      return ConnectorHealthProbeSupport.fromResponse(response, matches);
    } catch (Exception failure) {
      return ConnectorHealthProbeSupport.fromException(failure);
    }
  }
}