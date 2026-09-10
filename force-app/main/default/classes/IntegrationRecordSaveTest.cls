@IsTest
private class IntegrationRecordSaveTest {
  private static Integration_Operation__mdt operation(String connector, String key, String objectName, Boolean enabled) {
    return new Integration_Operation__mdt(
      Connector_Key__c = connector, Operation_Key__c = key, Salesforce_Object__c = objectName,
      External_Entity__c = 'Customer', Salesforce_External_Id_Field__c = null,
      Direction__c = 'Outbound', Active__c = true, Run_On_Record_Save__c = enabled
    );
  }
  private static void connector(String key, Boolean active) {
    insert new Connector_Instance__c(Name = key, Connector_Key__c = key,
      Connector_Label__c = key, Active__c = active, Named_Credential__c = 'Test_NC');
  }
  private static Integration_Operation_Mapping__mdt mapping(
    String connector, String key, String objectName, String field, String parent
  ) {
    return new Integration_Operation_Mapping__mdt(
      Connector_Key__c = connector, Operation_Key__c = key, Salesforce_Object__c = objectName,
      Salesforce_Field__c = field, External_Path__c = field, Direction__c = 'Outbound',
      Active__c = true, Transform__c = 'identity', Parent_Salesforce_Field__c = parent,
      Collection_Path__c = parent == null ? null : 'Line', Sort_Order__c = 1
    );
  }
  private static void configure(List<Integration_Operation__mdt> operations,
    List<Integration_Operation_Mapping__mdt> mappings) {
    IntegrationEventApi.testOperations = operations;
    GenericIntegrationRuntime.testMappingRows = mappings;
    GenericIntegrationRuntime.testOverrideRows = new List<Field_Mapping__mdt>();
    GenericIntegrationRuntime.resetMappingCache();
  }
  private static Integer workCount() { return [SELECT COUNT() FROM Integration_Work_Item__c]; }

  @IsTest static void defaultOffBlocksRecordAndChildInsertUpdateDelete() {
    connector('qbo', true);
    configure(new List<Integration_Operation__mdt>{
      operation('qbo', 'CustomerUpsert', 'Account', false),
      operation('qbo', 'CustomInvoiceUpsert', 'Invoice__c', false)
    }, new List<Integration_Operation_Mapping__mdt>{
      mapping('qbo', 'CustomerUpsert', 'Account', 'Name', null),
      mapping('qbo', 'CustomInvoiceUpsert', 'Invoice_Line__c', 'Quantity__c', 'Invoice__c')
    });
    Account account = new Account(Name = 'Off'); insert account;
    account.Name = 'Still off'; update account;
    Invoice__c invoice = new Invoice__c(); insert invoice;
    Invoice_Line__c line = new Invoice_Line__c(Invoice__c = invoice.Id, Quantity__c = 1); insert line;
    line.Quantity__c = 2; update line; delete line; delete invoice; delete account;
    System.assertEquals(0, workCount(), 'Off must cover all existing trigger paths.');
    System.assertEquals(0, Limits.getCallouts());
  }

  @IsTest static void checkedOperationsAreIndependentAndBulkSafe() {
    connector('qbo', true); connector('shopify', true);
    configure(new List<Integration_Operation__mdt>{
      operation('qbo', 'CustomerUpsert', 'Account', true),
      operation('qbo', 'VendorUpsert', 'Account', false),
      operation('shopify', 'CustomerUpsert', 'Account', false)
    }, new List<Integration_Operation_Mapping__mdt>{
      mapping('qbo', 'CustomerUpsert', 'Account', 'Name', null)
    });
    List<Account> rows = new List<Account>();
    for (Integer i = 0; i < 200; i++) rows.add(new Account(Name = 'Bulk ' + i));
    Test.startTest();
    insert rows;
    System.assertEquals(200, workCount());
    for (Account row : rows) row.Name += ' updated';
    update rows;
    System.assertEquals(200, workCount(), 'Repeated saves coalesce instead of duplicating.');
    System.assert(Limits.getQueries() < 30, 'Queries must not grow per record.');
    System.assertEquals(0, Limits.getCallouts());
    for (Integration_Work_Item__c item : [
      SELECT Integration__c, Operation__c, Coalesced_Count__c FROM Integration_Work_Item__c
    ]) {
      System.assertEquals('qbo', item.Integration__c);
      System.assertEquals('CustomerUpsert', item.Operation__c);
      System.assertEquals(1, item.Coalesced_Count__c);
    }
    Test.stopTest();
  }

  @IsTest static void effectiveOverridesAndOutcomeExclusion() {
    connector('qbo', true);
    Integration_Operation__mdt op = operation('qbo', 'CustomerUpsert', 'Account', true);
    configure(new List<Integration_Operation__mdt>{ op },
      new List<Integration_Operation_Mapping__mdt>{ mapping('qbo', 'CustomerUpsert', 'Account', 'Name', null) });
    GenericIntegrationRuntime.testOverrideRows.add(new Field_Mapping__mdt(
      Integration__c = 'QuickBooks', Action__c = 'Customer', SF_Object__c = 'Account',
      SF_Field__c = 'Description', External_Field__c = 'Notes', Sync_Direction__c = 'Both', Is_Active__c = true));
    Account source = new Account(Name = 'Override'); insert source;
    Id workId = [SELECT Id FROM Integration_Work_Item__c LIMIT 1].Id;
    source.Phone = '123'; update source;
    System.assertEquals(0, [SELECT Coalesced_Count__c FROM Integration_Work_Item__c WHERE Id = :workId].Coalesced_Count__c);
    source.Description = 'Mapped through override'; update source;
    System.assertEquals(1, [SELECT Coalesced_Count__c FROM Integration_Work_Item__c WHERE Id = :workId].Coalesced_Count__c);
    IntegrationOutcomeService.markFailure(new Set<Id>{source.Id}, 'qbo', 'CustomerUpsert');
    System.assertEquals(1, [SELECT Coalesced_Count__c FROM Integration_Work_Item__c WHERE Id = :workId].Coalesced_Count__c);
    List<GenericIntegrationRuntime.MappingRule> rules = GenericIntegrationRuntime.recordSaveMappings(op, true);
    System.assertEquals(2, rules.size(), 'Overrides must preserve unrelated defaults.');
  }

  @IsTest static void parentFlagControlsLineChangesAndOverrides() {
    connector('qbo', true);
    Integration_Operation__mdt op = operation('qbo', 'CustomInvoiceUpsert', 'Invoice__c', true);
    configure(new List<Integration_Operation__mdt>{op},
      new List<Integration_Operation_Mapping__mdt>{
        mapping('qbo', 'CustomInvoiceUpsert', 'Invoice_Line__c', 'Quantity__c', 'Invoice__c')
      });
    GenericIntegrationRuntime.testOverrideRows.add(new Field_Mapping__mdt(
      Integration__c = 'qbo', Action__c = 'CustomInvoiceUpsert', SF_Object__c = 'Invoice_Line__c',
      SF_Field__c = 'Quantity__c', External_Field__c = 'Qty', Sync_Direction__c = 'Outbound', Is_Active__c = true));
    Invoice__c invoice = new Invoice__c(); insert invoice;
    Invoice_Line__c line = new Invoice_Line__c(Invoice__c = invoice.Id, Quantity__c = 1); insert line;
    Id workId = [SELECT Id FROM Integration_Work_Item__c LIMIT 1].Id;
    Decimal beforeCount = [SELECT Coalesced_Count__c FROM Integration_Work_Item__c WHERE Id = :workId].Coalesced_Count__c;
    line.Quantity__c = 2; update line;
    delete line;
    System.assertEquals(beforeCount + 2, [SELECT Coalesced_Count__c FROM Integration_Work_Item__c WHERE Id = :workId].Coalesced_Count__c);
    op.Run_On_Record_Save__c = false;
    Invoice_Line__c second = new Invoice_Line__c(Invoice__c = invoice.Id, Quantity__c = 1); insert second;
    second.Quantity__c = 3; update second; delete second;
    System.assertEquals(beforeCount + 2, [SELECT Coalesced_Count__c FROM Integration_Work_Item__c WHERE Id = :workId].Coalesced_Count__c);
  }

  @IsTest static void inactiveInboundAndOtherConnectors() {
    connector('qbo', false); connector('klaviyo', true); connector('netsuite', true);
    Integration_Operation__mdt inbound = operation('klaviyo', 'Profiles', 'Account', true);
    inbound.Direction__c = 'Inbound';
    configure(new List<Integration_Operation__mdt>{
      operation('qbo', 'CustomerUpsert', 'Account', true), inbound,
      operation('netsuite', 'CustomerUpsert', 'Account', false)
    }, new List<Integration_Operation_Mapping__mdt>{
      mapping('netsuite', 'CustomerUpsert', 'Account', 'Name', null)
    });
    Account row = new Account(Name = 'Eligibility'); insert row;
    System.assertEquals(0, workCount(), 'Every connector must explicitly opt in.');
    System.assertEquals(false, IntegrationEventApi.supportsRecordSave('klaviyo', 'Inbound'));
    System.assertEquals(true, IntegrationEventApi.supportsRecordSave('shopify', 'Both'));
    System.assertEquals(true, IntegrationEventApi.supportsRecordSave('netsuite', 'Outbound'));
  }

  @IsTest static void turningOffDoesNotCancelQueuedOrManualWork() {
    connector('shopify', true);
    Integration_Operation__mdt op = operation('shopify', 'CustomerUpsert', 'Account', true);
    configure(new List<Integration_Operation__mdt>{op},
      new List<Integration_Operation_Mapping__mdt>{mapping('shopify', 'CustomerUpsert', 'Account', 'Name', null)});
    Account row = new Account(Name = 'Queued'); insert row;
    Id workId = [SELECT Id FROM Integration_Work_Item__c LIMIT 1].Id;
    op.Run_On_Record_Save__c = false;
    row.Name = 'Off now'; update row;
    System.assertEquals('Pending', [SELECT Status__c FROM Integration_Work_Item__c WHERE Id = :workId].Status__c);
    ConnectorExecutionRequest request = new ConnectorExecutionRequest();
    request.connectorKey = 'shopify'; request.operationKey = 'CustomerUpsert'; request.recordIds.add(row.Id);
    IntegrationWorkService.complete(workId, request, ConnectorExecutionResult.success());
    System.assertEquals('Completed', [SELECT Status__c FROM Integration_Work_Item__c WHERE Id = :workId].Status__c);
    IntegrationWorkRequest manual = new IntegrationWorkRequest();
    manual.connectorKey = 'shopify'; manual.operationKey = 'CustomerUpsert';
    manual.sourceObject = 'Account'; manual.sourceRecordId = row.Id;
    IntegrationWorkService.enqueue(new List<IntegrationWorkRequest>{manual});
    System.assertEquals('Pending', [SELECT Status__c FROM Integration_Work_Item__c WHERE Id = :workId].Status__c);
  }

  @IsTest static void controllerSettingOnlyCombinedAndLegacySaves() {
    QuickbridgeMappingController.bypassSecurityForTests = true;
    QuickbridgeAdminSecurity.bypassPermissionsForTests = true;
    Map<String,Object> request = saveRequest();
    request.put('runOnRecordSave', true);
    QuickbridgeMappingController.SaveResponse result = QuickbridgeMappingController.saveMappings(JSON.serialize(request));
    System.assertEquals(1, result.submittedCount);
    List<Metadata.Metadata> submitted = QuickbridgeMappingController.lastSaveContainer.getMetadata();
    Metadata.CustomMetadata setting = (Metadata.CustomMetadata) submitted[0];
    System.assertEquals('Integration_Operation__mdt.QBO_Customer_Outbound', setting.fullName);
    System.assertEquals(1, setting.values.size(), 'Only the flag must be written.');
    System.assertEquals('Run_On_Record_Save__c', setting.values[0].field);
    System.assertEquals(true, setting.values[0].value);
    request.put('rows', new List<Object>{new Map<String,Object>{
      'salesforceField'=>'Name', 'externalPath'=>'DisplayName', 'direction'=>'Outbound', 'active'=>true}});
    result = QuickbridgeMappingController.saveMappings(JSON.serialize(request));
    System.assertEquals(2, result.submittedCount);
    request.remove('runOnRecordSave');
    System.assertEquals(1, QuickbridgeMappingController.saveMappings(JSON.serialize(request)).submittedCount);
    request.put('runOnRecordSave', null);
    System.assertEquals(1, QuickbridgeMappingController.saveMappings(JSON.serialize(request)).submittedCount);
    request.remove('rows'); request.put('runOnRecordSave', false);
    QuickbridgeMappingController.saveMappings(JSON.serialize(request));
    setting = (Metadata.CustomMetadata) QuickbridgeMappingController.lastSaveContainer.getMetadata()[0];
    System.assertEquals(false, setting.values[0].value);
  }

  @IsTest static void unsupportedAndUnauthorizedSettingWrites() {
    QuickbridgeMappingController.bypassSecurityForTests = true;
    QuickbridgeAdminSecurity.bypassPermissionsForTests = true;
    Map<String,Object> request = saveRequest(); request.put('runOnRecordSave', true);
    request.remove('operationDirection'); assertRejected(request);
    request.put('operationDirection', 'Inbound'); assertRejected(request);
    request.put('connectorKey', 'klaviyo'); request.put('operationKey', 'Profiles');
    request.put('externalObject', 'profile'); assertRejected(request);
    request.put('connectorKey', 'netsuite'); request.put('operationKey', 'CustomerUpsert');
    request.put('operationDirection', 'Outbound'); request.put('externalObject', 'customer');
    QuickbridgeMappingController.saveMappings(JSON.serialize(request));
    System.assertNotEquals(null,QuickbridgeMappingController.lastSaveContainer,'Configured outbound connectors can opt in.');
    QuickbridgeAdminSecurity.bypassPermissionsForTests = false;
    User isolatedUser = new User(Alias='nosync', Email='nosync@example.test', EmailEncodingKey='UTF-8',
      LastName='NoSyncPermission', LanguageLocaleKey='en_US', LocaleSidKey='en_US',
      TimeZoneSidKey='America/Los_Angeles', ProfileId=UserInfo.getProfileId(),
      Username='nosync.'+System.now().getTime()+'.'+UserInfo.getOrganizationId()+'@example.test');
    insert isolatedUser;
    System.runAs(isolatedUser) {
      System.assertEquals(false, FeatureManagement.checkPermission('Manage_QuickBridge'));
      request = saveRequest(); request.put('runOnRecordSave', true); assertRejected(request);
    }
  }

  @IsTest static void workspaceAndDeploymentFailure() {
    QuickbridgeMappingController.bypassSecurityForTests = true;
    for (String key : new List<String>{'qbo','shopify','klaviyo'}) {
      QuickbridgeMappingController.MappingWorkspace workspace = QuickbridgeMappingController.getMappingWorkspace(key);
      for (QuickbridgeMappingController.OperationWorkspace operation : workspace.operations) {
        System.assertEquals(IntegrationEventApi.supportsRecordSave(key, operation.direction), operation.supportsRunOnRecordSave);
        if (!operation.supportsRunOnRecordSave) System.assertEquals(false, operation.runOnRecordSave);
      }
    }
    Metadata.DeployResult failure = new Metadata.DeployResult();
    failure.status = Metadata.DeployStatus.Failed;
    new QuickbridgeMappingController.MappingDeployCallback().handleResult(failure, null);
    System.assertEquals(1, [SELECT COUNT() FROM Error_Log__c WHERE Class_Method_Name__c = 'QuickbridgeMappingController.MappingDeployCallback']);
    String deploymentId = String.valueOf((Id) '0Af000000000001');
    QuickbridgeAdminSecurity.audit('MAPPING_DEPLOYMENT', null, 'Succeeded', null, (Id) deploymentId);
    System.assertEquals(1, [SELECT COUNT() FROM Quickbridge_Admin_Audit__c
      WHERE Related_Record_Id__c = :deploymentId AND Status__c = 'Succeeded']);
    System.assertEquals('Succeeded', QuickbridgeMappingController.getDeploymentStatus(deploymentId).status,
      'Deployment outcomes remain readable without Platform Cache.');
  }
  private static Map<String,Object> saveRequest() {
    return new Map<String,Object>{'connectorKey'=>'qbo','operationKey'=>'CustomerUpsert',
      'operationDirection'=>'Outbound','salesforceObject'=>'Account','externalObject'=>'Customer'};
  }
  private static void assertRejected(Map<String,Object> request) {
    try { QuickbridgeMappingController.saveMappings(JSON.serialize(request)); System.assert(false, 'Must reject this setting write.'); }
    catch (AuraHandledException expected) { System.assertNotEquals(null, expected); }
  }
}