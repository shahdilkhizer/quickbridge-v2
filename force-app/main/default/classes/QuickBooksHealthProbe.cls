public inherited sharing class QuickBooksHealthProbe implements ConnectorHealthProbe {
  public ConnectorHealthProbeResult probe(
    Connector_Instance__c connectorInstance
  ) {
    try {
      String realmId = ConnectorConfigService.getConfigValue('qbo', 'realmId');
      if (
        String.isBlank(realmId) ||
        !Pattern.matches('^[0-9]{1,30}$', realmId)
      ) {
        return ConnectorHealthProbeResult.failed(
          'Error',
          'QuickBooks realm ID is missing or invalid.',
          null,
          false
        );
      }
      ConnectorHttpClient.Response response = ConnectorHttpClient.send(
        ConnectorHealthProbeSupport.request(
          connectorInstance,
          '/companyinfo/' + realmId + '?minorversion=75'
        )
      );
      Object companyName = ConnectorHealthProbeSupport.jsonValue(
        response.body,
        'CompanyInfo.CompanyName'
      );
      return ConnectorHealthProbeSupport.fromResponse(
        response,
        companyName != null && String.isNotBlank(String.valueOf(companyName))
      );
    } catch (Exception failure) {
      return ConnectorHealthProbeSupport.fromException(failure);
    }
  }
}