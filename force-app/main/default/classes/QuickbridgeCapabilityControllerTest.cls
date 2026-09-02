@IsTest
private class QuickbridgeCapabilityControllerTest {
  private class CapabilityTransport implements ConnectorHttpClient.Transport {
    Integer calls = 0;
    HttpRequest lastRequest;

    public HttpResponse send(HttpRequest request) {
      calls++;
      lastRequest = request;
      HttpResponse response = new HttpResponse();
      response.setStatusCode(200);
      response.setStatus('OK');
      response.setBody(
        '{"id":"provider-reference","status":"succeeded","client_secret":"client-action"}'
      );
      return response;
    }
  }

  @TestSetup
  static void setupProviders() {
    List<Connector_Instance__c> connectors = new List<Connector_Instance__c>{
      instance('stripe', 'Stripe_NC', 'Stripe_EC'),
      instance('fedex', 'FedEx_NC', 'FedEx_EC')
    };
    insert connectors;
    Map<String, Id> idByKey = new Map<String, Id>();
    for (Connector_Instance__c connector : connectors) {
      idByKey.put(connector.Connector_Key__c, connector.Id);
    }
    insert new List<Connector_Config_Value__c>{
      config(idByKey.get('stripe'), 'stripe', 'publishableKey', 'pk_test_public'),
      config(idByKey.get('stripe'), 'stripe', 'useSandbox', 'true'),
      config(idByKey.get('fedex'), 'fedex', 'accountNumber', 'sandbox-account')
    };
  }

  @IsTest
  static void providerDiscoveryAndPublicPaymentSettingsAreMetadataDriven() {
    List<QuickbridgeCapabilityController.ProviderOption> payments =
      QuickbridgeCapabilityController.availableProviders('payment.checkout');
    List<QuickbridgeCapabilityController.ProviderOption> carriers =
      QuickbridgeCapabilityController.availableProviders('carrier.operation');
    System.assertEquals(1, payments.size());
    System.assertEquals('stripe', payments[0].key);
    System.assertEquals(1, carriers.size());
    System.assertEquals('fedex', carriers[0].key);

    Map<String, String> settings =
      QuickbridgeCapabilityController.paymentSettings('stripe');
    System.assertEquals('pk_test_public', settings.get('publishableKey'));
    System.assertEquals(1, settings.size(), 'Only explicitly public browser settings may be returned.');

    try {
      QuickbridgeCapabilityController.availableProviders('unsafe.capability');
      System.assert(false, 'Unknown capabilities must be rejected.');
    } catch (AuraHandledException expected) {
      System.assert(String.isNotBlank(expected.getMessage()));
    }
  }

  @IsTest
  static void paymentActionsPersistOutcomesAndNeverAcceptRawCardData() {
    Account sourceRecord = new Account(Name = 'Capability Payment Source');
    insert sourceRecord;
    CapabilityTransport transport = new CapabilityTransport();
    ConnectorHttpClient.setTestTransport(transport);

    PaymentCapabilityResult initialized = QuickbridgeCapabilityController.submitPayment(
      'stripe', sourceRecord.Id, 15.25, 'usd', null,
      'stripe:account:initialize', '{}', 'initialize'
    );
    System.assertEquals(true, initialized.successful);
    Account afterSuccess = [
      SELECT Integration_Success__c, Integration_Error__c,
        Last_Integration__c, Last_Integration_Operation__c
      FROM Account WHERE Id = :sourceRecord.Id
    ];
    System.assertEquals(true, afterSuccess.Integration_Success__c);
    System.assertEquals(false, afterSuccess.Integration_Error__c);
    System.assertEquals('stripe', afterSuccess.Last_Integration__c);

    PaymentCapabilityResult blocked = QuickbridgeCapabilityController.submitPayment(
      'stripe', sourceRecord.Id, 15.25, 'USD', 'pm_browser_token',
      'stripe:account:blocked', '{"cvv":"123"}', 'execute'
    );
    System.assertEquals(false, blocked.successful);
    System.assert(blocked.errorSummary.contains('Raw card data'));
    System.assertEquals(1, transport.calls, 'Rejected card data must not reach a callout.');
    Account afterFailure = [
      SELECT Integration_Success__c, Integration_Error__c
      FROM Account WHERE Id = :sourceRecord.Id
    ];
    System.assertEquals(false, afterFailure.Integration_Success__c);
    System.assertEquals(true, afterFailure.Integration_Error__c);
    System.assertEquals(
      1,
      [SELECT COUNT() FROM Error_Log__c WHERE Source_Record_Id__c = :String.valueOf(sourceRecord.Id)]
    );

    QuickbridgeCapabilityController.submitPayment(
      'stripe', sourceRecord.Id, null, 'USD', 'pi_reference',
      'stripe:account:recover', '{}', 'recover'
    );
    QuickbridgeCapabilityController.submitPayment(
      'stripe', sourceRecord.Id, 5, 'USD', 'pi_reference',
      'stripe:account:refund', '{}', 'refund'
    );
    ConnectorHttpClient.clearTestTransport();
  }

  @IsTest
  static void carrierActionsUseTheAllowlistedAdapterAndStableKey() {
    Account sourceRecord = new Account(Name = 'Capability Carrier Source');
    insert sourceRecord;
    CapabilityTransport transport = new CapabilityTransport();
    ConnectorHttpClient.setTestTransport(transport);
    List<String> operations = new List<String>{
      'validateAddress', 'quoteRates', 'createShipment', 'recoverLabel',
      'createReturnLabel', 'voidShipment', 'tracking'
    };
    for (String operation : operations) {
      ConnectorExecutionResult result =
        QuickbridgeCapabilityController.executeCarrierOperation(
          'fedex',
          operation,
          sourceRecord.Id,
          JSON.serialize(new Map<String, Object>{
            'idempotencyKey' => 'fedex:' + operation + ':' + sourceRecord.Id
          })
        );
      System.assertEquals(false, result.hasFailures());
    }
    System.assertEquals(operations.size(), transport.calls);
    System.assertEquals(
      true,
      [SELECT Integration_Success__c FROM Account WHERE Id = :sourceRecord.Id]
        .Integration_Success__c
    );
    ConnectorHttpClient.clearTestTransport();

    try {
      QuickbridgeCapabilityController.executeCarrierOperation(
        'fedex', 'unsupported', sourceRecord.Id, '{}'
      );
      System.assert(false, 'Unknown carrier actions must be rejected.');
    } catch (AuraHandledException expected) {
      System.assert(String.isNotBlank(expected.getMessage()));
    }
  }

  @IsTest
  static void inactiveOrMalformedRequestsAreBlockedBeforeExecution() {
    update new Connector_Instance__c(
      Id = [SELECT Id FROM Connector_Instance__c WHERE Connector_Key__c = 'stripe'].Id,
      Active__c = false
    );
    try {
      QuickbridgeCapabilityController.paymentSettings('stripe');
      System.assert(false, 'Inactive providers must not expose checkout settings.');
    } catch (AuraHandledException expected) {
      System.assert(String.isNotBlank(expected.getMessage()));
    }
    try {
      QuickbridgeCapabilityController.executeCarrierOperation(
        'fedex', 'quoteRates', null, '{bad json'
      );
      System.assert(false, 'A missing source record must be rejected.');
    } catch (AuraHandledException expected) {
      System.assert(String.isNotBlank(expected.getMessage()));
    }
  }

  private static Connector_Instance__c instance(
    String connectorKey,
    String namedCredential,
    String externalCredential
  ) {
    return new Connector_Instance__c(
      Name = connectorKey + ' Capability',
      Connector_Key__c = connectorKey,
      Connector_Label__c = connectorKey,
      Environment__c = 'Sandbox',
      Named_Credential__c = namedCredential,
      External_Credential__c = externalCredential,
      Health_Status__c = 'Ready',
      Active__c = true
    );
  }

  private static Connector_Config_Value__c config(
    Id connectorId,
    String connectorKey,
    String fieldKey,
    String value
  ) {
    return new Connector_Config_Value__c(
      Name = connectorKey + '.' + fieldKey,
      Connector_Instance__c = connectorId,
      Connector_Key__c = connectorKey,
      Field_Key__c = fieldKey,
      Value__c = value,
      Is_Secret_Reference__c = false
    );
  }
}