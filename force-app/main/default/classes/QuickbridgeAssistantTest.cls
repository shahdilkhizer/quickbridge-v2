@IsTest
private class QuickbridgeAssistantTest {
  private static String request(String connector, String operation, String direction, List<Object> rows) {
    Map<String,Object> value = new Map<String,Object>{'connectorKey'=>connector,'operationKey'=>operation,'operationDirection'=>direction};
    if (rows != null) value.put('rows', rows);
    return JSON.serialize(value);
  }
  private static Map<String,Object> row(String field, String path) {
    return new Map<String,Object>{'salesforceField'=>field,'externalPath'=>path,'direction'=>'Outbound','active'=>true,'isLine'=>false,'salesforceObject'=>'Account'};
  }
  private static void permit() { QuickbridgeAdminSecurity.bypassPermissionsForTests = true; }
  @IsTest static void staticCatalogsHaveNoTransportDependencies() {
    Map<String,List<String>> entities = new Map<String,List<String>>{
      'qbo'=>new List<String>{'Customer','Vendor','Item','Invoice','CreditMemo','PurchaseOrder','TaxCode','Estimate'},
      'shopify'=>new List<String>{'Customer','Order','Product'},
      'netsuite'=>new List<String>{'Customer','inventoryItem','SalesOrder','Invoice','customerPayment','itemFulfillment'},
      'meta'=>new List<String>{'campaign','adset','ad','leadgen','campaignmemberattribution','comment','insights'}
    };
    Test.startTest();
    for (String connector : entities.keySet()) for (String entity : entities.get(connector)) {
      Map<String,QuickbridgeAssistantSchema.Field> fields = QuickbridgeAssistantSchema.fields(connector, entity, false);
      Assert.isFalse(fields.isEmpty(), connector + ':' + entity);
      for (QuickbridgeAssistantSchema.Field field : fields.values()) {
        Assert.isNotNull(field.type); Assert.isNotNull(field.required);
      }
      QuickbridgeAssistantSchema.fields(connector, entity, true);
    }
    Assert.isTrue(QuickbridgeAssistantSchema.fields('klaviyo', 'profile', false).isEmpty());
    Assert.isFalse(QuickbridgeAssistantSchema.fields('qbo','Customer',false).get('Balance').outboundAllowed);
    Assert.isTrue(QuickbridgeAssistantSchema.fields('qbo','Vendor',false).get('DisplayName').outboundAllowed);
    Assert.areEqual(0, Limits.getCallouts()); Assert.areEqual(0, Limits.getDmlStatements());
    Test.stopTest();
  }
  @IsTest static void explainsSuggestionsWithoutNativeIdOrSystemFields() {
    permit(); Test.startTest();
    QuickbridgeAssistantService.Analysis result = QuickbridgeAssistantService.review(request('shopify','ProductUpsert','Outbound',new List<Object>()));
    Assert.areEqual('ProductUpsert|Outbound', result.workspaceKey);
    Assert.isTrue(result.suggestions.size() <= 12);
    Boolean foundTitle = false;
    for (QuickbridgeAssistantService.Suggestion suggestion : result.suggestions) {
      Assert.areNotEqual('Id', suggestion.salesforceField);
      Assert.isFalse(IntegrationOutcomeService.SYSTEM_FIELDS.contains(suggestion.salesforceField.toLowerCase()));
      Assert.isNotNull(suggestion.reason);
      if (suggestion.externalPath == 'title') foundTitle = true;
    }
    Assert.isTrue(foundTitle);
    Assert.isTrue(result.fixPrompt.contains('ProductUpsert|Outbound'));
    Assert.areEqual(0, Limits.getCallouts()); Assert.areEqual(0, Limits.getDmlStatements());
    Test.stopTest();
  }
  @IsTest static void draftGapsDuplicatesTypesAndInactiveRows() {
    permit();
    List<Object> rows = new List<Object>{row('Name','DisplayName'),row('Name','CompanyName'),row('Phone','CompanyName'),row('AnnualRevenue','Active')};
    Map<String,Object> inactive = row('Name','PrimaryEmailAddr.Address'); inactive.put('active',false); rows.add(inactive);
    QuickbridgeAssistantService.Analysis result = QuickbridgeAssistantService.review(request('qbo','CustomerUpsert','Outbound',rows));
    Assert.isTrue(result.risks.size() >= 3);
    Assert.isTrue(result.healthScore == null || result.healthScore < 100);
    Assert.areNotEqual('Healthy', result.status);
    Assert.isTrue(result.requiredFieldsMapped > 0);
    for (QuickbridgeAssistantService.Suggestion suggestion : result.suggestions) Assert.areNotEqual('DisplayName',suggestion.externalPath);
  }
  @IsTest static void limitedSchemaIsNotPresentedAsHealthy() {
    permit();
    QuickbridgeAssistantService.Analysis result = QuickbridgeAssistantService.review(request('klaviyo','Profiles','Inbound',new List<Object>()));
    Assert.isTrue(result.limitedSchema); Assert.isNull(result.healthScore);
    Assert.areEqual('Limited schema',result.status);
    for (QuickbridgeAssistantService.Suggestion suggestion : result.suggestions) Assert.isTrue(suggestion.confidence < 80);
    List<Object> rows = new List<Object>{row('Name','Unverified.CustomPath')};
    result = QuickbridgeAssistantService.review(request('qbo','CustomerUpsert','Outbound',rows));
    Assert.isTrue(result.limitedSchema); Assert.isTrue(result.fixPrompt.contains('unverified'));
  }
  @IsTest static void operationDirectionsAndSavedDefaultsRemainIndependent() {
    permit();
    Integer enabledBefore = [SELECT COUNT() FROM Integration_Operation__mdt WHERE Run_On_Record_Save__c = true AND Connector_Key__c IN ('qbo','shopify','klaviyo')];
    QuickbridgeAssistantService.Analysis customer = QuickbridgeAssistantService.review(request('qbo','CustomerUpsert','Outbound',null));
    QuickbridgeAssistantService.Analysis vendor = QuickbridgeAssistantService.review(request('qbo','VendorUpsert','Inbound',null));
    Assert.areNotEqual(customer.workspaceKey,vendor.workspaceKey);
    Assert.areEqual('VendorUpsert|Inbound',vendor.workspaceKey);
    Assert.areEqual(0, Limits.getCallouts());
    Assert.areEqual(enabledBefore, [SELECT COUNT() FROM Integration_Operation__mdt WHERE Run_On_Record_Save__c = true AND Connector_Key__c IN ('qbo','shopify','klaviyo')], 'Analysis must preserve configured record-save settings.');
  }
  @IsTest static void childContextRetainedAndUnknownChildrenRejected() {
    permit();
    QuickbridgeAssistantService.Analysis result = QuickbridgeAssistantService.review(request('qbo','CustomInvoiceUpsert','Outbound',new List<Object>()));
    for (QuickbridgeAssistantService.Suggestion suggestion : result.suggestions) if (suggestion.isLine) {
      Assert.areEqual('Invoice_Line__c',suggestion.salesforceObject);
      Assert.isNotNull(suggestion.collectionPath);
    }
    Map<String,Object> child = row('Quantity__c','SalesItemLineDetail.Qty');
    child.put('salesforceObject','Invoice_Line__c'); child.put('isLine',true);
    result = QuickbridgeAssistantService.review(request('qbo','CustomInvoiceUpsert','Outbound',new List<Object>{child}));
    Assert.isNotNull(result);
    child.put('salesforceObject','Contact');
    rejected(request('qbo','CustomInvoiceUpsert','Outbound',new List<Object>{child}));
  }
  @IsTest static void invalidContextAndBoundsFailClosed() {
    permit(); rejected('{}'); rejected('not json');
    rejected(request('unknown','CustomerUpsert','Outbound',null));
    rejected(request('qbo','CustomerUpsert','MadeUp',null));
    List<Object> tooMany = new List<Object>(); for(Integer i=0;i<201;i++) tooMany.add(row('Name','DisplayName'));
    rejected(request('qbo','CustomerUpsert','Outbound',tooMany));
    rejected(request('qbo','CustomerUpsert','Outbound',new List<Object>{null}));
  }
  @IsTest static void facadeRequiresSessionAndSupportsAuthorizedDraftReview() {
    permit(); QuickbridgeAdminSecurity.bypassRateLimitForTests = true;
    String json = request('qbo','CustomerUpsert','Outbound',new List<Object>());
    try { QuickbridgeMappingFacade.reviewMappingOperation(null,json); Assert.fail('Session required'); }
    catch (QuickbridgeAdminSecurity.SessionException expected) { Assert.isNotNull(expected); }
    String token = QuickbridgeAdminSecurity.createSession('assistant@example.test').sessionToken;
    Assert.areEqual('qbo',QuickbridgeMappingFacade.reviewMappingOperation(token,json).connectorKey);
  }
  @IsTest static void bulkDraftReviewUsesBoundedQueries() {
    permit();
    List<Object> rows = new List<Object>(); for(Integer i=0;i<200;i++) rows.add(row('Name','DisplayName'));
    Test.startTest();
    QuickbridgeAssistantService.Analysis result = QuickbridgeAssistantService.review(request('qbo','CustomerUpsert','Outbound',rows));
    Assert.isTrue(Limits.getQueries() < 10); Assert.areEqual(0,Limits.getCallouts()); Assert.areEqual(0,Limits.getDmlStatements());
    Assert.isTrue(result.risks.size() < 10,'Warnings are deduplicated');
    Test.stopTest();
  }
  @IsTest static void unauthorizedReadersAndUnavailableFieldsAreSafe() {
    permit();
    QuickbridgeAssistantService.Analysis result = QuickbridgeAssistantService.review(
      request('qbo','CustomerUpsert','Outbound',new List<Object>{row('PrivateOrMissingField__c','DisplayName')}));
    Assert.isTrue(result.limitedSchema);
    Assert.isFalse(result.fixPrompt.contains('PrivateOrMissingField__c'));
    QuickbridgeAdminSecurity.bypassPermissionsForTests = false;
    User isolated = new User(Alias='noreview', Email='noreview@example.test', EmailEncodingKey='UTF-8',
      LastName='NoAssistantPermission', LanguageLocaleKey='en_US', LocaleSidKey='en_US',
      TimeZoneSidKey='America/Los_Angeles', ProfileId=UserInfo.getProfileId(),
      Username='noreview.'+System.now().getTime()+'.'+UserInfo.getOrganizationId()+'@example.test');
    insert isolated;
    System.runAs(isolated) {
      Assert.isFalse(FeatureManagement.checkPermission('View_QuickBridge'));
      rejected(request('qbo','CustomerUpsert','Outbound',null));
    }
  }
  @IsTest
  static void mappingFacadeRequiresSessionAndAuditsMutations() {
    permit(); QuickbridgeAdminSecurity.bypassRateLimitForTests = true;
    String sessionToken = QuickbridgeAdminSecurity.createSession('assistant-legacy@example.test').sessionToken;
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


  private static void rejected(String value) {
    try { QuickbridgeAssistantService.review(value); Assert.fail('Expected rejection'); }
    catch (AuraHandledException expected) { Assert.isNotNull(expected); }
  }
}