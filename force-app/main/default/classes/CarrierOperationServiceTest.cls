@IsTest
private class CarrierOperationServiceTest {
  private class Transport implements ConnectorHttpClient.Transport {
    Integer calls = 0;
    HttpRequest lastRequest;
    Integer statusCode = 200;
    String body = '{"tracking":{"trackingNumber":"TRACK-1","latestStatus":"In transit","events":[{"code":"IT","description":"In transit","timestamp":"2026-09-10T00:00:00Z"}]},"shipment":{"externalShipmentId":"SHIP-1","masterTrackingNumber":"TRACK-1"},"rates":[{"serviceType":"GROUND","serviceName":"Ground","totalNetCharge":12.50,"currencyCode":"USD"}]}';
    public HttpResponse send(HttpRequest request) {
      calls++; lastRequest = request;
      HttpResponse response = new HttpResponse();
      response.setStatusCode(statusCode); response.setStatus(statusCode < 300 ? 'OK' : 'Carrier Error');
      response.setBody(body);
      return response;
    }
  }

  @TestSetup
  static void setupData() {
    PermissionSet carrierAccess = [
      SELECT Id FROM PermissionSet WHERE Name = 'Quickbridge_Carrier_User' LIMIT 1
    ];
    insert new PermissionSetAssignment(
      AssigneeId = UserInfo.getUserId(), PermissionSetId = carrierAccess.Id
    );
    User runtimeUser = new User(
      Alias='carrier', Email='carrier-test@example.com', EmailEncodingKey='UTF-8',
      LastName='Carrier Runtime', LanguageLocaleKey='en_US', LocaleSidKey='en_US',
      ProfileId=UserInfo.getProfileId(), TimeZoneSidKey='America/Los_Angeles',
      UserName='carrier-runtime-' + String.valueOf(DateTime.now().getTime()) + '@example.com'
    );
    insert runtimeUser;
    insert new PermissionSetAssignment(
      AssigneeId = runtimeUser.Id, PermissionSetId = carrierAccess.Id
    );
    PermissionSet adminAccess = [
      SELECT Id FROM PermissionSet WHERE Name = 'Quickbridge_Admin' LIMIT 1
    ];
    insert new PermissionSetAssignment(
      AssigneeId = runtimeUser.Id, PermissionSetId = adminAccess.Id
    );
    Connector_Instance__c connector = new Connector_Instance__c(
      Name='FedEx Test', Connector_Key__c='fedex', Connector_Label__c='FedEx',
      Environment__c='Sandbox', Named_Credential__c='FedEx_NC',
      External_Credential__c='FedEx_EC', Active__c=true, Health_Status__c='Ready'
    );
    insert connector;
    insert new Connector_Config_Value__c(
      Name='fedex.accountNumber', Connector_Instance__c=connector.Id, Connector_Key__c='fedex',
      Field_Key__c='accountNumber', Value__c='test-account', Is_Secret_Reference__c=false
    );
    insert new List<Connector_Instance__c>{
      new Connector_Instance__c(Name='UPS Test', Connector_Key__c='ups', Connector_Label__c='UPS', Environment__c='Sandbox', Named_Credential__c='UPS_NC', External_Credential__c='UPS_EC', Active__c=true, Health_Status__c='Ready'),
      new Connector_Instance__c(Name='DHL Test', Connector_Key__c='dhl', Connector_Label__c='DHL', Environment__c='Sandbox', Named_Credential__c='DHL_NC', External_Credential__c='DHL_EC', Active__c=true, Health_Status__c='Ready')
    };
  }

  @IsTest
  static void allProvidersExposeTheSameMetadataDefinedActions() {
    grantCarrierAccess();
    for (String connector : new List<String>{'fedex','ups','dhl'}) {
      List<CarrierOperationModels.Definition> definitions = CarrierOperationCatalog.definitionsFor(connector);
      System.assertEquals(7, definitions.size(), connector + ' must expose all carrier workflows.');
      System.assertNotEquals(null, CarrierOperationCatalog.requireDefinition(connector, 'recoverLabel'));
    }
  }

  @IsTest
  static void catalogRejectsUnsupportedOperationsAndDescribesActionRequirements() {
    System.assertEquals(false, CarrierOperationCatalog.isMutation('quoteRates'));
    System.assertEquals(true, CarrierOperationCatalog.isMutation('voidShipment'));
    System.assertEquals(false, CarrierOperationCatalog.needsShipment('createShipment'));
    System.assertEquals(true, CarrierOperationCatalog.needsShipment('syncTrackingStatus'));
    System.assertEquals('', CarrierOperationCatalog.normalize(null));
    System.assertEquals(0, CarrierOperationCatalog.definitionsFor('usps').size());
    try {
      CarrierOperationCatalog.requireDefinition('usps', 'createShipment');
      System.assert(false, 'Unknown carriers must not expose an operation.');
    } catch (CarrierOperationCatalog.CarrierOperationException expected) {
      System.assert(expected.getMessage().contains('Unsupported'));
    }
    CarrierOperationCatalog.forceTestFallback = true;
    try {
      for (String connector : new List<String>{ 'fedex', 'ups', 'dhl' }) {
        System.assertNotEquals(null, CarrierOperationCatalog.requireDefinition(connector, 'createShipment').requiredRequestPaths);
        System.assertNotEquals(null, CarrierOperationCatalog.requireDefinition(connector, 'createReturnLabel').responsePaths);
      }
      System.assertEquals(7, CarrierOperationCatalog.definitionsFor('fedex').size());
    } finally {
      CarrierOperationCatalog.forceTestFallback = false;
    }
    CarrierOperationCatalog.testRows = new List<Carrier_Operation__mdt>{
      new Carrier_Operation__mdt(
        Connector_Key__c='fedex', Operation_Key__c='createshipment', MasterLabel='Create shipment',
        Requires_Shipment__c=false, Requires_Idempotency__c=true, Enabled__c=true
      )
    };
    try {
      CarrierOperationModels.Definition metadataDefinition = CarrierOperationCatalog.requireDefinition('fedex', 'createShipment');
      System.assertEquals('requestedShipment.shipper,requestedShipment.recipient,requestedShipment.requestedPackageLineItems', metadataDefinition.requiredRequestPaths);
      System.assertEquals('shipment.externalShipmentId,shipment.masterTrackingNumber,label.content', metadataDefinition.responsePaths);
      System.assertEquals(1, CarrierOperationCatalog.definitionsFor('fedex').size());
    } finally {
      CarrierOperationCatalog.testRows = null;
    }
  }

  @IsTest
  static void carrierUserCanWriteCarrierRuntimeFields() {
    System.runAs(carrierRuntimeUser()) {
      assertCreateable(new Carrier_Shipment__c(
        Connector_Key__c='fedex', Source_Record_Id__c='001000000000001AAA',
        Source_Object__c='Account', Master_Tracking_Number__c='TRACK-PERM', Shipment_Status__c='Label created'
      ));
      assertCreateable(new Carrier_Operation_Attempt__c(
        Request_Key__c='permission-test', Connector_Key__c='fedex', Operation_Key__c='createshipment',
        Source_Record_Id__c='001000000000001AAA', Status__c='Prepared'
      ));
    }
  }

  @IsTest
  static void actionContextOnlyExposesReadyProvidersAndLinkedShipments() {
    System.runAs(carrierRuntimeUser()) {
    Account source = new Account(Name='Carrier Source'); insert source;
    System.assertEquals(true, Carrier_Shipment__c.SObjectType.getDescribe().isCreateable(), 'Carrier shipment create permission is required for the runtime user.');
    System.assertEquals(true, Schema.SObjectType.Carrier_Shipment__c.fields.Connector_Key__c.isCreateable(), 'Carrier connector field must be createable.');
    Carrier_Shipment__c shipment = new Carrier_Shipment__c(
      Connector_Key__c='fedex', Source_Record_Id__c=String.valueOf(source.Id),
      Source_Object__c='Account', Master_Tracking_Number__c='TRACK-1', Shipment_Status__c='In transit'
    ); insert shipment;
    CarrierOperationModels.ActionContext context = CarrierOperationService.getActionContext(source.Id);
    System.assertEquals(1, context.providers.size());
    System.assertEquals('fedex', context.providers[0].key);
    System.assertEquals(3, context.operations.size(), 'Only shipment-backed actions are available until request mappings are saved.');
    System.assertEquals(false, new Set<String>(new List<String>{
      context.operations[0].operationKey, context.operations[1].operationKey, context.operations[2].operationKey
    }).contains('createshipment'));
    System.assertEquals(shipment.Id, context.shipments[0].id);
    }
  }

  @IsTest
  static void trackingUsesTheAllowlistedAdapterAndDeduplicatesEvents() {
    System.runAs(carrierRuntimeUser()) {
    Account source = new Account(Name='Tracking Source'); insert source;
    Carrier_Shipment__c shipment = new Carrier_Shipment__c(
      Connector_Key__c='fedex', Source_Record_Id__c=String.valueOf(source.Id),
      Source_Object__c='Account', Master_Tracking_Number__c='TRACK-1', Shipment_Status__c='Label created'
    ); insert shipment;
    Transport transport = new Transport(); ConnectorHttpClient.setTestTransport(transport);
    CarrierOperationModels.Result first = CarrierOperationService.execute('fedex','syncTrackingStatus',source.Id,shipment.Id,null);
    CarrierOperationModels.Result second = CarrierOperationService.execute('fedex','syncTrackingStatus',source.Id,shipment.Id,null);
    ConnectorHttpClient.clearTestTransport();
    assertSuccess(first);
    assertSuccess(second);
    System.assertEquals(2, transport.calls);
    System.assertEquals(1, [SELECT COUNT() FROM Carrier_Tracking_Event__c]);
    Carrier_Shipment__c saved = [SELECT Latest_Status__c, Master_Tracking_Number__c FROM Carrier_Shipment__c WHERE Id=:shipment.Id];
    System.assertEquals('In transit', saved.Latest_Status__c);
    System.assertEquals('TRACK-1', saved.Master_Tracking_Number__c);
    }
  }

  @IsTest
  static void scheduledTrackingServiceSynchronizesOneNonTerminalShipment() {
    System.runAs(carrierRuntimeUser()) {
    Account source = new Account(Name='Scheduled Tracking Source'); insert source;
    Carrier_Shipment__c shipment = new Carrier_Shipment__c(
      Connector_Key__c='fedex', Source_Record_Id__c=String.valueOf(source.Id),
      Source_Object__c='Account', Master_Tracking_Number__c='TRACK-SCHEDULED', Shipment_Status__c='Label created'
    ); insert shipment;
    Transport transport = new Transport(); ConnectorHttpClient.setTestTransport(transport);
    try {
      CarrierOperationModels.Result result = CarrierTrackingService.synchronizeNext('fedex');
      assertSuccess(result);
      System.assertEquals(1, transport.calls);
    } finally {
      ConnectorHttpClient.clearTestTransport();
    }
    }
  }

  @IsTest
  static void trackingSchedulerExecutesAndSurfacesProviderFailures() {
    System.runAs(carrierRuntimeUser()) {
      Account source = new Account(Name='Scheduler Source'); insert source;
      insert new Carrier_Shipment__c(
        Connector_Key__c='fedex', Source_Record_Id__c=String.valueOf(source.Id),
        Source_Object__c='Account', Master_Tracking_Number__c='TRACK-SCHEDULER', Shipment_Status__c='Label created'
      );
      Transport transport = new Transport();
      ConnectorHttpClient.setTestTransport(transport);
      try {
        new CarrierTrackingScheduler('fedex').execute(null);
        System.assertEquals(1, transport.calls);
        transport.statusCode = 400;
        try {
          new CarrierTrackingScheduler('fedex').execute(null);
          System.assert(false, 'A carrier failure must be surfaced by the scheduler.');
        } catch (CarrierTrackingScheduler.CarrierTrackingSchedulerException expected) {
          System.assert(String.isNotBlank(expected.getMessage()));
        }
      } finally {
        ConnectorHttpClient.clearTestTransport();
      }
    }
  }

  @IsTest
  static void trackingHandlesEmptyQueuesAndUnsupportedCarriers() {
    System.runAs(carrierRuntimeUser()) {
      CarrierOperationModels.Result empty = CarrierTrackingService.synchronizeNext('dhl');
      assertSuccess(empty);
      try {
        CarrierTrackingService.synchronizeNext('usps');
        System.assert(false, 'Unsupported tracking carriers must be rejected.');
      } catch (CarrierTrackingService.CarrierTrackingException expected) {
        System.assert(expected.getMessage().contains('Unsupported'));
      }
    }
  }

  @IsTest
  static void mutationPreparationCreatesAStableAttemptWithoutCallingTheCarrier() {
    System.runAs(carrierRuntimeUser()) {
    Account source = new Account(Name='Mutation Source'); insert source;
    Id attemptId = CarrierOperationService.prepareMutation('fedex','createShipment',source.Id,null);
    Id retryAttemptId = CarrierOperationService.prepareMutation('fedex','createShipment',source.Id,null);
    Carrier_Operation_Attempt__c attempt = [SELECT Idempotency_Key__c, Status__c, Connector_Key__c, Operation_Key__c FROM Carrier_Operation_Attempt__c WHERE Id=:attemptId];
    System.assertEquals('Prepared', attempt.Status__c);
    System.assertEquals('fedex', attempt.Connector_Key__c);
    System.assertEquals('createshipment', attempt.Operation_Key__c);
    System.assert(attempt.Idempotency_Key__c.contains(String.valueOf(attemptId)));
    System.assertEquals(attemptId, retryAttemptId, 'Retries must reuse the durable provider idempotency key.');
    }
  }

  @IsTest
  static void terminalShipmentCannotBeVoidedOrTrackedAgain() {
    System.runAs(carrierRuntimeUser()) {
    Account source = new Account(Name='Terminal Source'); insert source;
    Carrier_Shipment__c shipment = new Carrier_Shipment__c(
      Connector_Key__c='fedex', Source_Record_Id__c=String.valueOf(source.Id), Source_Object__c='Account',
      Master_Tracking_Number__c='TRACK-TERMINAL', Shipment_Status__c='Delivered', Is_Terminal__c=true
    ); insert shipment;
    Id trackingAttempt = null;
    CarrierOperationModels.Result skipped = CarrierOperationService.execute('fedex','syncTrackingStatus',source.Id,shipment.Id,trackingAttempt);
    System.assertEquals(true, skipped.success);
    Id voidAttempt = CarrierOperationService.prepareMutation('fedex','voidShipment',source.Id,shipment.Id);
    try {
      CarrierOperationService.execute('fedex','voidShipment',source.Id,shipment.Id,voidAttempt);
      System.assert(false, 'Terminal shipments must never be voided.');
    } catch (AuraHandledException expected) {
      System.assert(expected.getMessage().contains('terminal'));
    }
    }
  }

  @IsTest
  static void controllerDelegatesCarrierActionsAndRateSelection() {
    System.runAs(carrierRuntimeUser()) {
      Account source = new Account(Name='Controller Source'); insert source;
      Carrier_Shipment__c shipment = new Carrier_Shipment__c(
        Connector_Key__c='fedex', Source_Record_Id__c=String.valueOf(source.Id),
        Source_Object__c='Account', Master_Tracking_Number__c='TRACK-CONTROLLER', Shipment_Status__c='Label created'
      );
      insert shipment;
      CarrierOperationModels.ActionContext context = CarrierOperationController.getActionContext(source.Id);
      System.assertEquals(shipment.Id, context.shipments[0].id);
      CarrierOperationModels.Result address = CarrierOperationController.applyValidatedAddress('fedex', source.Id, '{}');
      assertSuccess(address);
      Carrier_Rate_Quote__c quote = new Carrier_Rate_Quote__c(
        Connector_Key__c='fedex', Source_Record_Id__c=String.valueOf(source.Id), Shipment__c=shipment.Id,
        Service_Type__c='GROUND', Service_Name__c='Ground', Total_Net_Charge__c=12.50, Currency_Code__c='USD'
      );
      insert quote;
      CarrierOperationModels.Result selection = CarrierOperationController.selectRateQuote(quote.Id, source.Id);
      assertSuccess(selection);
      Transport transport = new Transport();
      ConnectorHttpClient.setTestTransport(transport);
      try {
        Id attempt = CarrierOperationController.prepareMutation('fedex', 'recoverLabel', source.Id, shipment.Id);
        assertSuccess(CarrierOperationController.execute('fedex', 'recoverLabel', source.Id, shipment.Id, attempt));
      } finally {
        ConnectorHttpClient.clearTestTransport();
      }
      try {
        CarrierOperationController.applyValidatedAddress('fedex', source.Id, 'not-json');
        System.assert(false, 'The controller must reject malformed address confirmations.');
      } catch (AuraHandledException expected) {
        System.assertEquals('Address confirmation is invalid.', expected.getMessage());
      }
    }
  }

  @IsTest
  static void mappingControllerDiscoversFieldsAndRejectsMalformedRequests() {
    System.runAs(carrierRuntimeUser()) {
      CarrierMappingController.Workspace workspace = CarrierMappingController.getWorkspace('fedex', 'Account');
      System.assertEquals(7, workspace.operations.size());
      System.assert(workspace.objects.size() > 0);
      System.assert(workspace.fields.size() > 0);
      System.assertNotEquals(null, CarrierMappingController.getMappings('fedex', 'quoteRates', 'Account'));
      try {
        CarrierMappingController.saveMappings('not-json');
        System.assert(false, 'Malformed mapping payloads must be rejected.');
      } catch (AuraHandledException expected) {
        System.assertEquals('Carrier mapping request is invalid.', expected.getMessage());
      }
    }
  }

  @IsTest
  static void mappingControllerQueuesAValidMappingAndServiceRejectsReadOnlyResponseFields() {
    System.runAs(carrierRuntimeUser()) {
      try {
        CarrierMappingController.SaveResponse response = CarrierMappingController.saveMappings(
          '{"connectorKey":"fedex","operationKey":"validateAddress","salesforceObject":"Account","mappings":[' +
          '{"salesforceField":"Name","externalPath":"validatedAddress.city","direction":"Outbound","active":true}]}'
        );
        System.assertNotEquals(null, response.deploymentId);
      } catch (System.AsyncException expected) {
        System.assert(expected.getMessage().contains('Metadata cannot be deployed'));
      }
      Account source = new Account(Name='FLS Mapping Source'); insert source;
      CarrierOperationService.testMappings = new List<Field_Mapping__mdt>{
        new Field_Mapping__mdt(
          Integration__c='fedex', Action__c='validateaddress', SF_Object__c='Account',
          SF_Field__c='CreatedDate', External_Field__c='validatedAddress.city',
          Sync_Direction__c='Inbound', Is_Active__c=true
        )
      };
      try {
        CarrierOperationService.applyValidatedAddress(
          'fedex', source.Id, new Map<String, Object>{ 'city' => 'Austin' }
        );
        System.assert(false, 'Read-only response mappings must be rejected.');
      } catch (AuraHandledException expected) {
        System.assertEquals('A configured carrier response field is not updateable.', expected.getMessage());
      } finally {
        CarrierOperationService.testMappings = null;
      }
    }
  }

  @IsTest
  static void everyProviderUsesTheAllowlistedAdapterForEveryCarrierAction() {
    grantCarrierAccess();
    Transport transport = new Transport();
    ConnectorHttpClient.setTestTransport(transport);
    try {
      for (String connector : new List<String>{ 'fedex', 'ups', 'dhl' }) {
        for (String operation : new List<String>{ 'validateAddress', 'quoteRates', 'createShipment', 'recoverLabel', 'createReturnLabel', 'syncTrackingStatus', 'voidShipment' }) {
          CarrierOperationModels.Request request = new CarrierOperationModels.Request();
          request.connectorKey = connector; request.operationKey = operation;
          request.idempotencyKey = 'stable-test-key';
          CarrierOperationModels.Result result = CarrierOperationAdapterFactory.forConnector(connector).execute(request);
          System.assertEquals(true, result.success, connector + ' ' + operation + ' should use the allowlisted adapter.');
        }
      }
      System.assertEquals(21, transport.calls);
      System.assertEquals('stable-test-key', transport.lastRequest.getHeader('Idempotency-Key'));
    } finally {
      ConnectorHttpClient.clearTestTransport();
    }
  }

  @IsTest
  static void malformedAndErrorCarrierResponsesAreActionable() {
    grantCarrierAccess();
    Transport transport = new Transport();
    ConnectorHttpClient.setTestTransport(transport);
    try {
      CarrierOperationModels.Request request = new CarrierOperationModels.Request();
      request.connectorKey='fedex'; request.operationKey='syncTrackingStatus';
      transport.body = 'not-json';
      CarrierOperationModels.Result malformed = CarrierOperationAdapterFactory.forConnector('fedex').execute(request);
      System.assertEquals(false, malformed.success);
      System.assertEquals(false, malformed.retryable);
      transport.statusCode = 400; transport.body = '{"errors":[{"message":"Bad request"}]}';
      CarrierOperationModels.Result providerError = CarrierOperationAdapterFactory.forConnector('fedex').execute(request);
      System.assertEquals(false, providerError.success);
      System.assertEquals(400, providerError.httpStatusCode);
    } finally {
      ConnectorHttpClient.clearTestTransport();
    }
  }

  @IsTest
  static void shipmentCreationPersistsTheLabelAsASalesforceFile() {
    System.runAs(carrierRuntimeUser()) {
    Account source = new Account(Name='Label Source'); insert source;
    CarrierOperationService.testMappings = new List<Field_Mapping__mdt>{
      mapping('requestedShipment.shipper'), mapping('requestedShipment.recipient'), mapping('requestedShipment.requestedPackageLineItems')
    };
    Transport transport = new Transport();
    transport.body = '{"shipment":{"externalShipmentId":"SHIP-LABEL","masterTrackingNumber":"TRACK-LABEL"},"label":{"content":"SGVsbG8="}}';
    ConnectorHttpClient.setTestTransport(transport);
    try {
      Id attempt = CarrierOperationService.prepareMutation('fedex', 'createShipment', source.Id, null);
      CarrierOperationModels.Result result = CarrierOperationService.execute('fedex', 'createShipment', source.Id, null, attempt);
      assertSuccess(result);
      Carrier_Shipment__c shipment = [SELECT Label_Content_Document_Id__c, Master_Tracking_Number__c FROM Carrier_Shipment__c WHERE Id = :result.shipmentId];
      System.assertEquals('TRACK-LABEL', shipment.Master_Tracking_Number__c);
      System.assertNotEquals(null, shipment.Label_Content_Document_Id__c);
      System.assertEquals(1, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :shipment.Id]);
    } finally {
      CarrierOperationService.testMappings = null;
      ConnectorHttpClient.clearTestTransport();
    }
    }
  }

  private static Field_Mapping__mdt mapping(String externalPath) {
    return new Field_Mapping__mdt(
      Integration__c='fedex', Action__c='createshipment', SF_Object__c='Account',
      SF_Field__c='Name', External_Field__c=externalPath, Sync_Direction__c='Outbound', Is_Active__c=true
    );
  }

  private static void grantCarrierAccess() {
    if ([SELECT COUNT() FROM PermissionSetAssignment
        WHERE AssigneeId = :UserInfo.getUserId()
        AND PermissionSet.Name = 'Quickbridge_Carrier_User'] == 0) {
      PermissionSet carrierAccess = [
        SELECT Id FROM PermissionSet WHERE Name = 'Quickbridge_Carrier_User' LIMIT 1
      ];
      insert new PermissionSetAssignment(
        AssigneeId = UserInfo.getUserId(), PermissionSetId = carrierAccess.Id
      );
    }
  }

  private static User carrierRuntimeUser() {
    return [SELECT Id FROM User WHERE LastName = 'Carrier Runtime' LIMIT 1];
  }

  private static void assertCreateable(SObject row) {
    SObjectAccessDecision decision = Security.stripInaccessible(
      AccessType.CREATABLE, new List<SObject>{ row }
    );
    System.assert(
      decision.getRemovedFields().isEmpty(),
      'Missing create access: ' + JSON.serialize(decision.getRemovedFields())
    );
  }

  private static void assertSuccess(CarrierOperationModels.Result result) {
    System.assertEquals(
      true,
      result.success,
      String.isBlank(result.errorSummary) ? 'Expected the carrier action to succeed.' : result.errorSummary
    );
  }
}