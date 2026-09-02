@IsTest
private class ConnectorCapabilityArchitectureTest {
  private class CapturingTransport implements ConnectorHttpClient.Transport {
    Integer statusCode;
    String responseBody;
    Integer calls = 0;
    HttpRequest lastRequest;

    CapturingTransport(Integer statusCode, String responseBody) {
      this.statusCode = statusCode;
      this.responseBody = responseBody;
    }

    public HttpResponse send(HttpRequest request) {
      calls++;
      lastRequest = request;
      HttpResponse response = new HttpResponse();
      response.setStatusCode(statusCode);
      response.setStatus(statusCode >= 200 && statusCode < 300 ? 'OK' : 'Error');
      response.setBody(responseBody);
      return response;
    }
  }

  @IsTest
  static void credentialPolicyAndAllowlistCoverEveryConnector() {
    Map<String, String> expectedBaseNames = new Map<String, String>{
      'qbo' => 'QuickBooks',
      'shopify' => 'Shopify',
      'netsuite' => 'NetSuite',
      'meta' => 'Meta',
      'klaviyo' => 'Klaviyo',
      'fedex' => 'FedEx',
      'ups' => 'UPS',
      'dhl' => 'DHL',
      'stripe' => 'Stripe',
      'paypal' => 'PayPal',
      'authorizenet' => 'AuthorizeNet'
    };

    System.assertEquals(expectedBaseNames.keySet(), ConnectorCredentialPolicy.supportedConnectorKeys());
    for (String connectorKey : expectedBaseNames.keySet()) {
      String baseName = expectedBaseNames.get(connectorKey);
      System.assertEquals(baseName + '_NC', ConnectorCredentialPolicy.expectedNamedCredential(connectorKey));
      System.assertEquals(baseName + '_EC', ConnectorCredentialPolicy.expectedExternalCredential(connectorKey));
      System.assertEquals(baseName + '_Principal', ConnectorCredentialPolicy.expectedPrincipal(connectorKey));
    }
    System.assertEquals(null, ConnectorCredentialPolicy.expectedNamedCredential('unsupported'));
    System.assert(ConnectorAdapterAllowlist.isAllowed('StripePaymentAdapter'));
    System.assert(!ConnectorAdapterAllowlist.isAllowed('UntrustedDynamicClass'));
  }

  @IsTest
  static void routerEnforcesCapabilityTypeAndAllowlist() {
    ConnectorCapabilityRouter.clearTestAdapters();
    ConnectorCapabilityRouter.registerTestAdapter('stripe', 'payment.checkout', 'StripePaymentAdapter');
    System.assert(ConnectorCapabilityRouter.paymentAdapter('stripe') instanceof StripePaymentAdapter);

    ConnectorCapabilityRouter.registerTestAdapter('stripe', 'health.probe', 'StripePaymentAdapter');
    try {
      ConnectorCapabilityRouter.healthProbe('stripe');
      System.assert(false, 'An adapter implementing the wrong contract must be rejected.');
    } catch (ConnectorCapabilityRouter.ConnectorCapabilityException expected) {
      System.assert(expected.getMessage().contains('ConnectorHealthProbe'));
    }

    ConnectorCapabilityRouter.registerTestAdapter('stripe', 'health.probe', 'UntrustedDynamicClass');
    try {
      ConnectorCapabilityRouter.healthProbe('stripe');
      System.assert(false, 'A class outside the fixed allowlist must be rejected.');
    } catch (ConnectorCapabilityRouter.ConnectorCapabilityException expected) {
      System.assert(expected.getMessage().contains('allowlisted'));
    }

    try {
      ConnectorCapabilityRouter.hasCapability('../stripe', 'health.probe');
      System.assert(false, 'Unsafe connector keys must be rejected.');
    } catch (ConnectorCapabilityRouter.ConnectorCapabilityException expected) {
      System.assert(expected.getMessage().contains('invalid'));
    }
  }

  @IsTest
  static void paymentAdapterUsesNamedCredentialAndRejectsCardData() {
    insert connectorInstance('stripe', 'Stripe_NC', 'Stripe_EC');
    CapturingTransport transport = new CapturingTransport(
      200,
      '{"id":"pi_test","status":"requires_action","client_secret":"safe_client_action"}'
    );
    ConnectorHttpClient.setTestTransport(transport);

    PaymentCapabilityRequest request = new PaymentCapabilityRequest();
    request.connectorKey = 'stripe';
    request.amount = 12.34;
    request.currencyCode = 'USD';
    request.idempotencyKey = 'stripe:order:test';
    PaymentCapabilityResult result = new StripePaymentAdapter().initializePayment(request);

    System.assertEquals(true, result.successful);
    System.assertEquals(true, result.requiresAction);
    System.assertEquals('pi_test', result.providerReference);
    System.assertEquals('callout:Stripe_NC/v1/payment_intents', transport.lastRequest.getEndpoint());
    System.assert(transport.lastRequest.getBody().contains('amount=1234'));

    PaymentCapabilityRequest prohibited = new PaymentCapabilityRequest();
    prohibited.connectorKey = 'stripe';
    prohibited.amount = 10;
    prohibited.providerToken = 'pm_browser_token';
    prohibited.idempotencyKey = 'stripe:order:blocked';
    prohibited.attributes.put('cardNumber', '4111111111111111');
    PaymentCapabilityResult blocked = new StripePaymentAdapter().executePayment(prohibited);
    System.assertEquals(false, blocked.successful);
    System.assert(blocked.errorSummary.contains('Raw card data'));
    System.assertEquals(1, transport.calls, 'Rejected card data must never reach the transport.');
  }

  @IsTest
  static void carrierAdapterRequiresStableIdempotencyForMutations() {
    insert connectorInstance('fedex', 'FedEx_NC', 'FedEx_EC');
    CapturingTransport transport = new CapturingTransport(201, '{"output":{}}');
    ConnectorHttpClient.setTestTransport(transport);
    FedExCarrierAdapter adapter = new FedExCarrierAdapter();

    ConnectorExecutionResult missingKey = adapter.createShipment(
      new Map<String, Object>{ 'packages' => new List<Object>() }
    );
    System.assertEquals(true, missingKey.hasFailures());
    System.assertEquals(0, transport.calls);

    ConnectorExecutionResult success = adapter.createShipment(
      new Map<String, Object>{
        'idempotencyKey' => 'fedex:order:test',
        'packages' => new List<Object>()
      }
    );
    System.assertEquals(false, success.hasFailures());
    System.assertEquals('callout:FedEx_NC/ship/v1/shipments', transport.lastRequest.getEndpoint());
    System.assertEquals('fedex:order:test', transport.lastRequest.getHeader('Idempotency-Key'));
  }

  @IsTest
  static void healthProbeClassifiesIdentityAndAuthenticationFailures() {
    Connector_Instance__c instanceRecord = connectorInstance('stripe', 'Stripe_NC', 'Stripe_EC');
    CapturingTransport readyTransport = new CapturingTransport(200, '{"id":"acct_test"}');
    ConnectorHttpClient.setTestTransport(readyTransport);
    ConnectorHealthProbeResult ready = new StripeHealthProbe().probe(instanceRecord);
    System.assertEquals(true, ready.successful);
    System.assertEquals('Ready', ready.status);

    CapturingTransport unauthorized = new CapturingTransport(
      401,
      '{"error":{"message":"Authorization: Bearer secret-value"}}'
    );
    ConnectorHttpClient.setTestTransport(unauthorized);
    ConnectorHealthProbeResult failed = new StripeHealthProbe().probe(instanceRecord);
    System.assertEquals(false, failed.successful);
    System.assertEquals('Authentication Required', failed.status);
    System.assert(!failed.message.contains('secret-value'));
  }

  @IsTest
  static void providerAdaptersUseSharedHealthCarrierAndPaymentContracts() {
    List<Connector_Instance__c> instances = new List<Connector_Instance__c>{
      connectorInstance('netsuite', 'NetSuite_NC', 'NetSuite_EC'),
      connectorInstance('meta', 'Meta_NC', 'Meta_EC'),
      connectorInstance('klaviyo', 'Klaviyo_NC', 'Klaviyo_EC'),
      connectorInstance('fedex', 'FedEx_NC', 'FedEx_EC'),
      connectorInstance('ups', 'UPS_NC', 'UPS_EC'),
      connectorInstance('dhl', 'DHL_NC', 'DHL_EC'),
      connectorInstance('paypal', 'PayPal_NC', 'PayPal_EC'),
      connectorInstance('authorizenet', 'AuthorizeNet_NC', 'AuthorizeNet_EC')
    };
    insert instances;
    Map<String, Connector_Instance__c> byKey = new Map<String, Connector_Instance__c>();
    for (Connector_Instance__c instanceRecord : instances) {
      byKey.put(instanceRecord.Connector_Key__c, instanceRecord);
    }
    CapturingTransport transport = new CapturingTransport(
      200,
      '{"id":"identity","data":{"id":"identity"},"user_id":"identity","status":"COMPLETED","messages":{"resultCode":"Ok"},"transactionResponse":{"transId":"txn"}}'
    );
    ConnectorHttpClient.setTestTransport(transport);

    List<ConnectorHealthProbeResult> healthResults = new List<ConnectorHealthProbeResult>{
      new NetSuiteHealthProbe().probe(byKey.get('netsuite')),
      new MetaHealthProbe().probe(byKey.get('meta')),
      new KlaviyoHealthProbe().probe(byKey.get('klaviyo')),
      new FedExHealthProbe().probe(byKey.get('fedex')),
      new UPSHealthProbe().probe(byKey.get('ups')),
      new DHLHealthProbe().probe(byKey.get('dhl')),
      new PayPalHealthProbe().probe(byKey.get('paypal')),
      new AuthorizeNetHealthProbe().probe(byKey.get('authorizenet'))
    };
    for (ConnectorHealthProbeResult healthResult : healthResults) {
      System.assertEquals(true, healthResult.successful);
    }

    ConnectorExecutionResult upsRates = new UPSCarrierAdapter().quoteRates(
      new Map<String, Object>{ 'packages' => new List<Object>() }
    );
    System.assertEquals(false, upsRates.hasFailures());
    System.assert(transport.lastRequest.getEndpoint().contains('/api/rating/'));
    ConnectorExecutionResult dhlTracking = new DHLCarrierAdapter().synchronizeTracking(
      new Map<String, Object>{ 'trackingNumber' => 'TEST' }
    );
    System.assertEquals(false, dhlTracking.hasFailures());
    System.assert(transport.lastRequest.getEndpoint().endsWith('/shipments/tracking'));

    PaymentCapabilityRequest paypal = paymentRequest('paypal');
    PaymentCapabilityResult paypalResult =
      new PayPalPaymentAdapter().initializePayment(paypal);
    System.assertEquals(true, paypalResult.successful);
    System.assert(transport.lastRequest.getEndpoint().endsWith('/v2/checkout/orders'));
    PaymentCapabilityRequest authorizeNet = paymentRequest('authorizenet');
    authorizeNet.providerToken = 'opaque-browser-token';
    PaymentCapabilityResult authorizeNetResult =
      new AuthorizeNetPaymentAdapter().executePayment(authorizeNet);
    System.assertEquals(true, authorizeNetResult.successful);
    System.assert(transport.lastRequest.getBody().contains('opaqueData'));
  }

  @IsTest
  static void signedWebhookCreatesOneIdempotentWorkChain() {
    insert new Connector_Secret__c(
      Connector_Key__c = 'meta',
      Secret_Kind__c = 'webhookSigningSecret',
      Secret_Value__c = 'unit-test-signing-secret',
      Active__c = true
    );
    String body = '{"object":"page","entry":[{"id":"event-1"}]}';
    String signature = 'sha256=' + EncodingUtil.convertToHex(
      Crypto.generateMac(
        'HmacSHA256',
        Blob.valueOf(body),
        Blob.valueOf('unit-test-signing-secret')
      )
    );
    Map<String, String> headers = new Map<String, String>{
      'X-Hub-Signature-256' => signature
    };

    ConnectorExecutionResult first = new MetaWebhookEventHandler().handle(body, headers);
    ConnectorExecutionResult duplicate = new MetaWebhookEventHandler().handle(body, headers);
    System.assertEquals(false, first.hasFailures());
    System.assertEquals(false, duplicate.hasFailures());
    List<Integration_Work_Item__c> workItems = [
      SELECT Status__c, Coalesced_Count__c, Source_External_Id__c
      FROM Integration_Work_Item__c
      WHERE Integration__c = 'meta' AND Operation__c = 'WebhookEvent'
    ];
    System.assertEquals(1, workItems.size(), 'Duplicate provider events must coalesce.');
    System.assertEquals(1, workItems[0].Coalesced_Count__c);
    System.assertEquals('Pending', workItems[0].Status__c);

    ConnectorExecutionResult rejected = new MetaWebhookEventHandler().handle(
      body,
      new Map<String, String>{ 'X-Hub-Signature-256' => 'sha256=00' }
    );
    System.assertEquals(true, rejected.hasFailures());
    System.assertEquals(false, rejected.retryable);
  }

  @IsTest
  static void scheduleConnectorAliasesAreCachedPerTransaction() {
    Integer beforeQueries = Limits.getQueries();
    String first = IntegrationScheduleDispatcher.normalizeConnector('QuickBooks');
    Integer afterFirst = Limits.getQueries();
    String second = IntegrationScheduleDispatcher.normalizeConnector('QuickBooks Online');
    Integer afterSecond = Limits.getQueries();

    System.assertEquals('qbo', first);
    System.assertEquals('qbo', second);
    System.assert(afterFirst >= beforeQueries);
    System.assertEquals(afterFirst, afterSecond, 'Connector aliases must be cached after one metadata query.');
  }

  @IsTest
  static void newObjectTriggersDelegateInBulkWithoutConnectorSideEffects() {
    Account accountRecord = new Account(Name = 'Quickbridge Trigger Account');
    insert accountRecord;
    Contact contactRecord = new Contact(
      LastName = 'Trigger Contact',
      AccountId = accountRecord.Id
    );
    Lead leadRecord = new Lead(
      LastName = 'Trigger Lead',
      Company = 'Quickbridge'
    );
    Campaign campaignRecord = new Campaign(Name = 'Quickbridge Trigger Campaign');
    insert contactRecord;
    insert leadRecord;
    insert campaignRecord;
    insert new CampaignMember(
      CampaignId = campaignRecord.Id,
      ContactId = contactRecord.Id
    );
    insert new Event(
      Subject = 'Quickbridge Trigger Event',
      WhatId = accountRecord.Id,
      StartDateTime = System.now().addHours(1),
      EndDateTime = System.now().addHours(2)
    );

    System.assertEquals(
      0,
      [SELECT COUNT() FROM Integration_Work_Item__c],
      'Inactive connectors must not create trigger work.'
    );
  }

  @IsTest
  static void readinessEvaluatesAllConnectorDefinitionsInBulk() {
    Set<String> connectorKeys = ConnectorCredentialPolicy.supportedConnectorKeys();
    List<Connector_Instance__c> instances = new List<Connector_Instance__c>();
    for (String connectorKey : connectorKeys) {
      instances.add(
        connectorInstance(
          connectorKey,
          ConnectorCredentialPolicy.expectedNamedCredential(connectorKey),
          ConnectorCredentialPolicy.expectedExternalCredential(connectorKey)
        )
      );
      instances[instances.size() - 1].Active__c = true;
      instances[instances.size() - 1].Health_Status__c = 'Ready';
    }
    insert instances;
    Map<String, Id> connectorIdByKey = new Map<String, Id>();
    for (Connector_Instance__c instanceRecord : instances) {
      connectorIdByKey.put(instanceRecord.Connector_Key__c, instanceRecord.Id);
    }
    List<Connector_Config_Value__c> requiredValues =
      new List<Connector_Config_Value__c>();
    for (Connector_Config_Field__mdt definition : [
      SELECT Connector_Key__c, Field_Key__c
      FROM Connector_Config_Field__mdt
      WHERE Required__c = true AND Secret__c = false
    ]) {
      if (!connectorIdByKey.containsKey(definition.Connector_Key__c)) continue;
      requiredValues.add(
        configValue(
          connectorIdByKey.get(definition.Connector_Key__c),
          definition.Connector_Key__c,
          definition.Field_Key__c,
          definition.Field_Key__c == 'realmId' ? '123456789' : 'test-value'
        )
      );
    }
    insert requiredValues;

    Map<String, ConnectorReadinessService.Assessment> assessments =
      ConnectorReadinessService.assessAll(connectorKeys, true);
    System.assertEquals(connectorKeys.size(), assessments.size());
    for (String connectorKey : connectorKeys) {
      ConnectorReadinessService.Assessment assessment = assessments.get(connectorKey);
      System.assertNotEquals(null, assessment);
      System.assertEquals(
        true,
        assessment.operationalReady,
        connectorKey + ': ' + String.join(assessment.issues, ' ')
      );
    }

    update new Connector_Instance__c(
      Id = connectorIdByKey.get('stripe'),
      Named_Credential__c = 'Unexpected_NC'
    );
    ConnectorReadinessService.Assessment blocked =
      ConnectorReadinessService.assess('stripe', true);
    System.assertEquals(false, blocked.operationalReady);
    System.assert(blocked.issues[0].contains('unexpected'));
  }

  @IsTest
  static void paymentWebhookHandlersValidateAndCoalesceProviderEvents() {
    List<Connector_Instance__c> instances = new List<Connector_Instance__c>{
      connectorInstance('stripe', 'Stripe_NC', 'Stripe_EC'),
      connectorInstance('paypal', 'PayPal_NC', 'PayPal_EC'),
      connectorInstance('authorizenet', 'AuthorizeNet_NC', 'AuthorizeNet_EC')
    };
    insert instances;
    Map<String, Id> connectorIds = new Map<String, Id>();
    for (Connector_Instance__c instanceRecord : instances) {
      connectorIds.put(instanceRecord.Connector_Key__c, instanceRecord.Id);
    }
    insert configValue(
      connectorIds.get('paypal'),
      'paypal',
      'webhookId',
      'paypal-webhook-test'
    );
    insert new List<Connector_Secret__c>{
      new Connector_Secret__c(
        Connector_Key__c = 'stripe',
        Secret_Kind__c = 'webhookSigningSecret',
        Secret_Value__c = 'stripe-test-secret',
        Active__c = true
      ),
      new Connector_Secret__c(
        Connector_Key__c = 'authorizenet',
        Secret_Kind__c = 'webhookSigningSecret',
        Secret_Value__c = 'authorize-test-secret',
        Active__c = true
      )
    };

    String stripeBody = '{"id":"evt_stripe","type":"payment_intent.succeeded"}';
    String timestamp = String.valueOf(Datetime.now().getTime() / 1000);
    String stripeSignature = HmacRequestVerifier.computeSignature(
      timestamp,
      stripeBody,
      'stripe-test-secret'
    );
    ConnectorExecutionResult stripeResult = new StripeWebhookEventHandler().handle(
      stripeBody,
      new Map<String, String>{
        'Stripe-Signature' => 't=' + timestamp + ',v1=' + stripeSignature
      }
    );
    System.assertEquals(false, stripeResult.hasFailures());

    String authorizeBody = '{"notificationId":"evt_authorize"}';
    String authorizeSignature = EncodingUtil.convertToHex(
      Crypto.generateMac(
        'HmacSHA512',
        Blob.valueOf(authorizeBody),
        Blob.valueOf('authorize-test-secret')
      )
    );
    ConnectorExecutionResult authorizeResult =
      new AuthorizeNetWebhookEventHandler().handle(
        authorizeBody,
        new Map<String, String>{
          'X-ANET-Signature' => 'sha512=' + authorizeSignature
        }
      );
    System.assertEquals(false, authorizeResult.hasFailures());

    CapturingTransport paypalTransport = new CapturingTransport(
      200,
      '{"verification_status":"SUCCESS"}'
    );
    ConnectorHttpClient.setTestTransport(paypalTransport);
    ConnectorExecutionResult paypalResult = new PayPalWebhookEventHandler().handle(
      '{"id":"evt_paypal","event_type":"PAYMENT.CAPTURE.COMPLETED"}',
      new Map<String, String>{
        'PAYPAL-AUTH-ALGO' => 'SHA256withRSA',
        'PAYPAL-CERT-URL' => 'https://api-m.paypal.com/cert',
        'PAYPAL-TRANSMISSION-ID' => 'transmission-id',
        'PAYPAL-TRANSMISSION-SIG' => 'signature',
        'PAYPAL-TRANSMISSION-TIME' => '2026-08-31T00:00:00Z'
      }
    );
    ConnectorHttpClient.clearTestTransport();
    System.assertEquals(false, paypalResult.hasFailures());
    System.assertEquals(
      3,
      [SELECT COUNT() FROM Integration_Work_Item__c WHERE Operation__c = 'WebhookEvent']
    );
  }

  @IsTest
  static void metadataWorkAdapterResolvesBoundedOperation() {
    GenericIntegrationRuntime.OperationDefinition noPagination =
      new GenericIntegrationRuntime.OperationDefinition();
    noPagination.paginationType = 'none';
    GenericIntegrationRuntime.OperationDefinition urlPagination =
      new GenericIntegrationRuntime.OperationDefinition();
    urlPagination.paginationType = 'url';
    urlPagination.nextPath = 'paging.next';
    urlPagination.approvedBaseUrl = 'https://graph.facebook.com';
    ConnectorHttpClient.setTestTransport(
      new CapturingTransport(
        200,
        '{"paging":{"next":"https://graph.facebook.com/next"}}'
      )
    );
    ConnectorHttpClient.RequestSpec pageRequest = new ConnectorHttpClient.RequestSpec();
    pageRequest.namedCredential = 'Meta_NC';
    pageRequest.relativeEndpoint = '/page';
    ConnectorHttpClient.Response pageResponse = ConnectorHttpClient.send(pageRequest);
    ConnectorHttpClient.clearTestTransport();
    System.assertEquals(
      null,
      GenericIntegrationRuntime.nextCursor(
        noPagination,
        pageResponse,
        new ConnectorExecutionRequest(),
        0
      )
    );
    System.assertEquals(
      '/next',
      GenericIntegrationRuntime.nextCursor(
        urlPagination,
        pageResponse,
        new ConnectorExecutionRequest(),
        1
      )
    );

    Integration_Work_Item__c outboundWork = new Integration_Work_Item__c(
      Integration__c = 'netsuite',
      Operation__c = 'CustomerUpsert',
      Status__c = 'Pending',
      Attempt_Count__c = 0,
      Unique_Key__c = 'netsuite:CustomerUpsert:test'
    );
    insert outboundWork;

    System.assert(
      new NetSuiteIntegrationWorker().handle(null).hasFailures(),
      'A missing work item must fail before any async work is submitted.'
    );
    Integration_Work_Item__c wrongConnector = outboundWork.clone(true, true, false, false);
    wrongConnector.Integration__c = 'meta';
    System.assert(
      new NetSuiteIntegrationWorker().handle(wrongConnector).hasFailures(),
      'A connector adapter must reject another connector\'s work.'
    );

    Test.startTest();
    ConnectorExecutionResult workResult = new NetSuiteIntegrationWorker().handle(outboundWork);
    Test.stopTest();
    System.assertEquals(false, workResult.hasFailures());
    System.assertNotEquals(null, workResult.asyncJobId);
  }

  @IsTest
  static void metadataScheduleAdapterResolvesBoundedOperation() {
    Scheduled_Integration_Job__c schedule = claimedSchedule(
      'netsuite-customer-upsert',
      'netsuite-lease',
      'NetSuite',
      'CustomerUpsert',
      'Out'
    );
    insert schedule;
    System.assert(
      new NetSuiteScheduledOperationAdapter().execute(null).hasFailures(),
      'Only a persisted claimed schedule may execute.'
    );
    Test.startTest();
    ConnectorExecutionResult scheduleResult =
      new NetSuiteScheduledOperationAdapter().execute(schedule);
    Test.stopTest();
    System.assertEquals(false, scheduleResult.hasFailures());
    System.assertNotEquals(null, scheduleResult.asyncJobId);
  }

  @IsTest
  static void webhookRestResourceRejectsUnsafeAndUnreadyRequests() {
    RestRequest request = new RestRequest();
    request.httpMethod = 'POST';
    request.requestURI = '/services/apexrest/quickbridge/webhooks/not-valid!';
    request.requestBody = Blob.valueOf('{"id":"event"}');
    RestContext.request = request;
    RestContext.response = new RestResponse();

    QuickbridgeWebhookRestResource.receive();

    System.assertEquals(400, RestContext.response.statusCode);
    System.assert(
      RestContext.response.responseBody.toString().contains('could not be processed')
    );

    request.requestURI = '/services/apexrest/quickbridge/webhooks/meta';
    RestContext.response = new RestResponse();
    QuickbridgeWebhookRestResource.receive();
    System.assertEquals(503, RestContext.response.statusCode);
    System.assert(
      RestContext.response.responseBody.toString().contains('not ready')
    );

    Connector_Instance__c meta = connectorInstance('meta', 'Meta_NC', 'Meta_EC');
    meta.Active__c = true;
    meta.Health_Status__c = 'Ready';
    insert meta;
    List<Connector_Config_Value__c> requiredMetaValues =
      new List<Connector_Config_Value__c>();
    for (Connector_Config_Field__mdt definition : [
      SELECT Field_Key__c
      FROM Connector_Config_Field__mdt
      WHERE Connector_Key__c = 'meta'
        AND Required__c = true
        AND Secret__c = false
    ]) {
      requiredMetaValues.add(
        configValue(meta.Id, 'meta', definition.Field_Key__c, 'test-value')
      );
    }
    insert requiredMetaValues;
    insert new Connector_Secret__c(
      Connector_Key__c = 'meta',
      Secret_Kind__c = 'webhookSigningSecret',
      Secret_Value__c = 'rest-webhook-secret',
      Active__c = true
    );
    String acceptedBody = '{"object":"page","entry":[{"id":"rest-event"}]}';
    String acceptedSignature = 'sha256=' + EncodingUtil.convertToHex(
      Crypto.generateMac(
        'HmacSHA256',
        Blob.valueOf(acceptedBody),
        Blob.valueOf('rest-webhook-secret')
      )
    );
    request.requestBody = Blob.valueOf(acceptedBody);
    request.addHeader('X-Hub-Signature-256', acceptedSignature);
    RestContext.response = new RestResponse();

    QuickbridgeWebhookRestResource.receive();

    System.assertEquals(202, RestContext.response.statusCode);
    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM Integration_Work_Item__c
        WHERE Integration__c = 'meta' AND Operation__c = 'WebhookEvent'
      ]
    );
  }

  @IsTest
  static void workProcessorRoutesMetadataCapabilityAndMarksBatchRunning() {
    Integration_Work_Item__c workItem = new Integration_Work_Item__c(
      Integration__c = 'meta',
      Operation__c = 'LeadAd',
      Status__c = 'Processing',
      Processor_Token__c = 'processor-token',
      Attempt_Count__c = 1,
      Unique_Key__c = 'meta:LeadAd:processor-test'
    );
    insert workItem;

    new IntegrationWorkProcessor(workItem.Id, 'superseded-token').execute(null);
    System.assertEquals(
      'Processing',
      [SELECT Status__c FROM Integration_Work_Item__c WHERE Id = :workItem.Id].Status__c,
      'A superseded processor must exit without touching the work item.'
    );

    new IntegrationWorkProcessor(workItem.Id, 'processor-token').execute(null);
    Integration_Work_Item__c routed = [
      SELECT Status__c, Processor_Job_Id__c
      FROM Integration_Work_Item__c
      WHERE Id = :workItem.Id
    ];
    System.assertEquals('Processing', routed.Status__c);
    System.assertNotEquals(null, routed.Processor_Job_Id__c);
  }

  @IsTest
  static void readinessSurfacesMissingInactiveAndCredentialIssues() {
    ConnectorReadinessService.Assessment missing =
      ConnectorReadinessService.assess('stripe', true);
    System.assertEquals(false, missing.operationalReady);
    System.assert(missing.issues.contains('The connector instance is missing.'));

    Connector_Instance__c stripe = connectorInstance('stripe', null, null);
    insert stripe;
    ConnectorReadinessService.Assessment incomplete =
      ConnectorReadinessService.assess('stripe', true);
    System.assertEquals(false, incomplete.configurationReady);
    System.assert(incomplete.issues.contains('The Named Credential reference is missing.'));
    System.assert(incomplete.issues.contains('The External Credential reference is missing.'));
    System.assert(incomplete.issues.contains('The connector is inactive.'));

    ConnectorReadinessService.Evaluation missingInstanceProbe =
      ConnectorReadinessService.evaluateForProbe(null);
    System.assertEquals(false, missingInstanceProbe.ready);
    System.assert(missingInstanceProbe.message.contains('instance is missing'));
    System.assertEquals(
      0,
      ConnectorReadinessService.evaluateForDashboard(null).size()
    );

    try {
      ConnectorReadinessService.assess('../stripe', true);
      System.assert(false, 'Unsafe connector keys must be rejected before SOQL.');
    } catch (ConnectorReadinessService.ConnectorReadinessException expected) {
      System.assert(expected.getMessage().contains('invalid'));
    }
  }

  private static Connector_Instance__c connectorInstance(
    String connectorKey,
    String namedCredential,
    String externalCredential
  ) {
    return new Connector_Instance__c(
      Name = connectorKey + ' Sandbox',
      Connector_Key__c = connectorKey,
      Connector_Label__c = connectorKey,
      Active__c = false,
      Environment__c = 'Sandbox',
      Health_Status__c = 'Unknown',
      Named_Credential__c = namedCredential,
      External_Credential__c = externalCredential
    );
  }

  private static Connector_Config_Value__c configValue(
    Id connectorInstanceId,
    String connectorKey,
    String fieldKey,
    String value
  ) {
    return new Connector_Config_Value__c(
      Name = connectorKey + '.' + fieldKey,
      Connector_Instance__c = connectorInstanceId,
      Connector_Key__c = connectorKey,
      Field_Key__c = fieldKey,
      Value__c = value,
      Is_Secret_Reference__c = false
    );
  }

  private static PaymentCapabilityRequest paymentRequest(String connectorKey) {
    PaymentCapabilityRequest request = new PaymentCapabilityRequest();
    request.connectorKey = connectorKey;
    request.amount = 25;
    request.currencyCode = 'USD';
    request.idempotencyKey = connectorKey + ':test:payment';
    return request;
  }

  private static Scheduled_Integration_Job__c claimedSchedule(
    String logicalKey,
    String leaseToken,
    String connector,
    String operation,
    String direction
  ) {
    return new Scheduled_Integration_Job__c(
      Logical_Job_Key__c = logicalKey,
      Scheduler_Name__c = logicalKey,
      Integration_Type__c = connector,
      Source_Object__c = operation,
      Direction__c = direction,
      Frequency_Value__c = 5,
      Frequency_Type__c = 'Minutes',
      Status__c = 'Claimed',
      Lease_Token__c = leaseToken,
      Lease_Expires_At__c = System.now().addMinutes(10),
      Next_Run_At__c = System.now().addMinutes(-1)
    );
  }
}