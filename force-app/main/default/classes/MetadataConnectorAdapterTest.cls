@IsTest
private class MetadataConnectorAdapterTest {
  private class CapturingTransport implements ConnectorHttpClient.Transport {
    HttpRequest lastRequest;

    public HttpResponse send(HttpRequest request) {
      lastRequest = request;
      HttpResponse response = new HttpResponse();
      response.setStatusCode(200);
      response.setStatus('OK');
      response.setBody(
        '{"id":"provider-id","status":"pending","url":"https://payments.example.test/session"}'
      );
      return response;
    }
  }

  @IsTest
  static void adapterModeSelectsTheCorrectAdapterForEveryCapability() {
    List<List<String>> capabilities = new List<List<String>>{
      new List<String>{ 'health', 'LegacyHealth', 'MetadataConnectorHealthProbe' },
      new List<String>{ 'work', 'LegacyWork', 'MetadataConnectorWorkAdapter' },
      new List<String>{ 'schedule', 'LegacySchedule', 'MetadataConnectorScheduleAdapter' },
      new List<String>{ 'webhook', 'LegacyWebhook', 'MetadataConnectorWebhookAdapter' },
      new List<String>{ 'carrier', 'LegacyCarrier', 'MetadataConnectorCarrierAdapter' },
      new List<String>{ 'payment', 'LegacyPayment', 'MetadataConnectorPaymentAdapter' },
      new List<String>{ 'hosted', 'LegacyHosted', 'MetadataConnectorHostedPaymentAdapter' }
    };
    for (List<String> capability : capabilities) {
      System.assertEquals(
        capability[1],
        ConnectorCapabilityRouter.selectAdapterClass(
          capability[1],
          capability[2],
          'Legacy'
        ),
        capability[0] + ' must preserve legacy routing.'
      );
      System.assertEquals(
        capability[2],
        ConnectorCapabilityRouter.selectAdapterClass(
          capability[1],
          capability[2],
          'Dynamic'
        ),
        capability[0] + ' must use the metadata adapter in Dynamic mode.'
      );
    }
    System.assertEquals(
      null,
      ConnectorCapabilityRouter.selectAdapterClass('LegacyHealth', null, 'Dynamic'),
      'A Dynamic connector must fail closed when its metadata adapter is absent.'
    );
  }

  @IsTest
  static void routerKeepsLegacyAndBindsDynamicMetadataAdapters() {
    insert new List<Connector_Instance__c>{
      connector('klaviyo', 'Legacy'),
      connector('meta', 'Dynamic')
    };
    ConnectorCapabilityRouter.clearTestAdapters();

    System.assert(
      ConnectorCapabilityRouter.healthProbe('klaviyo') instanceof KlaviyoHealthProbe,
      'Klaviyo must retain the deployed legacy health probe until its mode changes.'
    );
    System.assert(
      ConnectorCapabilityRouter.healthProbe('meta') instanceof MetadataConnectorHealthProbe,
      'Meta must use the allowlisted generic health probe in Dynamic mode.'
    );
    System.assert(
      ConnectorCapabilityRouter.workHandler('meta', 'LeadAd') instanceof
        MetadataConnectorWorkAdapter,
      'The router must bind the connector key before returning the generic worker.'
    );
  }

  @IsTest
  static void metadataAdaptersUseGenericContractsAndPreserveIdempotency() {
    List<Connector_Instance__c> instances = new List<Connector_Instance__c>{
      connector('meta', 'Dynamic'),
      connector('fedex', 'Legacy'),
      connector('stripe', 'Legacy'),
      connector('paypal', 'Legacy')
    };
    insert instances;
    Map<String, Id> connectorIds = new Map<String, Id>();
    for (Connector_Instance__c instanceRecord : instances) {
      connectorIds.put(instanceRecord.Connector_Key__c, instanceRecord.Id);
    }
    insert new List<Connector_Config_Value__c>{
      config(connectorIds.get('meta'), 'meta', 'healthPath', '/health'),
      config(connectorIds.get('meta'), 'meta', 'webhookOperation', 'WebhookEvent'),
      config(connectorIds.get('meta'), 'meta', 'webhookSignatureHeader', 'X-Signature'),
      config(connectorIds.get('meta'), 'meta', 'webhookSignatureAlgorithm', 'HmacSHA256'),
      config(connectorIds.get('meta'), 'meta', 'webhookSignaturePrefix', 'sha256='),
      config(connectorIds.get('meta'), 'meta', 'webhookEventIdPath', 'entry.0.id'),
      config(connectorIds.get('meta'), 'meta', 'webhookChallengeParameter', 'challenge'),
      config(connectorIds.get('meta'), 'meta', 'webhookVerifyTokenParameter', 'verify_token'),
      config(connectorIds.get('meta'), 'meta', 'webhookChallengeModeParameter', 'mode'),
      config(connectorIds.get('meta'), 'meta', 'webhookChallengeModeValue', 'subscribe'),
      config(connectorIds.get('fedex'), 'fedex', 'createShipmentPath', '/shipments'),
      config(connectorIds.get('stripe'), 'stripe', 'initializePath', '/payments'),
      config(connectorIds.get('paypal'), 'paypal', 'hostedPaymentPath', '/hosted-payments')
    };
    insert new List<Connector_Secret__c>{
      new Connector_Secret__c(
        Connector_Key__c = 'meta',
        Secret_Kind__c = 'webhookSigningSecret',
        Secret_Value__c = 'unit-webhook-secret',
        Active__c = true
      ),
      new Connector_Secret__c(
        Connector_Key__c = 'meta',
        Secret_Kind__c = 'webhookVerifyToken',
        Secret_Value__c = 'unit-verify-token',
        Active__c = true
      )
    };

    CapturingTransport transport = new CapturingTransport();
    ConnectorHttpClient.setTestTransport(transport);

    MetadataConnectorHealthProbe health = new MetadataConnectorHealthProbe();
    health.bindConnector('meta');
    ConnectorHealthProbeResult healthResult = health.probe(instances[0]);
    System.assertEquals(true, healthResult.successful);
    System.assertEquals('callout:Meta_NC/health', transport.lastRequest.getEndpoint());
    System.assertEquals(
      false,
      health.probe(instances[1]).successful,
      'A bound dynamic health adapter must reject a different connector instance.'
    );

    MetadataConnectorWorkAdapter work = new MetadataConnectorWorkAdapter();
    System.assertEquals(true, work.handle(null).hasFailures());
    work.bindConnector('meta');
    System.assertEquals(true, work.handle(null).hasFailures());

    MetadataConnectorScheduleAdapter schedule =
      new MetadataConnectorScheduleAdapter();
    System.assertEquals(true, schedule.execute(null).hasFailures());
    schedule.bindConnector('meta');
    System.assertEquals(true, schedule.execute(null).hasFailures());

    MetadataConnectorCarrierAdapter carrier = new MetadataConnectorCarrierAdapter();
    carrier.bindConnector('fedex');
    ConnectorExecutionResult carrierResult = carrier.createShipment(
      new Map<String, Object>{ 'idempotencyKey' => 'fedex:test:1' }
    );
    System.assertEquals(false, carrierResult.hasFailures());
    System.assertEquals(
      'fedex:test:1',
      transport.lastRequest.getHeader('Idempotency-Key')
    );
    MetadataConnectorCarrierAdapter unconfiguredCarrier =
      new MetadataConnectorCarrierAdapter();
    unconfiguredCarrier.bindConnector('ups');
    System.assertEquals(
      true,
      unconfiguredCarrier.quoteRates(new Map<String, Object>()).hasFailures(),
      'A generic carrier must fail closed without its configured operation path.'
    );

    MetadataConnectorPaymentAdapter payment = new MetadataConnectorPaymentAdapter();
    payment.bindConnector('stripe');
    PaymentCapabilityRequest paymentRequest = new PaymentCapabilityRequest();
    paymentRequest.connectorKey = 'stripe';
    paymentRequest.amount = 10;
    paymentRequest.currencyCode = 'USD';
    paymentRequest.idempotencyKey = 'stripe:test:1';
    PaymentCapabilityResult paymentResult = payment.initializePayment(paymentRequest);
    System.assertEquals(true, paymentResult.successful);
    System.assertEquals('provider-id', paymentResult.providerReference);

    MetadataConnectorHostedPaymentAdapter hosted =
      new MetadataConnectorHostedPaymentAdapter();
    hosted.bindConnector('paypal');
    HostedPaymentRequest hostedRequest = new HostedPaymentRequest();
    hostedRequest.connectorKey = 'paypal';
    hostedRequest.amount = 10;
    hostedRequest.currencyCode = 'USD';
    hostedRequest.customerEmail = 'buyer@example.test';
    hostedRequest.idempotencyKey = 'paypal:test:1';
    HostedPaymentResult hostedResult = hosted.createHostedPayment(hostedRequest);
    System.assertEquals(true, hostedResult.successful);
    System.assertEquals('https://payments.example.test/session', hostedResult.hostedUrl);
    System.assertEquals(
      false,
      hosted.createHostedPayment(new HostedPaymentRequest()).successful,
      'Hosted payment requests must fail closed before a callout.'
    );

    String body = '{"entry":[{"id":"event-1"}]}';
    String signature = 'sha256=' + EncodingUtil.convertToHex(
      Crypto.generateMac(
        'HmacSHA256',
        Blob.valueOf(body),
        Blob.valueOf('unit-webhook-secret')
      )
    );
    MetadataConnectorWebhookAdapter webhook = new MetadataConnectorWebhookAdapter();
    webhook.bindConnector('meta');
    ConnectorExecutionResult eventResult = webhook.handle(
      body,
      new Map<String, String>{ 'X-Signature' => signature }
    );
    System.assertEquals(false, eventResult.hasFailures());
    System.assertEquals(
      'event-1',
      [
        SELECT Source_External_Id__c
        FROM Integration_Work_Item__c
        WHERE Integration__c = 'meta' AND Operation__c = 'WebhookEvent'
        LIMIT 1
      ].Source_External_Id__c
    );
    WebhookChallengeResult challenge = webhook.handleChallenge(
      new Map<String, String>{
        'challenge' => 'accepted-value',
        'verify_token' => 'unit-verify-token',
        'mode' => 'subscribe'
      }
    );
    System.assertEquals(true, challenge.successful);
    System.assertEquals('accepted-value', challenge.responseBody);
    System.assertEquals(
      false,
      webhook.handleChallenge(
        new Map<String, String>{ 'challenge' => 'rejected-value' }
      ).successful,
      'A challenge without the configured verification token must be rejected.'
    );

    RestRequest restRequest = new RestRequest();
    restRequest.requestURI = '/services/apexrest/quickbridge/webhooks/meta';
    restRequest.httpMethod = 'GET';
    RestContext.request = restRequest;
    RestContext.response = new RestResponse();
    QuickbridgeWebhookRestResource.challenge();
    System.assertEquals(
      503,
      RestContext.response.statusCode,
      'Inactive connectors must not accept a webhook challenge.'
    );
    restRequest.requestURI = '/services/apexrest/quickbridge/webhooks/not-valid!';
    RestContext.response = new RestResponse();
    QuickbridgeWebhookRestResource.challenge();
    System.assertEquals(
      400,
      RestContext.response.statusCode,
      'Unsafe webhook paths must not reach a capability adapter.'
    );

    Set<String> configuredMetaKeys = new Set<String>{
      'healthPath',
      'webhookOperation',
      'webhookSignatureHeader',
      'webhookSignatureAlgorithm',
      'webhookSignaturePrefix',
      'webhookEventIdPath',
      'webhookChallengeParameter',
      'webhookVerifyTokenParameter',
      'webhookChallengeModeParameter',
      'webhookChallengeModeValue'
    };
    List<Connector_Config_Value__c> requiredMetaConfiguration =
      new List<Connector_Config_Value__c>();
    for (Connector_Config_Field__mdt definition : [
      SELECT Field_Key__c
      FROM Connector_Config_Field__mdt
      WHERE Connector_Key__c = 'meta'
        AND Required__c = true
        AND Secret__c = false
    ]) {
      if (configuredMetaKeys.add(definition.Field_Key__c)) {
        requiredMetaConfiguration.add(
          config(
            connectorIds.get('meta'),
            'meta',
            definition.Field_Key__c,
            'test-value'
          )
        );
      }
    }
    if (!requiredMetaConfiguration.isEmpty()) insert requiredMetaConfiguration;
    instances[0].Active__c = true;
    instances[0].Health_Status__c = 'Ready';
    update instances[0];
    restRequest.requestURI = '/services/apexrest/quickbridge/webhooks/meta';
    restRequest.params.put('challenge', 'accepted-rest-value');
    restRequest.params.put('verify_token', 'unit-verify-token');
    restRequest.params.put('mode', 'subscribe');
    RestContext.response = new RestResponse();
    ConnectorCapabilityRouter.clearTestAdapters();
    QuickbridgeWebhookRestResource.challenge();
    System.assertEquals(200, RestContext.response.statusCode);
    System.assertEquals(
      'accepted-rest-value',
      RestContext.response.responseBody.toString()
    );
    ConnectorHttpClient.clearTestTransport();
  }

  private static Connector_Instance__c connector(String connectorKey, String mode) {
    String baseName = ConnectorCredentialPolicy.expectedNamedCredential(connectorKey);
    return new Connector_Instance__c(
      Name = connectorKey + ' Dynamic Test',
      Connector_Key__c = connectorKey,
      Connector_Label__c = connectorKey,
      Active__c = false,
      Environment__c = 'Sandbox',
      Health_Status__c = 'Unknown',
      Adapter_Mode__c = mode,
      Named_Credential__c = baseName,
      External_Credential__c = ConnectorCredentialPolicy.expectedExternalCredential(
        connectorKey
      )
    );
  }

  private static Connector_Config_Value__c config(
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
}