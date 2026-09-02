public without sharing class PayPalPaymentAdapter extends RestPaymentProviderAdapter {
  protected override String connectorKey() { return 'paypal'; }
  protected override String endpoint(String operation, PaymentCapabilityRequest request) {
    if (operation == 'refund') return '/v2/payments/captures/' + encoded(request.providerToken) + '/refund';
    if (operation == 'recover') return '/v2/checkout/orders/' + encoded(request.providerToken);
    return '/v2/checkout/orders';
  }
  protected override String body(String operation, PaymentCapabilityRequest request) {
    if (operation == 'refund') {
      return jsonBody(new Map<String, Object>{
        'amount' => new Map<String, Object>{
          'currency_code' => request.currencyCode,
          'value' => String.valueOf(request.amount)
        }
      });
    }
    return jsonBody(new Map<String, Object>{
      'intent' => 'CAPTURE',
      'purchase_units' => new List<Object>{
        new Map<String, Object>{
          'reference_id' => String.valueOf(request.sourceRecordId),
          'amount' => new Map<String, Object>{
            'currency_code' => request.currencyCode,
            'value' => String.valueOf(request.amount)
          }
        }
      },
      'payment_source_token' => request.providerToken
    });
  }
  private static String encoded(String value) { return EncodingUtil.urlEncode(value, 'UTF-8'); }
}