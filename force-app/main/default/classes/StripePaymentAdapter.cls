public without sharing class StripePaymentAdapter extends RestPaymentProviderAdapter {
  protected override String connectorKey() { return 'stripe'; }
  protected override String contentType() { return 'application/x-www-form-urlencoded'; }
  protected override String endpoint(String operation, PaymentCapabilityRequest request) {
    if (operation == 'refund') return '/v1/refunds';
    if (operation == 'recover') return '/v1/payment_intents/' + encoded(request.providerToken);
    return '/v1/payment_intents';
  }
  protected override String body(String operation, PaymentCapabilityRequest request) {
    Map<String, String> values = new Map<String, String>();
    if (operation == 'refund') {
      values.put('payment_intent', request.providerToken);
    } else {
      values.put('amount', String.valueOf((request.amount * 100).setScale(0)));
      values.put('currency', request.currencyCode == null ? 'usd' : request.currencyCode.toLowerCase());
      values.put('payment_method', request.providerToken);
      values.put('confirm', operation == 'execute' ? 'true' : 'false');
    }
    return urlEncoded(values);
  }
  private static String encoded(String value) {
    return EncodingUtil.urlEncode(value, 'UTF-8');
  }
}