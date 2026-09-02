public inherited sharing class AuthorizeNetHealthProbe implements ConnectorHealthProbe {
  private static final String API_LOGIN =
    '{!$Credential.AuthorizeNet_EC.APILoginID}';
  private static final String TRANSACTION_KEY =
    '{!$Credential.AuthorizeNet_EC.TransactionKey}';

  public ConnectorHealthProbeResult probe(
    Connector_Instance__c connectorInstance
  ) {
    try {
      ConnectorHttpClient.RequestSpec request =
        ConnectorHealthProbeSupport.request(
          connectorInstance,
          '/xml/v1/request.api'
        );
      request.method = 'POST';
      request.headers.put('Content-Type', 'application/json');
      request.body = JSON.serialize(
        new Map<String, Object>{
          'authenticateTestRequest' => new Map<String, Object>{
            'merchantAuthentication' => new Map<String, Object>{
              'name' => API_LOGIN,
              'transactionKey' => TRANSACTION_KEY
            }
          }
        }
      );
      ConnectorHttpClient.Response response = ConnectorHttpClient.send(request);
      Object resultCode = ConnectorHealthProbeSupport.jsonValue(
        response.body,
        'messages.resultCode'
      );
      return ConnectorHealthProbeSupport.fromResponse(
        response,
        resultCode != null && String.valueOf(resultCode).equalsIgnoreCase('Ok')
      );
    } catch (Exception failure) {
      return ConnectorHealthProbeSupport.fromException(failure);
    }
  }
}