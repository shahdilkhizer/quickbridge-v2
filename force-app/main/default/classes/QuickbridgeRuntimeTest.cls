@IsTest
private class QuickbridgeRuntimeTest {
  @TestSetup
  static void setupData() {
    insert new List<Account>{
      new Account(Name = 'Quickbridge Outcome One'),
      new Account(Name = 'Quickbridge Outcome Two')
    };
  }

  @IsTest
  static void outcomeTransitionsFollowTheContract() {
    Account source = [SELECT Id FROM Account WHERE Name = 'Quickbridge Outcome One' LIMIT 1];
    IntegrationOutcomeService.markPending(new Set<Id>{ source.Id }, 'qbo', 'CustomerUpsert');
    Account pending = outcome(source.Id);
    System.assertEquals(false, pending.Integration_Success__c);
    System.assertEquals(false, pending.Integration_Error__c);
    System.assertEquals('qbo', pending.Last_Integration__c);
    System.assertEquals('CustomerUpsert', pending.Last_Integration_Operation__c);
    System.assertNotEquals(null, pending.Last_Integration_Attempt_At__c);

    IntegrationOutcomeService.markFailure(new Set<Id>{ source.Id }, 'qbo', 'CustomerUpsert');
    Account failed = outcome(source.Id);
    System.assertEquals(false, failed.Integration_Success__c);
    System.assertEquals(true, failed.Integration_Error__c);

    IntegrationOutcomeService.markSuccess(new Set<Id>{ source.Id }, 'qbo', 'CustomerUpsert');
    Account recovered = outcome(source.Id);
    System.assertEquals(true, recovered.Integration_Success__c);
    System.assertEquals(false, recovered.Integration_Error__c);
    System.assertNotEquals(null, recovered.Last_Integration_Success_At__c);
  }

  @IsTest
  static void errorChainUsesOneLogAndBothLinkTypes() {
    Account source = [SELECT Id FROM Account WHERE Name = 'Quickbridge Outcome One' LIMIT 1];
    IntegrationErrorLogService.Failure first = failure(source.Id, 1, true);
    first.message = 'HTTP 429 authorization: Bearer very-secret token=abc';
    first.httpStatusCode = 429;
    IntegrationErrorLogService.logFailures(new List<IntegrationErrorLogService.Failure>{ first });
    IntegrationErrorLogService.Failure second = failure(source.Id, 2, true);
    second.message = 'HTTP 503 temporarily unavailable';
    second.httpStatusCode = 503;
    IntegrationErrorLogService.logFailures(new List<IntegrationErrorLogService.Failure>{ second });

    List<Error_Log__c> logs = [
      SELECT Account__c, Error_Category__c, Error_Message__c,
        Http_Status_Code__c, Is_Retryable__c, Retry_Count__c,
        Retry_Status__c, Source_Object__c, Source_Record_Id__c,
        External_Reference__c, Raw_Payload__c, Retry_History_Notes__c
      FROM Error_Log__c
      WHERE Source_Record_Id__c = :String.valueOf(source.Id)
    ];
    System.assertEquals(1, logs.size(), 'A retry chain must update one error log.');
    System.assertEquals(source.Id, logs[0].Account__c);
    System.assertEquals(503, logs[0].Http_Status_Code__c);
    System.assertEquals(2, logs[0].Retry_Count__c);
    System.assertEquals('Retrying', logs[0].Retry_Status__c);
    System.assertEquals(null, logs[0].Raw_Payload__c);
    System.assert(!logs[0].Error_Message__c.contains('very-secret'));
    System.assert(logs[0].Retry_History_Notes__c.contains('attempt 1'));
    System.assert(logs[0].Retry_History_Notes__c.contains('attempt 2'));

    Error_Log_Link__c link = [
      SELECT Linked_Object_API_Name__c, Linked_Record_Id__c, Relationship_Role__c
      FROM Error_Log_Link__c WHERE Error_Log__c = :logs[0].Id LIMIT 1
    ];
    System.assertEquals('Account', link.Linked_Object_API_Name__c);
    System.assertEquals(String.valueOf(source.Id), link.Linked_Record_Id__c);
    System.assertEquals('Source', link.Relationship_Role__c);

    IntegrationErrorLogService.markResolved(null, new Set<Id>{ source.Id });
    System.assertEquals('Success', [SELECT Retry_Status__c FROM Error_Log__c WHERE Id = :logs[0].Id].Retry_Status__c);
  }

  @IsTest
  static void workRetriesOnlyFailedIdsAndPreservesSuccess() {
    List<Account> sources = [SELECT Id FROM Account ORDER BY Name LIMIT 2];
    IntegrationWorkRequest workRequest = new IntegrationWorkRequest();
    workRequest.connectorKey = 'qbo';
    workRequest.operationKey = 'CustomerUpsert';
    workRequest.sourceObject = 'Account';
    workRequest.sourceRecordId = sources[0].Id;
    workRequest.maximumAttempts = 5;
    Id workItemId = IntegrationWorkService.enqueue(new List<IntegrationWorkRequest>{ workRequest })[0];

    Integration_Work_Item__c item = [SELECT Status__c FROM Integration_Work_Item__c WHERE Id = :workItemId];
    System.assertEquals('Pending', item.Status__c);
    ConnectorExecutionRequest request = new ConnectorExecutionRequest();
    request.connectorKey = 'qbo';
    request.operationKey = 'CustomerUpsert';
    request.direction = 'Outbound';
    request.salesforceObject = 'Account';
    request.externalEntity = 'Customer';
    request.recordIds = new List<Id>{ sources[0].Id, sources[1].Id };

    ConnectorExecutionResult partial = ConnectorExecutionResult.failed('HTTP 503 busy', true, 60);
    partial.httpStatusCode = 503;
    partial.errorCategory = 'SERVER_ERROR';
    partial.retryRecordIds.add(sources[0].Id);
    IntegrationWorkService.complete(workItemId, request, partial);
    System.assertEquals('Retry', [SELECT Status__c FROM Integration_Work_Item__c WHERE Id = :workItemId].Status__c);
    Map<Id, Account> afterPartial = new Map<Id, Account>([
      SELECT Integration_Success__c, Integration_Error__c FROM Account WHERE Id IN :request.recordIds
    ]);
    System.assertEquals(true, afterPartial.get(sources[1].Id).Integration_Success__c);
    System.assertEquals(true, afterPartial.get(sources[0].Id).Integration_Error__c);

    request.recordIds = new List<Id>{ sources[0].Id };
    IntegrationWorkService.complete(workItemId, request, ConnectorExecutionResult.success());
    Account recovered = outcome(sources[0].Id);
    System.assertEquals(true, recovered.Integration_Success__c);
    System.assertEquals(false, recovered.Integration_Error__c);
    System.assertEquals('Success', [SELECT Retry_Status__c FROM Error_Log__c WHERE Source_Record_Id__c = :String.valueOf(sources[0].Id) LIMIT 1].Retry_Status__c);
  }

  @IsTest
  static void outcomeUpdatesDoNotRetriggerIntegration() {
    // Opt in explicitly; deployed operations default to record-save sync disabled.
    IntegrationEventApi.testOperations = [
      SELECT Connector_Key__c, Operation_Key__c, Salesforce_Object__c, Direction__c,
        External_Entity__c, Salesforce_External_Id_Field__c, Active__c, Run_On_Record_Save__c
      FROM Integration_Operation__mdt WHERE Active__c = true
    ];
    for (Integration_Operation__mdt operation : IntegrationEventApi.testOperations) {
      operation.Run_On_Record_Save__c = true;
    }
    insert new Connector_Instance__c(
      Name = 'QBO Test Instance', Connector_Key__c = 'qbo',
      Connector_Label__c = 'QBO', Active__c = true,
      Named_Credential__c = 'QuickBooks_NC'
    );
    Account source = new Account(Name = 'Watched Field Guard');
    insert source;
    List<Integration_Work_Item__c> beforeRows = [
      SELECT Id, Coalesced_Count__c FROM Integration_Work_Item__c
      WHERE Source_Salesforce_Id__c = :String.valueOf(source.Id)
    ];
    System.assert(beforeRows.size() > 0, 'The active connector should create outbound work.');
    Map<Id, Decimal> counts = new Map<Id, Decimal>();
    for (Integration_Work_Item__c row : beforeRows) counts.put(row.Id, row.Coalesced_Count__c);

    IntegrationOutcomeService.markFailure(new Set<Id>{ source.Id }, 'qbo', 'CustomerUpsert');
    for (Integration_Work_Item__c row : [
      SELECT Id, Coalesced_Count__c FROM Integration_Work_Item__c WHERE Id IN :counts.keySet()
    ]) {
      System.assertEquals(counts.get(row.Id), row.Coalesced_Count__c,
        'Outcome-only DML must not coalesce or create integration work.');
    }
  }

  @IsTest
  static void bulkOutcomesHandleTwoHundredRecords() {
    List<Account> records = new List<Account>();
    for (Integer indexValue = 0; indexValue < 200; indexValue++) {
      records.add(new Account(Name = 'Bulk Outcome ' + indexValue));
    }
    insert records;
    Set<Id> ids = new Map<Id, Account>(records).keySet();
    Test.startTest();
    IntegrationOutcomeService.markSuccess(ids, 'shopify', 'CustomerUpsert');
    Test.stopTest();
    System.assertEquals(200, [
      SELECT COUNT() FROM Account WHERE Id IN :ids
        AND Integration_Success__c = true AND Integration_Error__c = false
    ]);
  }

  @IsTest
  static void simultaneousSchedulesShareCapacityAndExpiredLeaseRecovers() {
    insert new Connector_Instance__c(Name='Shopify scheduling',Connector_Key__c='shopify',Active__c=true);
    Scheduled_Integration_Job__c qbo = dueSchedule('QBO Simultaneous', 'QuickBooks', 'CustomerUpsert');
    Scheduled_Integration_Job__c shopify = dueSchedule('Shopify Simultaneous', 'Shopify', 'ProductUpsert');
    insert new List<Scheduled_Integration_Job__c>{ qbo, shopify };

    Test.startTest();
    Integer claimed = IntegrationScheduleDispatcher.dispatchDue(2);
    System.assertEquals(2, claimed);
    List<Scheduled_Integration_Job__c> claimedRows = [
      SELECT Status__c, Lease_Token__c, Lease_Expires_At__c, Processor_Job_Id__c
      FROM Scheduled_Integration_Job__c WHERE Id IN :new Set<Id>{ qbo.Id, shopify.Id }
    ];
    for (Scheduled_Integration_Job__c row : claimedRows) {
      System.assertEquals('Claimed', row.Status__c);
      System.assertNotEquals(null, row.Lease_Token__c);
      System.assert(row.Lease_Expires_At__c > System.now());
      System.assertNotEquals(null, row.Processor_Job_Id__c);
    }
    System.assertEquals(0, IntegrationScheduleDispatcher.dispatchDue(2), 'Duplicate heartbeat must not double-claim.');
    Test.stopTest();

    Scheduled_Integration_Job__c expired = dueSchedule('Expired Claim', 'QuickBooks', 'CustomerUpsert');
    expired.Status__c = 'Claimed';
    expired.Lease_Token__c = 'expired-token';
    expired.Lease_Expires_At__c = System.now().addMinutes(-1);
    insert expired;
    System.assertEquals(1, IntegrationScheduleDispatcher.dispatchDue(1));
    Scheduled_Integration_Job__c reclaimed = [
      SELECT Lease_Token__c, Lease_Expires_At__c FROM Scheduled_Integration_Job__c WHERE Id = :expired.Id
    ];
    System.assertNotEquals('expired-token', reclaimed.Lease_Token__c);
    System.assert(reclaimed.Lease_Expires_At__c > System.now());
  }

  @IsTest
  static void constrainedCapacityLeavesSecondScheduleDue() {
    insert new Connector_Instance__c(Name='Shopify scheduling',Connector_Key__c='shopify',Active__c=true);
    insert new List<Scheduled_Integration_Job__c>{
      dueSchedule('Capacity Older', 'QuickBooks', 'CustomerUpsert'),
      dueSchedule('Capacity Newer', 'Shopify', 'ProductUpsert')
    };
    System.assertEquals(1, IntegrationScheduleDispatcher.dispatchDue(1));
    Integer readyCount = [
      SELECT COUNT() FROM Scheduled_Integration_Job__c
      WHERE Logical_Job_Key__c LIKE 'Capacity %' AND Status__c = 'Ready'
    ];
    System.assertEquals(1, readyCount);
  }

  @IsTest
  static void everySupportedTriggerHandlesInsertUpdateAndDelete() {
    Account accountValue = new Account(Name = 'Trigger Smoke Account');
    insert accountValue;
    Product2 productValue = new Product2(Name = 'Trigger Smoke Product', IsActive = true);
    insert productValue;
    Id standardPricebookId = Test.getStandardPricebookId();
    PricebookEntry entry = new PricebookEntry(
      Pricebook2Id = standardPricebookId, Product2Id = productValue.Id,
      UnitPrice = 10, IsActive = true
    );
    insert entry;

    Order orderValue = new Order(
      AccountId = accountValue.Id, EffectiveDate = Date.today(),
      Status = 'Draft', Pricebook2Id = standardPricebookId
    );
    insert orderValue;
    OrderItem orderLine = new OrderItem(
      OrderId = orderValue.Id, PricebookEntryId = entry.Id,
      Quantity = 1, UnitPrice = 10
    );
    insert orderLine;

    Opportunity opportunityValue = new Opportunity(
      Name = 'Trigger Smoke Opportunity', AccountId = accountValue.Id,
      StageName = 'Prospecting', CloseDate = Date.today().addDays(30),
      Pricebook2Id = standardPricebookId
    );
    insert opportunityValue;
    Quote quoteValue = new Quote(
      Name = 'Trigger Smoke Quote',
      OpportunityId = opportunityValue.Id,
      ExpirationDate = Date.today().addDays(15),
      Pricebook2Id = standardPricebookId
    );
    insert quoteValue;
    QuoteLineItem quoteLine = new QuoteLineItem(
      QuoteId = quoteValue.Id, PricebookEntryId = entry.Id,
      Quantity = 1, UnitPrice = 10
    );
    insert quoteLine;

    Invoice__c invoiceValue = new Invoice__c();
    Purchase_Order__c purchaseOrderValue = new Purchase_Order__c();
    Credit_Memo__c creditMemoValue = new Credit_Memo__c();
    Item_Sales_Tax__c taxValue = new Item_Sales_Tax__c();
    insert invoiceValue;
    insert purchaseOrderValue;
    insert creditMemoValue;
    insert taxValue;
    Invoice_Line__c invoiceLine = new Invoice_Line__c(Invoice__c = invoiceValue.Id);
    Purchase_Order_Line__c purchaseLine = new Purchase_Order_Line__c(Purchase_Order__c = purchaseOrderValue.Id);
    Credit_Memo_Line__c creditLine = new Credit_Memo_Line__c(Credit_Memo__c = creditMemoValue.Id);
    insert invoiceLine;
    insert purchaseLine;
    insert creditLine;

    accountValue.Name = 'Trigger Smoke Account Updated';
    productValue.Description = 'Updated';
    orderValue.Description = 'Updated';
    orderLine.Description = 'Updated';
    quoteValue.Description = 'Updated';
    quoteLine.Description = 'Updated';
    invoiceValue.Status__c = 'Open';
    purchaseOrderValue.Email__c = 'trigger@example.test';
    creditMemoValue.Ref_Number__c = 'CM-TEST';
    taxValue.Item_Description__c = 'Updated';
    update accountValue;
    update productValue;
    update orderValue;
    update orderLine;
    update quoteValue;
    update quoteLine;
    update invoiceValue;
    update purchaseOrderValue;
    update creditMemoValue;
    update taxValue;

    delete invoiceLine;
    delete purchaseLine;
    delete creditLine;
    delete quoteLine;
    delete orderLine;
    delete quoteValue;
    delete orderValue;
    delete invoiceValue;
    delete purchaseOrderValue;
    delete creditMemoValue;
    delete taxValue;
    delete productValue;
  }

  @IsTest
  static void configurationDashboardAndConnectorServicesAreGeneric() {
    QuickbridgeConfigController.bypassSecurityForTests = true;
    Connector_Instance__c qbo = new Connector_Instance__c(
      Name = 'QBO Dashboard', Connector_Key__c = 'qbo',
      Connector_Label__c = 'QuickBooks Online', Active__c = true,
      Named_Credential__c = 'QuickBooks_NC',
      External_Credential__c = 'QuickBooks_EC', Health_Status__c = 'Ready'
    );
    Connector_Instance__c shopify = new Connector_Instance__c(
      Name = 'Shopify Dashboard', Connector_Key__c = 'shopify',
      Connector_Label__c = 'Shopify', Active__c = false,
      Named_Credential__c = 'Shopify_NC',
      External_Credential__c = 'Shopify_EC', Health_Status__c = 'Unknown'
    );
    insert new List<Connector_Instance__c>{ qbo, shopify };
    insert new Connector_Config_Value__c(
      Name = 'QBO Realm', Connector_Instance__c = qbo.Id,
      Connector_Key__c = 'qbo', Field_Key__c = 'realmId', Value__c = '123456789'
    );
    insert new List<Scheduled_Integration_Job__c>{
      dueSchedule('Dashboard QBO', 'QuickBooks', 'CustomerUpsert'),
      dueSchedule('Dashboard Shopify', 'Shopify', 'ProductUpsert')
    };
    Account source = [SELECT Id FROM Account WHERE Name = 'Quickbridge Outcome One' LIMIT 1];
    IntegrationErrorLogService.logFailures(new List<IntegrationErrorLogService.Failure>{ failure(source.Id, 5, false) });

    QuickbridgeConfigController.Dashboard dashboard = QuickbridgeConfigController.getDashboard();
    Integer enabledConnectorCount = [
      SELECT Id FROM Integration_Connector__mdt WHERE Enabled__c = true
    ].size();
    System.assertEquals(enabledConnectorCount, dashboard.connectors.size());
    System.assertEquals(true, dashboard.canAdminister);
    System.assertEquals(1, dashboard.recentErrors.size());
    System.assertEquals(true, ConnectorConfigService.isActive(' QBO '));
    System.assertEquals('QuickBooks_NC', ConnectorConfigService.namedCredentialFor('qbo'));
    System.assertEquals('123456789', ConnectorConfigService.getConfigValue('qbo', 'realmId'));
    QuickbridgeConfigController.ConnectorConfiguration configuration =
      QuickbridgeConfigController.getConnectorConfiguration('qbo');
    System.assertEquals('QuickBooks_NC', configuration.namedCredential);
    System.assert(configuration.fields.size() >= 3, 'QBO canonical fields should be returned.');
    QuickbridgeConfigController.saveConnectorConfiguration(
      'qbo',
      JSON.serialize(new Map<String, Object>{
        'companyName' => 'Quickbridge Test',
        'realmId' => '987654321',
        'mapDraftOrdersAsEstimates' => true,
        'startDate' => '2026-01-01',
        'endDate' => '',
        'defaultTaxAgencyId' => '7'
      })
    );
    System.assertEquals(
      '987654321',
      ConnectorConfigService.getConfigValue('qbo', 'realmId')
    );
    System.assertEquals(
      6,
      [SELECT COUNT() FROM Connector_Config_Value__c WHERE Connector_Key__c = 'qbo']
    );
    ConnectorConfigService.updateHealth('qbo', 'Warning');
    System.assertEquals('Warning', [SELECT Health_Status__c FROM Connector_Instance__c WHERE Id = :qbo.Id].Health_Status__c);

    QuickbridgeConfigController.setConnectorPaused('qbo', true);
    System.assertEquals(false, [SELECT Active__c FROM Connector_Instance__c WHERE Id = :qbo.Id].Active__c);
    ConnectorHttpClient.setTestTransport(new ReadyHealthTransport());
    QuickbridgeConfigController.setConnectorPaused('qbo', false);
    ConnectorHttpClient.clearTestTransport();
    System.assertEquals(true, [SELECT Active__c FROM Connector_Instance__c WHERE Id = :qbo.Id].Active__c);
    try {
      QuickbridgeConfigController.setConnectorPaused('unsupported', true);
      System.assert(false, 'Unsupported connector must be rejected.');
    } catch (AuraHandledException expected) {
      System.assert(String.isNotBlank(expected.getMessage()));
    }
    shopify.Named_Credential__c = null;
    update shopify;
    try {
      QuickbridgeConfigController.setConnectorPaused('shopify', false);
      System.assert(false, 'A connector without a Named Credential must remain inactive.');
    } catch (AuraHandledException expected) {
      System.assert(String.isNotBlank(expected.getMessage()));
    }
  }

  @IsTest
  static void workDispatcherClaimsOnceAndCreatesLeaseLock() {
    Account source = [SELECT Id FROM Account WHERE Name = 'Quickbridge Outcome One' LIMIT 1];
    IntegrationWorkRequest request = new IntegrationWorkRequest();
    request.connectorKey = 'qbo';
    request.operationKey = 'CustomerUpsert';
    request.sourceObject = 'Account';
    request.sourceRecordId = source.Id;
    request.maximumAttempts = 5;
    Id workItemId = IntegrationWorkService.enqueue(new List<IntegrationWorkRequest>{ request })[0];
    Test.startTest();
    System.assertEquals(1, IntegrationWorkDispatcher.dispatchDueWork(1));
    System.assertEquals(0, IntegrationWorkDispatcher.dispatchDueWork(1));
    Integration_Work_Item__c claimed = [
      SELECT Status__c, Processor_Token__c, Processor_Job_Id__c,
        Lease_Expires_At__c, Attempt_Count__c
      FROM Integration_Work_Item__c WHERE Id = :workItemId
    ];
    System.assertEquals('Processing', claimed.Status__c);
    System.assertNotEquals(null, claimed.Processor_Token__c);
    System.assertNotEquals(null, claimed.Processor_Job_Id__c);
    System.assertEquals(1, claimed.Attempt_Count__c);
    Integration_Work_Lock__c lockRow = [
      SELECT Status__c, Work_Item__c, Lease_Expires_At__c
      FROM Integration_Work_Lock__c WHERE Work_Item__c = :workItemId LIMIT 1
    ];
    System.assertEquals('Locked', lockRow.Status__c);
    Test.stopTest();
  }

  private static Account outcome(Id accountId) {
    return [
      SELECT Integration_Success__c, Integration_Error__c,
        Last_Integration__c, Last_Integration_Operation__c,
        Last_Integration_Attempt_At__c, Last_Integration_Success_At__c
      FROM Account WHERE Id = :accountId
    ];
  }

  private static IntegrationErrorLogService.Failure failure(Id recordId, Integer attempt, Boolean retryable) {
    IntegrationErrorLogService.Failure value = new IntegrationErrorLogService.Failure();
    value.recordId = recordId;
    value.connectorKey = 'qbo';
    value.operationKey = 'CustomerUpsert';
    value.category = 'HTTP';
    value.message = 'Failure';
    value.retryable = retryable;
    value.retryCount = attempt;
    value.maximumAttempts = 5;
    value.classMethod = 'QuickbridgeRuntimeTest.failure';
    return value;
  }

  private static Scheduled_Integration_Job__c dueSchedule(String keyValue, String connector, String operation) {
    return new Scheduled_Integration_Job__c(
      Logical_Job_Key__c = keyValue,
      Scheduler_Name__c = keyValue,
      Integration_Type__c = connector,
      Source_Object__c = operation,
      Direction__c = 'Inbound',
      Frequency_Value__c = 5,
      Frequency_Type__c = 'Minutes',
      Status__c = 'Ready',
      Next_Run_At__c = System.now().addMinutes(-1),
      Created_DateTime__c = System.now()
    );
  }

  private class ReadyHealthTransport implements ConnectorHttpClient.Transport {
    public HttpResponse send(HttpRequest request) {
      HttpResponse response = new HttpResponse();
      response.setStatusCode(200);
      response.setStatus('OK');
      response.setBody('{"CompanyInfo":{"CompanyName":"Quickbridge Test"}}');
      return response;
    }
  }
}