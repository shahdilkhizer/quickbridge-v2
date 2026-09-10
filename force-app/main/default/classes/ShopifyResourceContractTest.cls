@IsTest
private class ShopifyResourceContractTest {
  private static String lastOrderResponse;
  @TestSetup static void setup() {
    Connector_Instance__c connector = new Connector_Instance__c(Name='Shopify contract', Connector_Key__c='shopify',
      Connector_Label__c='Shopify', Active__c=false, Named_Credential__c='Shopify_NC', External_Credential__c='Shopify_EC');
    insert connector;
    Integer quarterMonth = ((Date.today().month()-1)/3)*3+1;
    String apiVersion = String.valueOf(Date.today().year()) + '-' + (quarterMonth < 10 ? '0' : '') + quarterMonth;
    List<Connector_Config_Value__c> config = new List<Connector_Config_Value__c>();
    Map<String,String> values = new Map<String,String>{'storeDomain'=>'contract-store.myshopify.com', 'apiVersion'=>apiVersion,
      'startDate'=>String.valueOf(Date.today().addDays(-10)), 'companyName'=>'Contract', 'pricebookName'=>'Contract book'};
    for (String key : values.keySet()) config.add(new Connector_Config_Value__c(Name=key, Connector_Instance__c=connector.Id,
      Connector_Key__c='shopify', Field_Key__c=key, Value__c=values.get(key), Is_Secret_Reference__c=false));
    insert config;
    Account customer = new Account(Name='Contract customer',Shopify_ID__c='100'); insert customer;
    Product2 product = new Product2(Name='Contract product',IsActive=true,Shopify_ID__c='200'); insert product;
    Id standard = Test.getStandardPricebookId();
    insert new PricebookEntry(Pricebook2Id=standard,Product2Id=product.Id,UnitPrice=12,IsActive=true);
    Pricebook2 book = new Pricebook2(Name='Contract book',IsActive=true); insert book;
    insert new PricebookEntry(Pricebook2Id=book.Id,Product2Id=product.Id,UnitPrice=12,IsActive=true);
  }
  private static GenericIntegrationRuntime.OperationDefinition definition(String entity,String direction) {
    ConnectorExecutionRequest request = new ConnectorExecutionRequest();
    request.connectorKey='shopify'; request.operationKey=entity+'Upsert'; request.direction=direction;
    return GenericIntegrationRuntime.resolve(request);
  }
  private static ConnectorExecutionRequest requestFor(String entity) {
    ConnectorExecutionRequest request = new ConnectorExecutionRequest();
    request.connectorKey='shopify'; request.operationKey=entity+'Upsert'; request.direction='Outbound';
    return request;
  }
  @IsTest static void envelopesAndEndpointSelection() {
    for (String entity : new List<String>{'Customer','Product','Order'}) {
      GenericIntegrationRuntime.OperationDefinition operation=definition(entity,'Outbound');
      GenericResourceContract contract=GenericResourceContract.parse(operation.resourceContractJson);
      System.assert(operation.approvedBaseUrl.startsWith('https://contract-store.myshopify.com/'));
      System.assert(contract.endpoint(operation,'123').endsWith('/'+entity.toLowerCase()+'s/123.json'));
      Map<String,Object> body=(Map<String,Object>)JSON.deserializeUntyped(contract.body('{"id":123,"note":"note","line_items":[]}',true));
      System.assert(body.containsKey(entity.toLowerCase()));
      if(entity=='Order') System.assert(!((Map<String,Object>)body.get('order')).containsKey('line_items'));
    }
  }
  @IsTest static void rejectsUnsafeResourceContract() {
    GenericIntegrationRuntime.OperationDefinition operation=definition('Customer','Outbound');
    GenericResourceContract contract=GenericResourceContract.parse(operation.resourceContractJson);
    try { contract.endpoint(operation,'../orders'); System.assert(false); } catch(GenericResourceContract.ResourceContractException expected) {}
    try { GenericResourceContract.parse(operation.resourceContractJson.replace('VersionedRestResource','ApexClass')); System.assert(false); }
    catch(GenericResourceContract.ResourceContractException expected) {}
    try { GenericResourceContract.parse(operation.resourceContractJson.replace('.myshopify.com','.evil.example')); System.assert(false); }
    catch(GenericResourceContract.ResourceContractException expected) {}
    Connector_Config_Value__c config=[SELECT Id,Value__c FROM Connector_Config_Value__c WHERE Field_Key__c='apiVersion'];
    config.Value__c='2020-01'; update config; GenericResourceContract.resetConfig();
    try { contract.version('shopify'); System.assert(false); } catch(GenericResourceContract.ResourceContractException expected) {}
  }
  @IsTest static void customerCreateAndUpdateUseRealWireContract() {
    Account fresh=new Account(Name='New customer'); insert fresh;
    List<Account> records=[SELECT Id,Name,Phone,Shopify_ID__c FROM Account ORDER BY Name];
    Test.setMock(HttpCalloutMock.class,new ResourceMock('customer',200));
    ConnectorExecutionRequest request=requestFor('Customer');
    OutboundIntegrationHandler handler=new OutboundIntegrationHandler(request);
    Test.startTest(); handler.execute(null,records); Test.stopTest();
    System.assertEquals(2,[SELECT COUNT() FROM Account WHERE Shopify_ID__c != null]);
  }
  @IsTest static void productWireContract() {
    List<Product2> records=[SELECT Id,Name,Description,Shopify_ID__c FROM Product2];
    Test.setMock(HttpCalloutMock.class,new ResourceMock('product',200));
    Test.startTest(); new OutboundIntegrationHandler(requestFor('Product')).execute(null,records); Test.stopTest();
    System.assertEquals('200',[SELECT Shopify_ID__c FROM Product2 LIMIT 1].Shopify_ID__c);
  }
  @IsTest static void bulkInboundIsIdempotent() {
    GenericIntegrationRuntime.OperationDefinition operation=definition('Customer','Inbound');
    List<Object> rows=new List<Object>();
    for(Integer i=0;i<200;i++) rows.add(new Map<String,Object>{'id'=>String.valueOf(1000+i),'first_name'=>'Customer '+i});
    String body=JSON.serialize(new Map<String,Object>{'customers'=>rows});
    Test.startTest();
    ConnectorExecutionResult first=GenericIntegrationRuntime.persistInbound(operation,body);
    ConnectorExecutionResult second=GenericIntegrationRuntime.persistInbound(operation,body);
    Test.stopTest();
    System.assertEquals(0,first.failedCount,'Result: '+first.errorSummary); System.assertEquals(200,second.successfulCount);
    System.assertEquals(201,[SELECT COUNT() FROM Account]);
    System.assertEquals(0,[SELECT COUNT() FROM Integration_Work_Item__c]);
  }
  @IsTest static void partialFailureQueuesIdentityOnlyReplay() {
    GenericIntegrationRuntime.OperationDefinition operation=definition('Customer','Inbound');
    ConnectorExecutionResult result=GenericIntegrationRuntime.persistInbound(operation,'{"customers":[{"id":"401","first_name":"Good"},{"id":"402"}]}');
    System.assertEquals(1,result.successfulCount); System.assertEquals(1,result.failedCount);
    Integration_Work_Item__c work=[SELECT Lifecycle_Action__c,Source_External_Id__c,Payload__c FROM Integration_Work_Item__c LIMIT 1];
    System.assertEquals('InboundReplay',work.Lifecycle_Action__c); System.assertEquals('402',work.Source_External_Id__c); System.assertEquals(null,work.Payload__c);
    try { GenericIntegrationRuntime.persistInbound(operation,'{"wrong":[]}'); System.assert(false); }
    catch(GenericResourceContract.ResourceContractException expected) {}
  }
  private static String orderBody(String product) {
    return '{"orders":[{"id":"300","created_at":"2026-07-01T10:00:00Z","customer":{"id":"100"},"currency":"USD","line_items":[{"id":"301","product_id":"'+product+'","quantity":2,"price":"12.00","title":"Contract line"}]}]}';
  }
  @IsTest static void orderGraphPersistsAndReimportsWithoutDuplicates() {
    GenericIntegrationRuntime.OperationDefinition operation=definition('Order','Inbound');
    Test.startTest();
    ConnectorExecutionResult result=GenericIntegrationRuntime.persistInbound(operation,orderBody('200'));
    ConnectorExecutionResult replay=GenericIntegrationRuntime.persistInbound(operation,orderBody('200'));
    Test.stopTest();
    System.assertEquals(0,result.failedCount,'Result: '+result.errorSummary); System.assertEquals(0,replay.failedCount,'Replay: '+replay.errorSummary);
    Order parent=[SELECT Id,AccountId,Pricebook2Id,EffectiveDate,Status FROM Order WHERE Shopify_ID__c='300'];
    System.assertEquals(Date.newInstance(2026,7,1),parent.EffectiveDate); System.assertEquals('Draft',parent.Status);
    System.assertEquals(1,[SELECT COUNT() FROM OrderItem WHERE OrderId=:parent.Id]);
    OrderItem line=[SELECT Quantity,UnitPrice FROM OrderItem WHERE OrderId=:parent.Id];
    System.assertEquals(2,line.Quantity); System.assertEquals(12,line.UnitPrice);
  }
  @IsTest static void missingProductDoesNotCreatePartialOrder() {
    ConnectorExecutionResult result=GenericIntegrationRuntime.persistInbound(definition('Order','Inbound'),orderBody('999'));
    System.assertEquals(1,result.failedCount); System.assertEquals(0,[SELECT COUNT() FROM Order]);
    System.assertEquals(1,[SELECT COUNT() FROM Integration_Work_Item__c]);
  }
  @IsTest static void replayRetrievesCurrentResource() {
    Test.setMock(HttpCalloutMock.class,new ResourceMock('customer',200));
    Test.startTest();
    ConnectorExecutionResult result=GenericResourceLifecycle.replay(definition('Customer','Inbound'),'777');
    Test.stopTest();
    System.assertEquals(0,result.failedCount,'Result: '+result.errorSummary);
    System.assertEquals(1,[SELECT COUNT() FROM Account WHERE Shopify_ID__c='777']);
  }
  @IsTest static void deleteIsIdempotentAndRetryClassified() {
    GenericIntegrationRuntime.OperationDefinition operation=definition('Product','Outbound');
    Test.startTest();
    Test.setMock(HttpCalloutMock.class,new ResourceMock('product',404));
    System.assert(!GenericResourceLifecycle.deleteResource(operation,'200').hasFailures());
    System.assert(!GenericResourceLifecycle.deleteResource(operation,null).hasFailures());
    Test.setMock(HttpCalloutMock.class,new ResourceMock('product',429));
    ConnectorExecutionResult limited=GenericResourceLifecycle.deleteResource(operation,'200');
    System.assert(limited.retryable); System.assertEquals(60,limited.retryDelaySeconds);
    GenericResourceContract contract=GenericResourceContract.parse(operation.resourceContractJson); contract.deleteEnabled=false;
    operation.resourceContractJson=JSON.serialize(contract);
    try { GenericResourceLifecycle.deleteResource(operation,'200'); System.assert(false); } catch(GenericResourceContract.ResourceContractException expected) {}
    Test.stopTest();
  }
  @IsTest static void transportBudgetIsSharedAndResets() {
    System.assert(GenericResourceRateLimit.reserve('shopify',20));
    System.assert(GenericResourceRateLimit.reserve('shopify',10));
    System.assertEquals(false,GenericResourceRateLimit.reserve('shopify',1));
    Connector_Instance__c row=[SELECT Id,Rate_Window_Start__c FROM Connector_Instance__c WHERE Connector_Key__c='shopify'];
    row.Rate_Window_Start__c=System.now().addSeconds(-61); update row;
    System.assert(GenericResourceRateLimit.reserve('shopify',1));
  }
  @IsTest static void healthChecksIdentityScopesAndAuthentication() {
    Connector_Instance__c instance=[SELECT Id,Named_Credential__c FROM Connector_Instance__c WHERE Connector_Key__c='shopify'];
    Test.setMock(HttpCalloutMock.class,new ResourceMock('shop',200));
    Test.startTest();
    ConnectorHealthProbeResult health=new ShopifyHealthProbe().probe(instance);
    System.assert(health.successful,String.valueOf(health.message));
    Test.setMock(HttpCalloutMock.class,new ResourceMock('shop',401));
    System.assertEquals(false,new ShopifyHealthProbe().probe(instance).successful);
    Test.stopTest();
  }
  @IsTest static void readinessValidatesMetadataAndInitialWindow() {
    List<String> issues=GenericResourceReadiness.inspect(new Set<String>{'shopify'}).get('shopify');
    System.assertEquals(0,issues.size(),String.join(issues,';'));
    GenericResourceContract contract=GenericResourceContract.parse(definition('Customer','Inbound').resourceContractJson);
    System.assertEquals(Date.today().addDays(-10),contract.initialSince('shopify').dateGmt());
    System.assert(IntegrationEventApi.supportsRecordSave('future_connector','Outbound'));
    System.assert(!IntegrationEventApi.supportsRecordSave('future_connector','Inbound'));
  }
  @IsTest static void scheduledInboundCommitsSuccessfulStartWatermark() {
    Scheduled_Integration_Job__c job=new Scheduled_Integration_Job__c(Logical_Job_Key__c='shopify-contract',Scheduler_Name__c='shopify-contract',
      Integration_Type__c='Shopify',Source_Object__c='Product2',Direction__c='Inbound',Frequency_Value__c=5,Frequency_Type__c='Minutes',
      Status__c='Claimed',Lease_Token__c='contract-lease',Created_DateTime__c=System.now());
    insert job;
    Test.setMock(HttpCalloutMock.class,new ListResourceMock());
    Datetime beforeRun=System.now();
    Test.startTest(); new IntegrationScheduleProcessor(job.Id,'contract-lease').execute(null); Test.stopTest();
    job=[SELECT Status__c,Sync_Watermark__c,Last_Error__c FROM Scheduled_Integration_Job__c WHERE Id=:job.Id];
    System.assertEquals('Active',job.Status__c,'Schedule: '+job.Last_Error__c);
    System.assertNotEquals(null,job.Sync_Watermark__c);
    System.assert(job.Sync_Watermark__c>=beforeRun.addSeconds(-1),'Persisted watermarks have second precision.');
    System.assertEquals(1,[SELECT COUNT() FROM Product2 WHERE Shopify_ID__c='888']);
  }
  @IsTest static void executionRequestNormalizesAndValidatesIdentity() {
    ConnectorExecutionRequest request=requestFor('Customer');
    request.recordIds.add([SELECT Id FROM Account LIMIT 1].Id);
    request.syncStartedAt=System.now(); request.sinceValue=System.now().addDays(-1); request.cursor='cursor'; request.correlationKey='correlation';
    ConnectorExecutionRequest normalized=request.normalizedCopy();
    System.assertEquals('Account',normalized.salesforceObject); System.assertEquals(request.syncStartedAt,normalized.syncStartedAt);
    System.assertEquals(request.recordIds,normalized.recordIds); System.assertNotEquals(null,request.operationIdentity());
    request.validate(); request.recordIds=new List<Id>{[SELECT Id FROM Product2 LIMIT 1].Id};
    try {request.validate();System.assert(false);} catch(ConnectorExecutionRequest.ConnectorExecutionRequestException expected) {}
  }
  @IsTest static void workProcessorReplaysCurrentRemoteResource() {
    IntegrationWorkRequest work=new IntegrationWorkRequest(); work.connectorKey='shopify';work.operationKey='CustomerUpsert';
    work.sourceObject='Account';work.sourceExternalId='777';work.lifecycleAction='InboundReplay';work.maximumAttempts=3;
    Id workId=IntegrationWorkService.enqueue(new List<IntegrationWorkRequest>{work})[0];
    update new Integration_Work_Item__c(Id=workId,Status__c='Processing',Processor_Token__c='work-token',Attempt_Count__c=1);
    Test.setMock(HttpCalloutMock.class,new ResourceMock('customer',200));
    Test.startTest();new IntegrationWorkProcessor(workId,'work-token').execute(null);Test.stopTest();
    System.assertEquals('Completed',[SELECT Status__c FROM Integration_Work_Item__c WHERE Id=:workId].Status__c);
    System.assertEquals(1,[SELECT COUNT() FROM Account WHERE Shopify_ID__c='777']);
  }
  @IsTest static void workProcessorDeletesUsingCapturedIdentity() {
    Account source=[SELECT Id FROM Account LIMIT 1];
    IntegrationWorkRequest work=new IntegrationWorkRequest();work.connectorKey='shopify';work.operationKey='CustomerUpsert';
    work.sourceObject='Account';work.sourceRecordId=source.Id;work.sourceExternalId='100';work.lifecycleAction='Delete';
    Id workId=IntegrationWorkService.enqueue(new List<IntegrationWorkRequest>{work})[0]; delete source;
    update new Integration_Work_Item__c(Id=workId,Status__c='Processing',Processor_Token__c='delete-token',Attempt_Count__c=1);
    Test.setMock(HttpCalloutMock.class,new ResourceMock('customer',404));
    Test.startTest();new IntegrationWorkProcessor(workId,'delete-token').execute(null);Test.stopTest();
    System.assertEquals('Completed',[SELECT Status__c FROM Integration_Work_Item__c WHERE Id=:workId].Status__c);
  }
  @IsTest static void linkPaginationPreservesCursorAndRejectsOtherStores() {
    GenericIntegrationRuntime.OperationDefinition operation=definition('Customer','Inbound');
    ConnectorExecutionRequest request=requestFor('Customer');request.direction='Inbound';request.sinceValue=System.now().addDays(-2);
    System.assert(GenericIntegrationRuntime.queryParametersFor(operation,request).containsKey('updated_at_min'));
    ConnectorHttpClient.RequestSpec spec=new ConnectorHttpClient.RequestSpec();spec.namedCredential=operation.namedCredential;
    spec.relativeEndpoint=operation.relativeEndpoint;spec.approvedBaseUrl=operation.approvedBaseUrl;
    Test.setMock(HttpCalloutMock.class,new PaginationMock(operation.approvedBaseUrl+'/customers.json?page_info=next&limit=50'));
    Test.startTest();
    ConnectorHttpClient.Response response=ConnectorHttpClient.send(spec);
    String cursor=GenericIntegrationRuntime.nextCursor(operation,response,request,50);
    System.assert(cursor.contains('page_info=next'));System.assert(!cursor.contains('updated_at_min'));
    Test.setMock(HttpCalloutMock.class,new PaginationMock('https://other-store.myshopify.com/admin/api/2026-07/customers.json?page_info=next'));
    try {GenericIntegrationRuntime.nextCursor(operation,ConnectorHttpClient.send(spec),request,50);System.assert(false);}
    catch(Exception expected) {System.assert(!expected.getMessage().contains('Assertion Failed'));}
    Test.stopTest();
  }
  @IsTest static void orderCreateCorrelatesReorderedRemoteLines() {
    Account customer=[SELECT Id FROM Account LIMIT 1];
    PricebookEntry entry=[SELECT Id,Pricebook2Id FROM PricebookEntry WHERE Pricebook2.Name='Contract book' LIMIT 1];
    Order orderRecord=new Order(AccountId=customer.Id,Pricebook2Id=entry.Pricebook2Id,EffectiveDate=Date.today(),Status='Draft');insert orderRecord;
    List<OrderItem> lines=new List<OrderItem>{new OrderItem(OrderId=orderRecord.Id,PricebookEntryId=entry.Id,Quantity=1,UnitPrice=12),
      new OrderItem(OrderId=orderRecord.Id,PricebookEntryId=entry.Id,Quantity=2,UnitPrice=12)};insert lines;
    List<Order> orders=[SELECT Id,Description,Financial_Status__c,Fulfillment_Status__c,Shopify_ID__c,Account.Shopify_ID__c FROM Order WHERE Id=:orderRecord.Id];
    Test.setMock(HttpCalloutMock.class,new OrderCreateMock());
    Test.startTest();new OutboundIntegrationHandler(requestFor('Order')).execute(null,orders);Test.stopTest();
    System.assertEquals('990',[SELECT Shopify_ID__c FROM Order WHERE Id=:orderRecord.Id].Shopify_ID__c);
    List<OrderItem> saved=[SELECT Shopify_ID__c FROM OrderItem WHERE OrderId=:orderRecord.Id ORDER BY Id];
    System.assertEquals('991',saved[0].Shopify_ID__c);System.assertEquals('992',saved[1].Shopify_ID__c);
    Object responseOrder=GenericIntegrationRuntime.valueAtPath(JSON.deserializeUntyped(lastOrderResponse),'order');
    ConnectorExecutionResult imported=GenericIntegrationRuntime.persistInbound(definition('Order','Inbound'),JSON.serialize(new Map<String,Object>{'orders'=>new List<Object>{responseOrder}}));
    System.assertEquals(0,imported.failedCount,'Round trip: '+imported.errorSummary);
    System.assertEquals(2,[SELECT COUNT() FROM OrderItem WHERE OrderId=:orderRecord.Id]);
  }
  @IsTest static void scheduledCapabilityFailureIsRecorded() {
    Scheduled_Integration_Job__c job=new Scheduled_Integration_Job__c(Logical_Job_Key__c='adapter-contract',Scheduler_Name__c='adapter-contract',
      Integration_Type__c='Shopify',Source_Object__c='Unsupported',Direction__c='Inbound',Frequency_Value__c=5,Frequency_Type__c='Minutes',
      Status__c='Claimed',Lease_Token__c='adapter-lease',Created_DateTime__c=System.now());insert job;
    ConnectorCapabilityRouter.registerTestAdapter('shopify','scheduler.operation','MetaScheduledOperationAdapter');
    Test.startTest();new IntegrationScheduleProcessor(job.Id,'adapter-lease').execute(null);Test.stopTest();
    System.assertEquals('Failed',[SELECT Status__c FROM Scheduled_Integration_Job__c WHERE Id=:job.Id].Status__c);
    ConnectorCapabilityRouter.clearTestAdapters();
  }
  @IsTest static void scheduledAdapterSuccessRetainsLeaseUntilCompletion() {
    Scheduled_Integration_Job__c job=new Scheduled_Integration_Job__c(Logical_Job_Key__c='adapter-success',Scheduler_Name__c='adapter-success',
      Integration_Type__c='Shopify',Source_Object__c='Campaign',Direction__c='Inbound',Frequency_Value__c=5,Frequency_Type__c='Minutes',
      Status__c='Claimed',Lease_Token__c='adapter-success-lease',Created_DateTime__c=System.now());insert job;
    ConnectorCapabilityRouter.registerTestAdapter('shopify','scheduler.operation','MetaScheduledOperationAdapter');
    Test.setMock(HttpCalloutMock.class,new EmptyCollectionMock());
    Test.startTest();new IntegrationScheduleProcessor(job.Id,'adapter-success-lease').execute(null);Test.stopTest();
    job=[SELECT Status__c,Lease_Token__c,Last_Error__c FROM Scheduled_Integration_Job__c WHERE Id=:job.Id];
    System.assertEquals('Active',job.Status__c,'Adapter result: '+job.Last_Error__c);
    System.assertEquals(null,job.Lease_Token__c);
    ConnectorCapabilityRouter.clearTestAdapters();
  }
  private class EmptyCollectionMock implements HttpCalloutMock {
    public HttpResponse respond(HttpRequest request) {HttpResponse response=new HttpResponse();response.setStatusCode(200);response.setBody('{"data":[]}');return response;}
  }
  private class OrderCreateMock implements HttpCalloutMock {
    public HttpResponse respond(HttpRequest request) {
      System.assertEquals('POST',request.getMethod());
      Map<String,Object> root=(Map<String,Object>)JSON.deserializeUntyped(request.getBody());
      Map<String,Object> orderBody=(Map<String,Object>)root.get('order');
      System.assertEquals('100',String.valueOf(GenericIntegrationRuntime.valueAtPath(orderBody,'customer.id')));
      List<Object> lines=(List<Object>)orderBody.get('line_items');System.assertEquals(2,lines.size());
      for(Integer i=0;i<lines.size();i++) {
        Map<String,Object> line=(Map<String,Object>)lines[i];System.assertEquals('Contract product',line.get('title'));
        System.assert(line.get('properties') instanceof List<Object>);line.put('id',String.valueOf(991+i));
      }
      orderBody.put('id','990');orderBody.put('created_at','2026-07-01T10:00:00Z');orderBody.put('currency','USD');orderBody.put('line_items',new List<Object>{lines[1],lines[0]});
      lastOrderResponse=JSON.serialize(root);
      HttpResponse response=new HttpResponse();response.setStatusCode(201);response.setBody(JSON.serialize(root));return response;
    }
  }
  private class PaginationMock implements HttpCalloutMock {
    String nextUrl;PaginationMock(String url){nextUrl=url;}
    public HttpResponse respond(HttpRequest request){HttpResponse response=new HttpResponse();response.setStatusCode(200);
      response.setHeader('Link','<'+nextUrl+'>; rel="next"');response.setBody('{"customers":[]}');return response;}
  }
  private class ListResourceMock implements HttpCalloutMock {
    public HttpResponse respond(HttpRequest request) {
      System.assert(request.getEndpoint().contains('updated_at_min='));
      HttpResponse response=new HttpResponse();response.setStatusCode(200);
      response.setBody('{"products":[{"id":"888","title":"Scheduled product"}]}');return response;
    }
  }
  private class ResourceMock implements HttpCalloutMock {
    private String root; private Integer status;
    ResourceMock(String root,Integer status) {this.root=root;this.status=status;}
    public HttpResponse respond(HttpRequest request) {
      System.assert(request.getEndpoint().startsWith('callout:Shopify_NC/'));
      HttpResponse response=new HttpResponse(); response.setStatusCode(status); response.setHeader('Retry-After','60');
      if(request.getEndpoint().endsWith('/shop.json')) response.setBody('{"shop":{"myshopify_domain":"contract-store.myshopify.com"}}');
      else if(request.getEndpoint().endsWith('/access_scopes.json')) response.setBody('{"access_scopes":[{"handle":"write_customers"},{"handle":"write_products"},{"handle":"write_orders"}]}');
      else {
        if(request.getMethod()=='POST' || request.getMethod()=='PUT') {
          Map<String,Object> payload=(Map<String,Object>)JSON.deserializeUntyped(request.getBody());
          System.assertEquals(1,payload.size()); System.assert(payload.containsKey(root),request.getBody());
          Boolean updateRequest=request.getEndpoint().endsWith('/100.json') || request.getEndpoint().endsWith('/200.json');
          System.assertEquals(updateRequest ? 'PUT':'POST',request.getMethod());
        }
        String id=request.getMethod()=='GET' ? '777' : (root=='product' ? '200' : request.getMethod()=='PUT' ? '100':'101');
        response.setBody('{"'+root+'":{"id":"'+id+'","first_name":"Wire customer","title":"Wire product"}}');
      }
      return response;
    }
  }
}