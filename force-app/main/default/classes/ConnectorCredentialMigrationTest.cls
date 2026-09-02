@IsTest
private class ConnectorCredentialMigrationTest {
  @IsTest
  static void readinessRequiresConfigurationHealthAndExplicitActivation() {
    Connector_Instance__c connector = qboInstance(false, 'Unknown');
    insert connector;

    ConnectorReadinessService.Assessment missingConfig =
      ConnectorReadinessService.assess('qbo', false);
    System.assertEquals(false, missingConfig.configurationReady);

    insert requiredQboConfig(connector.Id);
    ConnectorReadinessService.Assessment probeReady =
      ConnectorReadinessService.assess('qbo', false);
    System.assertEquals(
      true,
      probeReady.configurationReady,
      String.join(probeReady.issues, ' ')
    );
    System.assertEquals(false, probeReady.operationalReady);

    connector.Health_Status__c = 'Ready';
    update connector;
    System.assertEquals(
      true,
      ConnectorReadinessService.assess('qbo', false).operationalReady
    );
    System.assertEquals(
      false,
      ConnectorReadinessService.assess('qbo', true).operationalReady
    );
  }

  @IsTest
  static void successfulProbeDoesNotBypassActivationGate() {
    QuickbridgeConfigController.bypassSecurityForTests = true;
    Connector_Instance__c connector = qboInstance(false, 'Unknown');
    insert connector;
    insert requiredQboConfig(connector.Id);
    ConnectorHttpClient.setTestTransport(
      new ProbeTransport(200, '{"CompanyInfo":{"CompanyName":"Quickbridge"}}')
    );

    ConnectorHealthProbeResult result =
      QuickbridgeConfigController.runHealthProbe('qbo');
    Connector_Instance__c afterProbe = [
      SELECT Active__c, Health_Status__c, Last_Health_Check_At__c
      FROM Connector_Instance__c WHERE Id = :connector.Id
    ];
    System.assertEquals(true, result.successful);
    System.assertEquals(false, afterProbe.Active__c);
    System.assertEquals('Ready', afterProbe.Health_Status__c);
    System.assertNotEquals(null, afterProbe.Last_Health_Check_At__c);

    QuickbridgeConfigController.setConnectorPaused('qbo', false);
    ConnectorHttpClient.clearTestTransport();
    System.assertEquals(
      true,
      [SELECT Active__c FROM Connector_Instance__c WHERE Id = :connector.Id].Active__c
    );
  }

  @IsTest
  static void authenticationFailureDeactivatesAndCreatesSanitizedLog() {
    Connector_Instance__c connector = qboInstance(true, 'Ready');
    insert connector;
    insert requiredQboConfig(connector.Id);
    ConnectorHttpClient.setTestTransport(
      new ProbeTransport(401, '{"error":"authorization: Bearer example-secret"}')
    );

    ConnectorHealthProbeResult result = ConnectorHealthService.probe('qbo');
    ConnectorHttpClient.clearTestTransport();

    System.assertEquals(false, result.successful);
    System.assertEquals(401, result.httpStatusCode);
    Connector_Instance__c refreshed = [
      SELECT Active__c, Health_Status__c
      FROM Connector_Instance__c WHERE Id = :connector.Id
    ];
    System.assertEquals(false, refreshed.Active__c);
    System.assertEquals('Authentication Required', refreshed.Health_Status__c);
    Error_Log__c logRow = [
      SELECT Error_Category__c, Error_Message__c, Http_Status_Code__c,
        Source_Object__c, Source_Record_Id__c, Raw_Payload__c
      FROM Error_Log__c WHERE Source_Record_Id__c = :String.valueOf(connector.Id)
      LIMIT 1
    ];
    System.assertEquals('Authentication', logRow.Error_Category__c);
    System.assertEquals(401, logRow.Http_Status_Code__c);
    System.assertEquals('Connector_Instance__c', logRow.Source_Object__c);
    System.assertEquals(null, logRow.Raw_Payload__c);
    System.assert(!logRow.Error_Message__c.contains('example-secret'));
  }

  @IsTest
  static void shopIdentityMismatchIsRejected() {
    Connector_Instance__c connector = new Connector_Instance__c(
      Name = 'Shopify Probe',
      Connector_Key__c = 'shopify',
      Connector_Label__c = 'Shopify',
      Active__c = false,
      Environment__c = 'Sandbox',
      Health_Status__c = 'Unknown',
      Named_Credential__c = 'Shopify_NC',
      External_Credential__c = 'Shopify_EC'
    );
    insert connector;
    insert new List<Connector_Config_Value__c>{
      configValue(connector.Id, 'shopify', 'companyName', 'Quickbridge'),
      configValue(connector.Id, 'shopify', 'storeDomain', 'expected.myshopify.com'),
      configValue(connector.Id, 'shopify', 'startDate', '2026-06-10')
    };
    ConnectorHttpClient.setTestTransport(
      new ProbeTransport(
        200,
        '{"shop":{"name":"Quickbridge","myshopify_domain":"other.myshopify.com"}}'
      )
    );

    ConnectorHealthProbeResult result = ConnectorHealthService.probe('shopify');
    ConnectorHttpClient.clearTestTransport();

    System.assertEquals(false, result.successful);
    System.assert(result.message.contains('did not match'));
    System.assertEquals(
      false,
      [SELECT Active__c FROM Connector_Instance__c WHERE Id = :connector.Id].Active__c
    );
  }

  @IsTest
  static void legacyProbeContractRemainsNonActivating() {
    Connector_Instance__c connector = qboInstance(false, 'Unknown');
    insert connector;
    insert requiredQboConfig(connector.Id);
    ConnectorHttpClient.setTestTransport(
      new ProbeTransport(200, '{"CompanyInfo":{"CompanyName":"Quickbridge"}}')
    );
    ConnectorCredentialProbe.ProbeResult result =
      ConnectorCredentialProbe.probe('qbo');
    ConnectorHttpClient.clearTestTransport();

    System.assertEquals(true, result.successful);
    System.assertEquals(
      false,
      [SELECT Active__c FROM Connector_Instance__c WHERE Id = :connector.Id].Active__c
    );
  }

  private static Connector_Instance__c qboInstance(Boolean active, String health) {
    return new Connector_Instance__c(
      Name = 'QBO Probe',
      Connector_Key__c = 'qbo',
      Connector_Label__c = 'QuickBooks Online',
      Active__c = active,
      Environment__c = 'Sandbox',
      Health_Status__c = health,
      Named_Credential__c = 'QuickBooks_NC',
      External_Credential__c = 'QuickBooks_EC'
    );
  }

  private static List<Connector_Config_Value__c> requiredQboConfig(Id connectorId) {
    return new List<Connector_Config_Value__c>{
      configValue(connectorId, 'qbo', 'companyName', 'Quickbridge'),
      configValue(connectorId, 'qbo', 'realmId', '123456789'),
      configValue(connectorId, 'qbo', 'startDate', '2026-06-10')
    };
  }

  private static Connector_Config_Value__c configValue(
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

  private class ProbeTransport implements ConnectorHttpClient.Transport {
    private Integer statusCode;
    private String responseBody;

    ProbeTransport(Integer statusCodeValue, String responseBodyValue) {
      statusCode = statusCodeValue;
      responseBody = responseBodyValue;
    }

    public HttpResponse send(HttpRequest request) {
      System.assert(request.getEndpoint().startsWith('callout:'));
      System.assertEquals('GET', request.getMethod());
      HttpResponse response = new HttpResponse();
      response.setStatusCode(statusCode);
      response.setStatus(statusCode >= 200 && statusCode < 300 ? 'OK' : 'Unauthorized');
      response.setBody(responseBody);
      return response;
    }
  }
}