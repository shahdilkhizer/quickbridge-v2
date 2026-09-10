public without sharing class PayPalHostedPaymentAdapter
  implements HostedPaymentProviderAdapter {
  public HostedPaymentResult createHostedPayment(HostedPaymentRequest request) {
    Map<String, Object> invoice = new Map<String, Object>{
      'detail' => new Map<String, Object>{
        'invoice_number' => request.referenceNumber,
        'reference' => String.valueOf(request.sourceRecordId),
        'currency_code' => request.currencyCode,
        'note' => request.description
      },
      'primary_recipients' => new List<Object>{
        new Map<String, Object>{ 'billing_info' => new Map<String, Object>{
          'email_address' => request.customerEmail
        }}
      },
      'items' => new List<Object>{
        new Map<String, Object>{
          'name' => String.isBlank(request.description) ? 'Payment' : request.description.left(200),
          'quantity' => '1',
          'unit_amount' => new Map<String, Object>{
            'currency_code' => request.currencyCode,
            'value' => String.valueOf(request.amount.setScale(2))
          }
        }
      }
    };
    ConnectorHttpClient.Response createResponse = HostedPaymentSupport.post(
      'paypal', '/v2/invoicing/invoices', JSON.serialize(invoice),
      'application/json', request.idempotencyKey + ':invoice'
    );
    if (!createResponse.successful) return HostedPaymentSupport.failure(createResponse);
    Map<String, Object> created = HostedPaymentSupport.objectBody(createResponse);
    String invoiceId = HostedPaymentSupport.stringValue(created, 'id');
    ConnectorHttpClient.Response sendResponse = HostedPaymentSupport.post(
      'paypal', '/v2/invoicing/invoices/' + EncodingUtil.urlEncode(invoiceId, 'UTF-8') + '/send',
      JSON.serialize(new Map<String, Object>{ 'send_to_recipient' => true }),
      'application/json', request.idempotencyKey + ':send'
    );
    if (!sendResponse.successful) return HostedPaymentSupport.failure(sendResponse);
    HostedPaymentResult result = new HostedPaymentResult();
    result.successful = true;
    result.providerReference = invoiceId;
    result.status = 'SENT';
    result.hostedUrl = payerView(created);
    result.launchMode = 'REDIRECT';
    result.httpStatusCode = sendResponse.statusCode;
    return result;
  }
  private static String payerView(Map<String, Object> body) {
    Object linksValue = body.get('links');
    if (!(linksValue instanceof List<Object>)) return null;
    for (Object rowValue : (List<Object>) linksValue) {
      if (!(rowValue instanceof Map<String, Object>)) continue;
      Map<String, Object> row = (Map<String, Object>) rowValue;
      String rel = HostedPaymentSupport.stringValue(row, 'rel');
      if (rel == 'payer-view' || rel == 'recipient-view') {
        return HostedPaymentSupport.stringValue(row, 'href');
      }
    }
    return null;
  }
}