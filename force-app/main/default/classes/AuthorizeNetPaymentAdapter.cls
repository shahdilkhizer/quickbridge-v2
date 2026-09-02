public without sharing class AuthorizeNetPaymentAdapter extends RestPaymentProviderAdapter {
  private static final String API_LOGIN =
    '{!$Credential.AuthorizeNet_EC.APILoginID}';
  private static final String TRANSACTION_KEY =
    '{!$Credential.AuthorizeNet_EC.TransactionKey}';

  protected override String connectorKey() { return 'authorizenet'; }
  protected override String endpoint(String operation, PaymentCapabilityRequest request) {
    return '/xml/v1/request.api';
  }
  protected override String referencePath() { return 'transactionResponse.transId'; }
  protected override String statusPath() { return 'messages.resultCode'; }
  protected override String actionTokenPath() { return 'opaqueData.dataValue'; }
  protected override String body(String operation, PaymentCapabilityRequest request) {
    String transactionType = operation == 'refund'
      ? 'refundTransaction'
      : 'authCaptureTransaction';
    return jsonBody(new Map<String, Object>{
      'createTransactionRequest' => new Map<String, Object>{
        'merchantAuthentication' => new Map<String, Object>{
          'name' => API_LOGIN,
          'transactionKey' => TRANSACTION_KEY
        },
        'refId' => request.idempotencyKey,
        'transactionRequest' => new Map<String, Object>{
          'transactionType' => transactionType,
          'amount' => request.amount,
          'payment' => new Map<String, Object>{
            'opaqueData' => new Map<String, Object>{
              'dataDescriptor' => 'COMMON.ACCEPT.INAPP.PAYMENT',
              'dataValue' => request.providerToken
            }
          }
        }
      }
    });
  }
}