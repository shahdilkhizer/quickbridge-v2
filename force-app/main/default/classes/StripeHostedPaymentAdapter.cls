public without sharing class StripeHostedPaymentAdapter
  implements HostedPaymentProviderAdapter {
  public HostedPaymentResult createHostedPayment(HostedPaymentRequest request) {
    if (request == null || request.amount == null || request.amount <= 0 ||
        String.isBlank(request.customerEmail)) {
      HostedPaymentResult invalid = new HostedPaymentResult();
      invalid.errorSummary = 'Amount and customer email are required.';
      return invalid;
    }
    String customerBody = RestPaymentProviderAdapter.urlEncoded(new Map<String, String>{
      'email' => request.customerEmail,
      'name' => request.customerName,
      'metadata[sourceRecordId]' => String.valueOf(request.sourceRecordId)
    });
    ConnectorHttpClient.Response customerResponse = HostedPaymentSupport.post(
      'stripe', '/v1/customers', customerBody,
      'application/x-www-form-urlencoded', request.idempotencyKey + ':customer'
    );
    if (!customerResponse.successful) return HostedPaymentSupport.failure(customerResponse);
    String customerId = HostedPaymentSupport.stringValue(
      HostedPaymentSupport.objectBody(customerResponse), 'id'
    );

    ConnectorHttpClient.Response itemResponse = HostedPaymentSupport.post(
      'stripe', '/v1/invoiceitems',
      RestPaymentProviderAdapter.urlEncoded(new Map<String, String>{
        'customer' => customerId,
        'amount' => String.valueOf((request.amount * 100).setScale(0)),
        'currency' => request.currencyCode.toLowerCase(),
        'description' => request.description
      }),
      'application/x-www-form-urlencoded', request.idempotencyKey + ':item'
    );
    if (!itemResponse.successful) return HostedPaymentSupport.failure(itemResponse);

    ConnectorHttpClient.Response invoiceResponse = HostedPaymentSupport.post(
      'stripe', '/v1/invoices',
      RestPaymentProviderAdapter.urlEncoded(new Map<String, String>{
        'customer' => customerId,
        'collection_method' => 'send_invoice',
        'days_until_due' => String.valueOf(daysUntilDue(request.dueDate)),
        'description' => request.description,
        'metadata[sourceRecordId]' => String.valueOf(request.sourceRecordId),
        'metadata[referenceNumber]' => request.referenceNumber
      }),
      'application/x-www-form-urlencoded', request.idempotencyKey + ':invoice'
    );
    if (!invoiceResponse.successful) return HostedPaymentSupport.failure(invoiceResponse);
    String invoiceId = HostedPaymentSupport.stringValue(
      HostedPaymentSupport.objectBody(invoiceResponse), 'id'
    );
    ConnectorHttpClient.Response finalResponse = HostedPaymentSupport.post(
      'stripe', '/v1/invoices/' + EncodingUtil.urlEncode(invoiceId, 'UTF-8') + '/finalize',
      '', 'application/x-www-form-urlencoded', request.idempotencyKey + ':finalize'
    );
    if (!finalResponse.successful) return HostedPaymentSupport.failure(finalResponse);
    Map<String, Object> body = HostedPaymentSupport.objectBody(finalResponse);
    HostedPaymentResult result = new HostedPaymentResult();
    result.successful = true;
    result.providerReference = HostedPaymentSupport.stringValue(body, 'id');
    result.status = HostedPaymentSupport.stringValue(body, 'status');
    result.hostedUrl = HostedPaymentSupport.stringValue(body, 'hosted_invoice_url');
    result.launchMode = 'REDIRECT';
    result.httpStatusCode = finalResponse.statusCode;
    return result;
  }
  private static Integer daysUntilDue(Date dueDate) {
    return dueDate == null ? 30 : Math.max(1, Date.today().daysBetween(dueDate));
  }
}