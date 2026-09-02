@IsTest
private class QuickbridgeControlPanelTest {
  private class ControlPlaneMock implements HttpCalloutMock {
    private Integer statusCode;
    private String responseBody;
    ControlPlaneMock(Integer code, String body) { statusCode = code; responseBody = body; }
    public HttpResponse respond(HttpRequest request) {
      System.assertEquals('POST', request.getMethod());
      System.assert(request.getEndpoint().startsWith('callout:Quickbridge_Server_NC/'));
      HttpResponse response = new HttpResponse(); response.setStatusCode(statusCode); response.setBody(responseBody); return response;
    }
  }

  @TestSetup
  static void setupData() {
    insert new Connector_Instance__c(
      Name = 'QBO', Connector_Key__c = 'qbo', Connector_Label__c = 'QuickBooks Online', Environment__c = 'Sandbox',
      Named_Credential__c = 'QuickBooks_NC', External_Credential__c = 'QuickBooks_EC', Active__c = false,
      Entitlement_Status__c = 'Available', Health_Status__c = 'Unknown'
    );
  }

  private static String createAdminSession() {
    QuickbridgeAdminSecurity.bypassPermissionsForTests = true;
    QuickbridgeAdminSecurity.bypassRateLimitForTests = true;
    return QuickbridgeAdminSecurity.createSession('admin@example.com').sessionToken;
  }

  @IsTest
  static void authenticationCreatesOnlyHashedSession() {
    QuickbridgeAdminSecurity.bypassPermissionsForTests = true;
    QuickbridgeAdminSecurity.bypassRateLimitForTests = true;
    Test.setMock(HttpCalloutMock.class, new ControlPlaneMock(200, '{"status":"Success","message":"Welcome"}'));
    Test.startTest();
    QuickbridgeControlPanelController.AuthenticationResponse response = QuickbridgeControlPanelController.authenticateAdmin('admin@example.com', '1234');
    Test.stopTest();
    System.assertEquals(true, response.successful);
    System.assertNotEquals(null, response.sessionToken);
    Quickbridge_Admin_Session__c session = [SELECT Token_Hash__c, Username__c, Status__c FROM Quickbridge_Admin_Session__c LIMIT 1];
    System.assertEquals('admin@example.com', session.Username__c);
    System.assertEquals('Active', session.Status__c);
    System.assertNotEquals(response.sessionToken, session.Token_Hash__c);
    System.assertEquals(64, session.Token_Hash__c.length());
    System.assertEquals(true, QuickbridgeControlPanelController.revokeAdminSession(response.sessionToken));
    System.assertEquals('Revoked', [SELECT Status__c FROM Quickbridge_Admin_Session__c WHERE Id = :session.Id].Status__c);
  }

  @IsTest
  static void invalidPinDoesNotCallControlPlane() {
    QuickbridgeAdminSecurity.bypassPermissionsForTests = true;
    QuickbridgeAdminSecurity.bypassRateLimitForTests = true;
    QuickbridgeControlPanelController.AuthenticationResponse response = QuickbridgeControlPanelController.authenticateAdmin('admin@example.com', '12');
    System.assertEquals(false, response.successful);
    System.assertEquals(0, [SELECT COUNT() FROM Quickbridge_Admin_Session__c]);
  }

  @IsTest
  static void bootstrapSeparatesEntitlementFromOperationalState() {
    QuickbridgeAdminSecurity.bypassPermissionsForTests = true;
    QuickbridgeAdminSecurity.bypassRateLimitForTests = true;
    QuickbridgeAdminSecurity.SessionResult session = QuickbridgeAdminSecurity.createSession('admin@example.com');
    Connector_Instance__c qbo = [SELECT Id, Entitlement_Status__c, Active__c, Expiry_Date__c FROM Connector_Instance__c WHERE Connector_Key__c = 'qbo' LIMIT 1];
    qbo.Entitlement_Status__c = 'Active'; qbo.Active__c = false; qbo.Expiry_Date__c = Date.today().addDays(20); update qbo;
    Test.startTest(); QuickbridgeControlPanelController.PanelBootstrap bootstrap = QuickbridgeControlPanelController.getPanelBootstrap(session.sessionToken); Test.stopTest();
    QuickbridgeControlPanelController.ConnectorView qboView;
    for (QuickbridgeControlPanelController.ConnectorView item : bootstrap.connectors) if (item.key == 'qbo') qboView = item;
    System.assertNotEquals(null, qboView);
    System.assertEquals(true, qboView.subscribed);
    System.assertEquals(false, qboView.active);
    System.assertEquals(20, qboView.expiryDate == null ? null : Date.today().daysBetween(qboView.expiryDate));
  }

  @IsTest
  static void terminalErrorCannotBeReplayed() {
    QuickbridgeAdminSecurity.bypassPermissionsForTests = true;
    QuickbridgeAdminSecurity.bypassRateLimitForTests = true;
    QuickbridgeAdminSecurity.SessionResult session = QuickbridgeAdminSecurity.createSession('admin@example.com');
    Error_Log__c errorRow = new Error_Log__c(
      Error_Category__c = 'Validation', Error_Message__c = 'Provider rejected the record.', Is_Retryable__c = false,
      Retry_Status__c = 'Failed', Retry_Count__c = 1, Source_Object__c = 'Account', Source_Record_Id__c = '001000000000001AAA',
      External_Reference__c = 'qbo:customer:001000000000001AAA'
    ); insert errorRow;
    try {
      QuickbridgeErrorController.replayError(session.sessionToken, errorRow.Id);
      System.assert(false, 'Expected a terminal replay rejection.');
    } catch (AuraHandledException expected) {
      System.assert(expected.getMessage().contains('terminal'));
    }
    System.assertEquals(1, [SELECT Retry_Count__c FROM Error_Log__c WHERE Id = :errorRow.Id].Retry_Count__c);
  }

  @IsTest
  static void sessionSecurityRateLimitsExpiresAndAudits() {
    QuickbridgeAdminSecurity.bypassPermissionsForTests = true;
    QuickbridgeAdminSecurity.bypassRateLimitForTests = false;
    for (Integer attempt = 0; attempt < 5; attempt++) {
      QuickbridgeAdminSecurity.checkRateLimit('RATE-LIMIT@example.com', QuickbridgeAdminSecurity.LOGIN_BUCKET);
    }
    try {
      QuickbridgeAdminSecurity.checkRateLimit('rate-limit@example.com', QuickbridgeAdminSecurity.LOGIN_BUCKET);
      System.assert(false, 'Expected the sixth attempt to be rejected.');
    } catch (AuraHandledException expected) {
      System.assert(expected.getMessage().contains('Too many attempts'));
    }
    Quickbridge_Admin_Rate_Limit__c bucket = [
      SELECT Id, Bucket_Hash__c, Attempt_Count__c FROM Quickbridge_Admin_Rate_Limit__c LIMIT 1
    ];
    System.assertEquals(64, bucket.Bucket_Hash__c.length());
    System.assertEquals(false, bucket.Bucket_Hash__c.contains('rate-limit'));
    QuickbridgeAdminSecurity.clearRateLimit('rate-limit@example.com', QuickbridgeAdminSecurity.LOGIN_BUCKET);
    System.assertEquals(0, [SELECT COUNT() FROM Quickbridge_Admin_Rate_Limit__c]);

    QuickbridgeAdminSecurity.bypassRateLimitForTests = true;
    String token = QuickbridgeAdminSecurity.createSession('expired@example.com').sessionToken;
    Quickbridge_Admin_Session__c session = [SELECT Id, Expires_At__c FROM Quickbridge_Admin_Session__c WHERE Username__c = 'expired@example.com'];
    session.Expires_At__c = System.now().addMinutes(-1);
    update session;
    try {
      QuickbridgeAdminSecurity.requireSession(token);
      System.assert(false, 'Expected the expired session to be rejected.');
    } catch (QuickbridgeAdminSecurity.SessionException expected) {
      System.assert(expected.getMessage().contains('expired'));
    }
    System.assertEquals('Expired', [SELECT Status__c FROM Quickbridge_Admin_Session__c WHERE Id = :session.Id].Status__c);
    System.assertEquals(false, QuickbridgeAdminSecurity.revokeSession('missing-token'));
    QuickbridgeAdminSecurity.audit('TEST_ACTION', 'qbo', 'Success', 'safe details', session.Id);
    Quickbridge_Admin_Audit__c audit = [SELECT Action__c, Connector_Key__c, Status__c, Details__c FROM Quickbridge_Admin_Audit__c WHERE Action__c = 'TEST_ACTION' LIMIT 1];
    System.assertEquals('qbo', audit.Connector_Key__c);
    System.assertEquals('safe details', audit.Details__c);
  }

  @IsTest
  static void controlPlaneRecoveryLicenseRefreshAndPreferences() {
    String sessionToken = createAdminSession();
    Test.setMock(HttpCalloutMock.class, new ControlPlaneMock(200,
      '{"status":"Success","message":"Updated","licenses":[{"name":"qbo","endDate":"2026-12-31"},{"name":"unsupported","endDate":"2026-12-31"}]}'
    ));
    Test.startTest();
    QuickbridgeControlPanelController.ActionResponse recovered = QuickbridgeControlPanelController.recoverPin('admin@example.com');
    QuickbridgeControlPanelController.ActionResponse refreshed = QuickbridgeControlPanelController.refreshLicenses(sessionToken);
    QuickbridgeControlPanelController.ActionResponse visibility = QuickbridgeControlPanelController.updateAvailableProductsVisible(sessionToken, false);
    Test.stopTest();
    System.assertEquals(true, recovered.successful);
    System.assertEquals(true, refreshed.successful);
    System.assertEquals(true, visibility.successful);
    Connector_Instance__c instance = [SELECT Entitlement_Status__c, Expiry_Date__c, Last_Entitlement_Refresh_At__c FROM Connector_Instance__c WHERE Connector_Key__c = 'qbo'];
    System.assertEquals('Active', instance.Entitlement_Status__c);
    System.assertEquals(Date.newInstance(2026, 12, 31), instance.Expiry_Date__c);
    System.assertNotEquals(null, instance.Last_Entitlement_Refresh_At__c);
    System.assertEquals('false', [SELECT Value__c FROM Connector_Config_Value__c WHERE Connector_Key__c = 'quickbridge_panel' AND Field_Key__c = 'availableProductsVisible'].Value__c);
  }

  @IsTest
  static void renewalExpiryAndConfigurationResetAreSafe() {
    String sessionToken = createAdminSession();
    insert new List<Connector_Config_Value__c>{
      new Connector_Config_Value__c(Name='Renewal recipient', Connector_Key__c='quickbridge_panel', Field_Key__c='renewalRecipient', Value__c='admin@example.com', Is_Secret_Reference__c=false),
      new Connector_Config_Value__c(Name='Company', Connector_Key__c='qbo', Field_Key__c='companyName', Value__c='Sandbox Company', Is_Secret_Reference__c=false),
      new Connector_Config_Value__c(Name='Secret reference', Connector_Key__c='qbo', Field_Key__c='webhookSecret', Value__c='Connector_Secret__c', Is_Secret_Reference__c=true)
    };
    Connector_Instance__c instance = [SELECT Id, Active__c, Expiry_Date__c FROM Connector_Instance__c WHERE Connector_Key__c = 'qbo'];
    instance.Active__c = true;
    instance.Expiry_Date__c = Date.today().addDays(7);
    update instance;
    Scheduled_Integration_Job__c job = new Scheduled_Integration_Job__c(
      Logical_Job_Key__c='reset-job', Integration_Type__c='QuickBooks', Source_Object__c='Account', Direction__c='Inbound',
      Frequency_Value__c=5, Frequency_Type__c='Minutes', Scheduler_Name__c='Reset me', Status__c='Ready', Created_DateTime__c=System.now()
    );
    insert job;

    QuickbridgeControlPanelController.ActionResponse renewal = QuickbridgeControlPanelController.sendRenewalRequest(sessionToken, new List<String>{'qbo'}, new List<String>{'shopify'});
    System.assertEquals(true, renewal.successful);
    QuickbridgeControlPanelController.ExpiryAlert firstAlert = QuickbridgeControlPanelController.checkIntegrationExpiry(sessionToken, 'qbo');
    QuickbridgeControlPanelController.ExpiryAlert secondAlert = QuickbridgeControlPanelController.checkIntegrationExpiry(sessionToken, 'qbo');
    System.assertEquals(true, firstAlert.shouldAlert);
    System.assertEquals(true, secondAlert.shouldAlert);
    System.assertEquals(1, [SELECT COUNT() FROM Connector_Config_Value__c WHERE Connector_Key__c='quickbridge_panel' AND Field_Key__c LIKE 'expiryAlert:qbo:%']);

    QuickbridgeControlPanelController.ActionResponse resetResult = QuickbridgeControlPanelController.resetConnectorConfiguration(sessionToken, 'qbo');
    System.assertEquals(true, resetResult.successful);
    System.assertEquals(0, [SELECT COUNT() FROM Connector_Config_Value__c WHERE Connector_Key__c='qbo' AND Is_Secret_Reference__c=false]);
    System.assertEquals(1, [SELECT COUNT() FROM Connector_Config_Value__c WHERE Connector_Key__c='qbo' AND Is_Secret_Reference__c=true]);
    System.assertEquals(false, [SELECT Active__c FROM Connector_Instance__c WHERE Id=:instance.Id].Active__c);
    System.assertEquals('Paused', [SELECT Status__c FROM Scheduled_Integration_Job__c WHERE Id=:job.Id].Status__c);
  }

  @IsTest
  static void schedulerSupportsCreateUpdateStateRunsAndDelete() {
    String sessionToken = createAdminSession();
    QuickbridgeScheduleController.Workspace workspace = QuickbridgeScheduleController.getScheduleWorkspace(sessionToken, 'qbo');
    System.assertEquals('qbo', workspace.connectorKey);
    System.assert(workspace.objects.size() > 0);
    String sourceObject = workspace.objects[0].value;
    String direction = workspace.directions[0].value;
    Map<String, Object> request = new Map<String, Object>{
      'connectorKey' => 'qbo', 'sourceObject' => sourceObject, 'direction' => direction,
      'frequencyValue' => 15, 'frequencyType' => 'Minutes', 'schedulerName' => 'QBO test schedule'
    };
    QuickbridgeScheduleController.ScheduleView created = QuickbridgeScheduleController.saveSchedule(sessionToken, JSON.serialize(request));
    System.assertNotEquals(null, created.id);
    request.put('scheduleId', created.id);
    request.put('frequencyValue', 2);
    request.put('frequencyType', 'Hours');
    QuickbridgeScheduleController.ScheduleView updated = QuickbridgeScheduleController.saveSchedule(sessionToken, JSON.serialize(request));
    System.assertEquals(2, updated.frequencyValue);
    System.assertEquals(1, QuickbridgeScheduleController.getSchedules(sessionToken, 'qbo').size());

    insert new List<Integration_Work_Item__c>{
      new Integration_Work_Item__c(Unique_Key__c='run-completed', Integration__c='qbo', Operation__c='test', Status__c='Completed', Source_Object__c=sourceObject, Last_Attempt_At__c=System.now()),
      new Integration_Work_Item__c(Unique_Key__c='run-failed', Integration__c='qbo', Operation__c='test', Status__c='Failed', Source_Object__c=sourceObject, Last_Attempt_At__c=System.now(), Last_Error__c='safe failure')
    };
    List<QuickbridgeScheduleController.RecentRun> runs = QuickbridgeScheduleController.getRecentRuns(sessionToken, created.id);
    System.assertEquals(2, runs.size());
    QuickbridgeScheduleController.setScheduleState(sessionToken, created.id, 'Paused');
    System.assertEquals('Paused', [SELECT Status__c FROM Scheduled_Integration_Job__c WHERE Id=:created.id].Status__c);
    QuickbridgeScheduleController.setScheduleState(sessionToken, created.id, 'Ready');
    QuickbridgeScheduleController.deleteSchedule(sessionToken, created.id);
    System.assertEquals('Deleted', [SELECT Status__c FROM Scheduled_Integration_Job__c WHERE Id=:created.id].Status__c);
  }

  @IsTest
  static void reportingUsageAndErrorAdministrationAreDeterministic() {
    String sessionToken = createAdminSession();
    Connector_Instance__c instance = [SELECT Id, Entitlement_Status__c, Expiry_Date__c FROM Connector_Instance__c WHERE Connector_Key__c='qbo'];
    instance.Entitlement_Status__c='Subscribed';
    instance.Expiry_Date__c=Date.today().addDays(45);
    update instance;
    insert new List<Integration_Work_Item__c>{
      new Integration_Work_Item__c(Unique_Key__c='report-completed', Integration__c='qbo', Operation__c='test', Status__c='Completed', Source_Object__c='Account'),
      new Integration_Work_Item__c(Unique_Key__c='report-failed', Integration__c='qbo', Operation__c='test', Status__c='Failed', Source_Object__c='Account')
    };
    QuickbridgeUsageService.record('synced-1', 'QBO', 'Synced', 3);
    QuickbridgeUsageService.record('synced-1', 'QBO', 'Synced', 3);
    QuickbridgeUsageService.record('error-1', 'qbo', 'Error', 2);
    QuickbridgeUsageService.record('endpoint-1', 'qbo', 'Endpoint', 9);
    QuickbridgeUsageService.record(null, 'qbo', 'Endpoint', 1);
    Test.startTest();
    QuickbridgeUsageService.aggregatePending();
    Test.stopTest();
    System.assertEquals(3, [SELECT COUNT() FROM Integration_Usage_Event__c]);
    Integration_Usage_Summary__c summary = [SELECT Synced_Records__c, Error_Count__c, Endpoint_Usage__c FROM Integration_Usage_Summary__c WHERE Product_Key__c='qbo'];
    System.assertEquals(3, summary.Synced_Records__c);
    System.assertEquals(2, summary.Error_Count__c);
    System.assertEquals(9, summary.Endpoint_Usage__c);
    QuickbridgeReportingController.Report report = QuickbridgeReportingController.getReport(sessionToken, 'qbo');
    System.assertEquals(1, report.products.size());
    System.assertEquals(1, report.products[0].syncedRecords);
    System.assertEquals(1, report.products[0].errors);
    System.assertEquals(9, report.products[0].endpointUsage);
    System.assertEquals(true, report.products[0].subscribed);

    insert new List<Error_Log__c>{
      new Error_Log__c(Error_Category__c='Timeout', Error_Message__c='retry me', Is_Retryable__c=true, Retry_Status__c='Retrying', Retry_Count__c=2, Http_Status_Code__c=429, Source_Object__c='Account', Source_Record_Id__c='001000000000001AAA', External_Reference__c='qbo:customer:1'),
      new Error_Log__c(Error_Category__c='Validation', Error_Message__c='terminal', Is_Retryable__c=false, Retry_Status__c='Failed', Retry_Count__c=0, Source_Object__c='Account', External_Reference__c='qbo:customer:2'),
      new Error_Log__c(Error_Category__c='Recovered', Error_Message__c='done', Is_Retryable__c=true, Retry_Status__c='Success', Retry_Count__c=1, Source_Object__c='Account', External_Reference__c='qbo:customer:3')
    };
    QuickbridgeErrorController.ErrorPage allRows = QuickbridgeErrorController.getErrors(sessionToken, 'qbo', 1, 2, 'All');
    QuickbridgeErrorController.ErrorPage retries = QuickbridgeErrorController.getErrors(sessionToken, 'qbo', 1, 10, 'Retry');
    QuickbridgeErrorController.ErrorPage pending = QuickbridgeErrorController.getErrors(sessionToken, 'qbo', 1, 10, 'Pending');
    System.assertEquals(3, allRows.totalCount);
    System.assertEquals(2, allRows.rows.size());
    System.assertEquals(2, retries.totalCount);
    System.assertEquals(1, pending.totalCount);
    System.assertEquals(false, pending.rows[0].retryable);
    System.assertNotEquals(null, pending.rows[0].retryDisabledReason);
  }

  @IsTest
  static void mappingFacadeRequiresSessionAndAuditsMutations() {
    String sessionToken = createAdminSession();
    QuickbridgeMappingController.bypassSecurityForTests = true;
    QuickbridgeMappingController.MappingWorkspace workspace = QuickbridgeMappingFacade.getMappingWorkspace(sessionToken, 'qbo');
    System.assertEquals('qbo', workspace.connectorKey);
    System.assert(workspace.operations.size() > 0);

    QuickbridgeMappingFacade.MappingAnalysis analysis = QuickbridgeMappingFacade.analyzeMappings(
      sessionToken, JSON.serialize(new Map<String, Object>{'connectorKey'=>'qbo'})
    );
    System.assert(analysis.totalMappings > 0);
    System.assert(analysis.healthScore >= 0);

    Map<String, Object> request = new Map<String, Object>{
      'connectorKey'=>'qbo', 'operationKey'=>'CustomerUpsert', 'operationDirection'=>'Outbound',
      'salesforceObject'=>'Account', 'externalObject'=>'Customer',
      'rows'=>new List<Object>{new Map<String, Object>{
        'salesforceField'=>'Name', 'externalPath'=>'DisplayName', 'direction'=>'Outbound', 'active'=>true
      }}
    };
    QuickbridgeMappingController.SaveResponse saved = QuickbridgeMappingFacade.applyMappingSuggestions(sessionToken, JSON.serialize(request));
    System.assertEquals('Succeeded', saved.status);
    QuickbridgeMappingController.SaveResponse cleared = QuickbridgeMappingFacade.clearMappings(
      sessionToken, 'qbo', 'CustomerUpsert', 'Account', 'Customer', 'Outbound'
    );
    System.assertNotEquals(null, cleared.status);
    System.assertEquals('Succeeded', QuickbridgeMappingFacade.getDeploymentStatus(sessionToken, null).status);
    System.assert([SELECT COUNT() FROM Quickbridge_Admin_Audit__c WHERE Action__c IN ('MAPPING_SAVE','MAPPING_RESET')] >= 2);
  }
}