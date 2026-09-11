@IsTest
private class QuickbridgeOperationalReportingTest {
  @TestSetup
  static void setupData() {
    insert new Connector_Instance__c(
      Name = 'QBO',
      Connector_Key__c = 'qbo',
      Connector_Label__c = 'QuickBooks Online',
      Environment__c = 'Sandbox',
      Named_Credential__c = 'QuickBooks_NC',
      External_Credential__c = 'QuickBooks_EC',
      Active__c = true,
      Health_Status__c = 'Ready'
    );
  }

  private static String createAdminSession() {
    QuickbridgeAdminSecurity.bypassPermissionsForTests = true;
    QuickbridgeAdminSecurity.bypassRateLimitForTests = true;
    return QuickbridgeAdminSecurity.createSession('admin@example.com').sessionToken;
  }

  @IsTest
  static void legacyReportingApiRemainsAvailable() {
    String sessionToken = createAdminSession();
    Connector_Instance__c instance = [
      SELECT Id, Entitlement_Status__c, Expiry_Date__c
      FROM Connector_Instance__c
      WHERE Connector_Key__c = 'qbo'
      LIMIT 1
    ];
    instance.Entitlement_Status__c = 'Subscribed';
    instance.Expiry_Date__c = Date.today().addDays(45);
    update instance;
    insert new List<Integration_Work_Item__c>{
      new Integration_Work_Item__c(
        Unique_Key__c = 'legacy-report-completed', Integration__c = 'qbo',
        Operation__c = 'test', Status__c = 'Completed', Source_Object__c = 'Account'
      ),
      new Integration_Work_Item__c(
        Unique_Key__c = 'legacy-report-failed', Integration__c = 'qbo',
        Operation__c = 'test', Status__c = 'Failed', Source_Object__c = 'Account'
      )
    };
    QuickbridgeUsageService.record('legacy-synced', 'qbo', 'Synced', 3);
    QuickbridgeUsageService.record('legacy-error', 'qbo', 'Error', 2);
    QuickbridgeUsageService.record('legacy-endpoint', 'qbo', 'Endpoint', 9);

    Test.startTest();
    QuickbridgeUsageService.aggregatePending();
    Test.stopTest();

    QuickbridgeReportingController.Report report =
      QuickbridgeReportingController.getReport(sessionToken, 'qbo');
    System.assertEquals(1, report.products.size());
    System.assertEquals(1, report.products[0].syncedRecords);
    System.assertEquals(1, report.products[0].errors);
    System.assertEquals(9, report.products[0].endpointUsage);
    System.assertEquals(true, report.products[0].subscribed);
  }

  @IsTest
  static void operationalReportingUsesCurrentWorkAndLogicalSchedules() {
    String sessionToken = createAdminSession();
    QuickbridgeReportingController.bypassReadAccessForTests = true;
    Datetime completedAt = System.now().addMinutes(-3);
    insert new List<Integration_Work_Item__c>{
      new Integration_Work_Item__c(
        Unique_Key__c = 'operational-completed', Integration__c = 'qbo',
        Operation__c = 'test', Status__c = 'Completed', Source_Object__c = 'Account',
        Completed_At__c = completedAt
      ),
      new Integration_Work_Item__c(
        Unique_Key__c = 'operational-pending', Integration__c = 'qbo',
        Operation__c = 'test', Status__c = 'Pending', Source_Object__c = 'Account'
      ),
      new Integration_Work_Item__c(
        Unique_Key__c = 'operational-processing', Integration__c = 'qbo',
        Operation__c = 'test', Status__c = 'Processing', Source_Object__c = 'Account'
      ),
      new Integration_Work_Item__c(
        Unique_Key__c = 'operational-retry', Integration__c = 'qbo',
        Operation__c = 'test', Status__c = 'Retry', Source_Object__c = 'Account'
      ),
      new Integration_Work_Item__c(
        Unique_Key__c = 'operational-failed', Integration__c = 'qbo',
        Operation__c = 'test', Status__c = 'Failed', Source_Object__c = 'Account'
      )
    };
    insert new List<Scheduled_Integration_Job__c>{
      new Scheduled_Integration_Job__c(
        Logical_Job_Key__c = 'operational-overdue', Integration_Type__c = 'QuickBooks',
        Source_Object__c = 'Account', Direction__c = 'Inbound', Frequency_Value__c = 5,
        Frequency_Type__c = 'Minutes', Scheduler_Name__c = 'Operational overdue',
        Status__c = 'Ready', Created_DateTime__c = System.now(),
        Next_Run_At__c = System.now().addMinutes(-6)
      ),
      new Scheduled_Integration_Job__c(
        Logical_Job_Key__c = 'operational-paused', Integration_Type__c = 'QuickBooks',
        Source_Object__c = 'Contact', Direction__c = 'Outbound', Frequency_Value__c = 5,
        Frequency_Type__c = 'Minutes', Scheduler_Name__c = 'Operational paused',
        Status__c = 'Paused', Created_DateTime__c = System.now(),
        Next_Run_At__c = System.now().addMinutes(-20)
      )
    };

    Test.startTest();
    QuickbridgeReportingController.OperationalOverview allConnectors =
      QuickbridgeReportingController.getOperationalOverview(sessionToken, null);
    QuickbridgeReportingController.OperationalOverview qboOnly =
      QuickbridgeReportingController.getOperationalOverview(sessionToken, 'qbo');
    Test.stopTest();

    System.assertEquals(1, allConnectors.activeConnectorCount);
    System.assertEquals(1, allConnectors.completedWorkCount);
    System.assertEquals(3, allConnectors.backlogCount);
    System.assertEquals(1, allConnectors.failedWorkCount);
    System.assertEquals(1, allConnectors.overdueScheduleCount);
    System.assertNotEquals(null, allConnectors.lastSuccessfulWorkAt);
    System.assertEquals(
      allConnectors.activeConnectorCount,
      allConnectors.readyConnectorCount + allConnectors.attentionConnectorCount
    );
    System.assertEquals(1, qboOnly.connectors.size());
    System.assertEquals('qbo', qboOnly.connectors[0].connectorKey);
    System.assertEquals(1, qboOnly.connectors[0].completedWorkCount);
    System.assertEquals(1, qboOnly.connectors[0].failedWorkCount);
    System.assertEquals(1, qboOnly.connectors[0].overdueScheduleCount);
    System.assertEquals('Overdue', qboOnly.connectors[0].scheduleState);
    System.assertEquals(0, [SELECT COUNT() FROM Integration_Usage_Event__c]);

    try {
      QuickbridgeReportingController.getOperationalOverview(sessionToken, 'unsupported');
      System.assert(false, 'Unsupported connector keys must be rejected.');
    } catch (AuraHandledException expectedError) {
      System.assertEquals('Unsupported connector.', expectedError.getMessage());
    }
  }
}