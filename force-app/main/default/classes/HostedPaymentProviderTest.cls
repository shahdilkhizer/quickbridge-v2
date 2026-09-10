@IsTest
private class HostedPaymentProviderTest {
  private class Transport implements ConnectorHttpClient.Transport {
    List<String> endpoints = new List<String>();
    List<String> bodies = new List<String>();
    public HttpResponse send(HttpRequest request) {
      endpoints.add(request.getEndpoint());
      bodies.add(request.getBody());
      HttpResponse response = new HttpResponse();
      response.setStatusCode(200);
      response.setStatus('OK');
      if (request.getEndpoint().contains('/v1/customers')) {
        response.setBody('{"id":"cus_test"}');
      } else if (request.getEndpoint().contains('/v1/invoiceitems')) {
        response.setBody('{"id":"ii_test"}');
      } else if (request.getEndpoint().endsWith('/v1/invoices')) {
        response.setBody('{"id":"in_test"}');
      } else if (request.getEndpoint().contains('/finalize')) {
        response.setBody('{"id":"in_test","status":"open","hosted_invoice_url":"https://invoice.stripe.test/i"}');
      } else if (request.getEndpoint().contains('/v2/invoicing/invoices') &&
          request.getEndpoint().endsWith('/send')) {
        response.setStatusCode(202);
        response.setBody('{}');
      } else if (request.getEndpoint().contains('/v2/invoicing/invoices')) {
        response.setBody('{"id":"INV2-1","links":[{"rel":"payer-view","href":"https://paypal.test/payer"}]}');
      } else {
        response.setBody('{"token":"short-lived-token"}');
      }
      return response;
    }
  }

  @TestSetup
  static void setupConnectors() {
    insert new List<Connector_Instance__c>{
      instance('stripe', 'Stripe_NC', 'Stripe_EC'),
      instance('paypal', 'PayPal_NC', 'PayPal_EC'),
      instance('authorizenet', 'AuthorizeNet_NC', 'AuthorizeNet_EC')
    };
  }

  @IsTest
  static void schemasAreProviderNeutralAndComplete() {
    for (String gateway : new List<String>{ 'stripe', 'paypal', 'authorizenet' }) {
      PaymentGatewaySchema.Contract contract = PaymentGatewaySchema.forGateway(gateway);
      System.assertEquals(gateway, contract.gateway);
      System.assert(!contract.requestFields.isEmpty());
      System.assert(!contract.invoiceResultFields.isEmpty());
      System.assert(!contract.transactionFields.isEmpty());
      System.assert(hasField(contract.invoiceResultFields, 'hostedPaymentUrl', true));
      System.assert(hasField(contract.transactionFields, 'providerEventKey', true));
    }
  }

  @IsTest
  static void readinessRecognizesCompletePaymentMappings() {
    ConnectorReadinessService.requirePaymentMappingsInTests = true;
    ConnectorReadinessService.Assessment assessment =
      ConnectorReadinessService.assess('stripe', false);
    System.assertEquals(
      false,
      String.join(assessment.issues, ' ').contains('Payment mappings are incomplete'),
      String.join(assessment.issues, ' ')
    );
    ConnectorReadinessService.requirePaymentMappingsInTests = false;
  }

  @IsTest
  static void adaptersNormalizeHostedLaunchesWithoutCardData() {
    Transport transport = new Transport();
    ConnectorHttpClient.setTestTransport(transport);
    HostedPaymentRequest request = requestFor('stripe');
    HostedPaymentResult stripe =
      new StripeHostedPaymentAdapter().createHostedPayment(request);
    System.assertEquals(true, stripe.successful);
    System.assertEquals('REDIRECT', stripe.launchMode);
    System.assertEquals('https://invoice.stripe.test/i', stripe.hostedUrl);

    request = requestFor('paypal');
    HostedPaymentResult paypal =
      new PayPalHostedPaymentAdapter().createHostedPayment(request);
    System.assertEquals(true, paypal.successful);
    System.assertEquals('https://paypal.test/payer', paypal.hostedUrl);

    request = requestFor('authorizenet');
    HostedPaymentResult authorize =
      new AuthorizeNetHostedPaymentAdapter().createHostedPayment(request);
    System.assertEquals(true, authorize.successful);
    System.assertEquals('POST_FORM', authorize.launchMode);
    System.assertNotEquals(null, authorize.expiresAt);

    String sent = String.join(transport.bodies, ' ').toLowerCase();
    System.assertEquals(false, sent.contains('cardnumber'));
    System.assertEquals(false, sent.contains('"cvv"'));
    ConnectorHttpClient.clearTestTransport();
  }

  @IsTest
  static void webhookNormalizationUsesCommonPicklistValues() {
    System.assertEquals('Open', HostedPaymentService.normalizeInvoiceStatus('open'));
    System.assertEquals('Open', HostedPaymentService.normalizeInvoiceStatus('SENT'));
    System.assertEquals('Paid', HostedPaymentService.normalizeInvoiceStatus('completed'));
    System.assertEquals('Cancelled', HostedPaymentService.normalizeInvoiceStatus('voided'));
    Map<String, Object> stripe = PaymentWebhookWorkHandler.normalizePayload(
      'stripe',
      '{"id":"evt_1","type":"invoice.paid","livemode":false,' +
      '"data":{"object":{"id":"in_1","status":"paid",' +
      '"amount_paid":1234,"currency":"usd","payment_intent":"pi_1"}}}'
    );
    System.assertEquals('Stripe', stripe.get('paymentType'));
    System.assertEquals('Paid', stripe.get('status'));
    System.assertEquals(12.34, stripe.get('gatewayAmount'));
    System.assertEquals('stripe:evt_1', stripe.get('providerEventKey'));

    Map<String, Object> paypal = PaymentWebhookWorkHandler.normalizePayload(
      'paypal',
      '{"id":"WH-1","event_type":"INVOICING.INVOICE.CANCELLED",' +
      '"resource":{"id":"INV2-1","status":"CANCELLED",' +
      '"amount":{"value":"9.50","currency_code":"USD"}}}'
    );
    System.assertEquals('PayPal', paypal.get('paymentType'));
    System.assertEquals('Cancelled', paypal.get('status'));

    Map<String, Object> authorizeNet = PaymentWebhookWorkHandler.normalizePayload(
      'authorizenet',
      '{"notificationId":"anet-1","eventType":"net.authorize.payment.authcapture.created",' +
      '"payload":{"id":"42","status":"settledSuccessfully","authAmount":"7.00"}}'
    );
    System.assertEquals('Authorize.Net', authorizeNet.get('paymentType'));
    System.assertEquals('Paid', authorizeNet.get('status'));
  }

  @IsTest
  static void duplicateWebhookDeliveryUpsertsOneTransaction() {
    Account account = new Account(Name = 'Webhook Test');
    insert account;
    Order sourceOrder = new Order(
      AccountId = account.Id,
      EffectiveDate = Date.today(),
      Status = 'Draft'
    );
    insert sourceOrder;
    String eventId = 'evt_duplicate_test';
    String body = '{"id":"' + eventId + '","type":"invoice.paid",' +
      '"livemode":false,"data":{"object":{"id":"in_duplicate",' +
      '"status":"paid","amount_paid":1234,"currency":"usd",' +
      '"payment_intent":"pi_duplicate","metadata":{"sourceRecordId":"' +
      sourceOrder.Id + '"}}}}';
    Integration_Work_Item__c workItem = new Integration_Work_Item__c(
      Integration__c = 'stripe',
      Payload__c = body
    );

    ConnectorExecutionResult first = new PaymentWebhookWorkHandler().handle(workItem);
    ConnectorExecutionResult duplicate = new PaymentWebhookWorkHandler().handle(workItem);

    System.assertEquals(false, first.hasFailures());
    System.assertEquals(false, duplicate.hasFailures());
    List<Portal_Payment_Transaction__c> transactions = [
      SELECT Provider_Event_Key__c, Payment_Type__c, Order__c
      FROM Portal_Payment_Transaction__c
      WHERE Provider_Event_Key__c = :('stripe:' + eventId)
    ];
    System.assertEquals(1, transactions.size());
    System.assertEquals('Stripe', transactions[0].Payment_Type__c);
    System.assertEquals(sourceOrder.Id, transactions[0].Order__c);
  }

  @IsTest
  static void paymentMappingReviewIsReadOnlyAndSuggestsDraftFixes() {
    PaymentInvoiceMappingController.GatewayMappingConfig config =
      PaymentInvoiceMappingController.getGatewayMappingConfig('stripe');
    QuickbridgeAssistantService.Analysis complete =
      PaymentMappingReviewService.review(JSON.serialize(config));
    System.assertEquals(complete.requiredFieldsTotal, complete.requiredFieldsMapped);
    System.assertEquals(100, complete.healthScore);
    QuickbridgeMappingController.SaveResponse saveResponse =
      PaymentInvoiceMappingController.saveGatewayMappingConfig(
        JSON.serialize(config)
      );
    System.assertEquals('Succeeded', saveResponse.status);
    System.assertEquals(
      'TEST-PAYMENT-MAPPING-DEPLOYMENT',
      saveResponse.deploymentId
    );

    for (PaymentInvoiceMappingController.MappingRow row : config.invoiceMappings) {
      if (row.sourceField == 'amount') {
        row.targetField = null;
        break;
      }
    }
    QuickbridgeAssistantService.Analysis draft =
      PaymentMappingReviewService.review(JSON.serialize(config));
    System.assert(draft.requiredFieldsMapped < draft.requiredFieldsTotal);
    System.assert(!draft.missingRequiredFields.isEmpty());
    System.assert(!draft.suggestions.isEmpty());
    System.assertEquals('PaymentInvoice|Invoice', draft.suggestions[0].workspaceKey);

    config.sourceCustomerLookupField = null;
    config.sourceEmailField = null;
    PaymentInvoiceMappingController.MappingRow duplicate =
      new PaymentInvoiceMappingController.MappingRow();
    duplicate.sourceField = 'TotalAmount';
    duplicate.targetField = 'amount';
    duplicate.isRequired = true;
    config.sourceMappings.add(duplicate);
    QuickbridgeAssistantService.Analysis risky =
      PaymentMappingReviewService.review(JSON.serialize(config));
    System.assert(risky.missingRequiredFields.size() >= 3);
    System.assert(!risky.risks.isEmpty());

    try {
      PaymentMappingReviewService.review('{"gateway":"unsupported"}');
      System.assert(false, 'Unsupported gateways must be rejected.');
    } catch (Exception expected) {
      System.assertNotEquals(null, expected);
    }
  }

  @IsTest
  static void mappingWorkspaceDiscoverySupportsObjectsLookupsAndGateways() {
    List<PaymentInvoiceMappingController.FieldOption> sourceObjects =
      PaymentInvoiceMappingController.getEligibleSourceObjects();
    List<PaymentInvoiceMappingController.FieldOption> targetObjects =
      PaymentInvoiceMappingController.getCreateableObjects();
    List<PaymentInvoiceMappingController.FieldOption> relatedObjects =
      PaymentInvoiceMappingController.getObjectsWithLookupTo('Order');
    System.assertNotEquals(null, sourceObjects);
    System.assert(!targetObjects.isEmpty());
    System.assert(!relatedObjects.isEmpty());

    List<PaymentInvoiceMappingController.FieldOption> orderFields =
      PaymentInvoiceMappingController.getObjectFields('Order');
    List<PaymentInvoiceMappingController.FieldOption> customerLookups =
      PaymentInvoiceMappingController.getLookupFields('Order', null);
    List<PaymentInvoiceMappingController.FieldOption> emailFields =
      PaymentInvoiceMappingController.getEmailFieldOptions(
        'Order',
        'BillToContactId'
      );
    List<PaymentInvoiceMappingController.FieldOption> invoiceLookups =
      PaymentInvoiceMappingController.getLookupFields('Invoice__c', 'Order');
    System.assert(hasOption(orderFields, 'TotalAmount'));
    System.assert(hasOption(customerLookups, 'BillToContactId'));
    System.assert(hasOption(emailFields, 'BillToContact.Email'));
    System.assert(hasOption(invoiceLookups, 'Order__c'));

    System.assert(!PaymentInvoiceMappingController.getInvoiceRequestFields().isEmpty());
    for (String gateway : new List<String>{ 'stripe', 'paypal', 'authorizenet' }) {
      System.assert(
        !PaymentInvoiceMappingController.getInvoiceRequestFieldsForGateway(
          gateway
        ).isEmpty()
      );
      System.assert(
        !PaymentInvoiceMappingController.getGatewayTransactionFields(
          gateway
        ).isEmpty()
      );
    }
    try {
      PaymentInvoiceMappingController.getObjectFields('Object_That_Does_Not_Exist__c');
      System.assert(false, 'Unknown objects must be rejected.');
    } catch (Exception expected) {
      System.assertNotEquals(null, expected);
    }
  }

  private static HostedPaymentRequest requestFor(String gateway) {
    HostedPaymentRequest request = new HostedPaymentRequest();
    request.connectorKey = gateway;
    request.sourceRecordId = UserInfo.getUserId();
    request.amount = 12.34;
    request.currencyCode = 'USD';
    request.referenceNumber = 'TEST-1';
    request.customerEmail = 'payer@example.test';
    request.customerName = 'Test Payer';
    request.description = 'Sandbox test invoice';
    request.dueDate = Date.today().addDays(10);
    request.idempotencyKey = gateway + ':test';
    return request;
  }

  private static Connector_Instance__c instance(
    String keyValue,
    String namedCredential,
    String externalCredential
  ) {
    return new Connector_Instance__c(
      Name = keyValue + ' hosted test',
      Connector_Key__c = keyValue,
      Connector_Label__c = keyValue,
      Active__c = false,
      Environment__c = 'Sandbox',
      Health_Status__c = 'Unknown',
      Named_Credential__c = namedCredential,
      External_Credential__c = externalCredential
    );
  }

  private static Boolean hasField(
    List<PaymentGatewaySchema.FieldDefinition> fields,
    String value,
    Boolean required
  ) {
    for (PaymentGatewaySchema.FieldDefinition field : fields) {
      if (field.value == value && field.required == required) return true;
    }
    return false;
  }

  private static Boolean hasOption(
    List<PaymentInvoiceMappingController.FieldOption> options,
    String value
  ) {
    for (PaymentInvoiceMappingController.FieldOption optionValue : options) {
      if (optionValue.value == value) return true;
    }
    return false;
  }
}