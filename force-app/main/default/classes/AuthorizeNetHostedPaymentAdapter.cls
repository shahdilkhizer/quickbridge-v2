public without sharing class AuthorizeNetHostedPaymentAdapter
  implements HostedPaymentProviderAdapter {
  private static final String API_LOGIN = '{!$Credential.AuthorizeNet_EC.APILoginID}';
  private static final String TRANSACTION_KEY = '{!$Credential.AuthorizeNet_EC.TransactionKey}';
  public HostedPaymentResult createHostedPayment(HostedPaymentRequest request) {
    Map<String, Object> payload = new Map<String, Object>{
      'getHostedPaymentPageRequest' => new Map<String, Object>{
        'merchantAuthentication' => new Map<String, Object>{
          'name' => API_LOGIN, 'transactionKey' => TRANSACTION_KEY
        },
        'refId' => request.referenceNumber,
        'transactionRequest' => new Map<String, Object>{
          'transactionType' => 'authCaptureTransaction',
          'amount' => request.amount,
          'order' => new Map<String, Object>{
            'invoiceNumber' => request.referenceNumber,
            'description' => request.description
          }
        }
      }
    };
    ConnectorHttpClient.Response response = HostedPaymentSupport.post(
      'authorizenet', '/xml/v1/request.api', JSON.serialize(payload),
      'application/json', request.idempotencyKey
    );
    if (!response.successful) return HostedPaymentSupport.failure(response);
    Map<String, Object> body = HostedPaymentSupport.objectBody(response);
    String token = HostedPaymentSupport.stringValue(body, 'token');
    HostedPaymentResult result = new HostedPaymentResult();
    result.successful = String.isNotBlank(token);
    result.providerReference = request.referenceNumber;
    result.status = 'PENDING';
    result.formToken = token;
    result.launchMode = 'POST_FORM';
    result.expiresAt = System.now().addMinutes(15);
    result.hostedUrl = sandboxEnabled()
      ? 'https://test.authorize.net/payment/payment'
      : 'https://accept.authorize.net/payment/payment';
    result.httpStatusCode = response.statusCode;
    if (!result.successful) result.errorSummary = 'Authorize.Net did not return a hosted form token.';
    return result;
  }
  private static Boolean sandboxEnabled() {
    String configured =
      ConnectorConfigService.getConfigValue('authorizenet', 'useSandbox');
    return configured != null && configured.equalsIgnoreCase('true');
  }
}