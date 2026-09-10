/** Salesforce Order/OrderItem domain constraints for a configured resource graph. */
public inherited sharing class ResourceOrderContext {
  private GenericIntegrationRuntime.OperationDefinition definition;
  private GenericResourceContract contract;
  private Id pricebookId;
  private Map<String,Id> accounts = new Map<String,Id>();
  private Map<String,Id> entries = new Map<String,Id>();
  private Set<String> ambiguousAccounts = new Set<String>();
  private Set<String> ambiguousEntries = new Set<String>();
  private Boolean multiCurrency;
  private Map<String,SObject> correlatedLines=new Map<String,SObject>();

  public ResourceOrderContext(GenericIntegrationRuntime.OperationDefinition definition, GenericResourceContract contract, List<Object> rows) {
    this.definition = definition; this.contract = contract;
    GenericResourceContract.require(definition.salesforceObject == 'Order', 'SalesOrderLines requires the Order object.');
    GenericResourceContract.require(String.isNotBlank(contract.childCollection) && String.isNotBlank(contract.productPath) && String.isNotBlank(contract.customerPath), 'Configure the order graph paths.');
    String pricebookName = ConnectorConfigService.getConfigValue(definition.connectorKey, contract.pricebookConfig);
    GenericResourceContract.require(String.isNotBlank(pricebookName), 'Configure pricebookName for inbound orders.');
    List<Pricebook2> books = [SELECT Id FROM Pricebook2 WHERE Name = :pricebookName AND IsActive = true WITH USER_MODE LIMIT 2];
    GenericResourceContract.require(books.size() == 1, 'pricebookName must identify exactly one active price book.');
    pricebookId = books[0].Id;
    Set<String> customerIds = new Set<String>(); Set<String> productIds = new Set<String>(); Set<Id> sourceLineIds=new Set<Id>();
    for (Object raw : rows) {
      if (!(raw instanceof Map<String,Object>)) continue;
      Map<String,Object> row = (Map<String,Object>)raw;
      Object customer = GenericIntegrationRuntime.valueAtPath(row, contract.customerPath);
      if (customer != null) customerIds.add(String.valueOf(customer));
      Object lines = GenericIntegrationRuntime.valueAtPath(row, contract.childCollection);
      if (lines instanceof List<Object>) for (Object line : (List<Object>)lines) {
        Object product = GenericIntegrationRuntime.valueAtPath(line, contract.productPath);
        if (product != null) productIds.add(String.valueOf(product));
        String sourceId=sourceLineId(line);
        if(String.isNotBlank(sourceId)) {
          try {Id localId=Id.valueOf(sourceId);if(localId.getSObjectType()==OrderItem.SObjectType) sourceLineIds.add(localId);}
          catch(Exception invalidId) { /* Unrecognized remote properties are not local identities. */ }
        }
      }
    }
    String field = definition.salesforceExternalIdField;
    GenericResourceContract.require(Account.SObjectType.getDescribe().fields.getMap().containsKey(field) &&
      Product2.SObjectType.getDescribe().fields.getMap().containsKey(field) && OrderItem.SObjectType.getDescribe().fields.getMap().containsKey(field), 'The resource identity field must exist on Account, Product2 and OrderItem.');
    for(SObject line:Database.queryWithBinds('SELECT Id,PricebookEntryId,PricebookEntry.Pricebook2Id,'+field+',Order.'+field+
      ' FROM OrderItem WHERE Id IN :ids',new Map<String,Object>{'ids'=>sourceLineIds},AccessLevel.USER_MODE)) correlatedLines.put(String.valueOf(line.Id),line);
    for (SObject row : Database.queryWithBinds('SELECT Id,' + field + ' FROM Account WHERE ' + field + ' IN :ids',
        new Map<String,Object>{'ids'=>customerIds}, AccessLevel.USER_MODE)) {
      String key = (String)row.get(field);
      if (accounts.containsKey(key)) ambiguousAccounts.add(key);
      accounts.put(key, row.Id);
    }
    multiCurrency = PricebookEntry.SObjectType.getDescribe().fields.getMap().containsKey('CurrencyIsoCode');
    String query = 'SELECT Id,Product2.' + field + (multiCurrency ? ',CurrencyIsoCode' : '') +
      ' FROM PricebookEntry WHERE Pricebook2Id = :book AND IsActive = true AND Product2.' + field + ' IN :ids';
    for (SObject row : Database.queryWithBinds(query, new Map<String,Object>{'book'=>pricebookId,'ids'=>productIds}, AccessLevel.USER_MODE)) {
      String key = (String)row.getSObject('Product2').get(field) + ':' + (multiCurrency ? (String)row.get('CurrencyIsoCode') : '');
      if (entries.containsKey(key)) ambiguousEntries.add(key);
      entries.put(key, row.Id);
    }
  }

  public void prepare(Map<String,Object> row) {
    String customer = String.valueOf(GenericIntegrationRuntime.valueAtPath(row, contract.customerPath));
    GenericResourceContract.require(accounts.containsKey(customer) && !ambiguousAccounts.contains(customer), 'Import the uniquely identified customer before its order; guest orders require an explicit mapping.');
    row.put('_accountId', accounts.get(customer)); row.put('_pricebookId', pricebookId);
    Object raw = GenericIntegrationRuntime.valueAtPath(row, contract.childCollection);
    GenericResourceContract.require(raw instanceof List<Object> && !((List<Object>)raw).isEmpty(), 'Inbound order requires line items.');
    String currencyCode = multiCurrency ? String.valueOf(GenericIntegrationRuntime.valueAtPath(row, contract.currencyPath)) : '';
    for (Object item : (List<Object>)raw) {
      GenericResourceContract.require(item instanceof Map<String,Object>, 'Order line must be an object.');
      Map<String,Object> line = (Map<String,Object>)item;
      String key = String.valueOf(GenericIntegrationRuntime.valueAtPath(line, contract.productPath)) + ':' + currencyCode;
      SObject correlated=correlatedLines.get(sourceLineId(line));
      if(correlated!=null && String.valueOf(correlated.getSObject('Order').get(definition.salesforceExternalIdField))==GenericInboundResourcePersistence.identity(definition,row) &&
        correlated.getSObject('PricebookEntry').get('Pricebook2Id')==pricebookId &&
        String.valueOf(correlated.get(definition.salesforceExternalIdField))==String.valueOf(line.get('id'))) {
        line.put('_pricebookEntryId',correlated.get('PricebookEntryId'));
      } else {
        GenericResourceContract.require(entries.containsKey(key) && !ambiguousEntries.contains(key), 'A line requires one active price book entry for its imported product and currency.');
        line.put('_pricebookEntryId', entries.get(key));
      }
      // Validate every line before parent DML. Parent link is supplied after the parent upsert.
      GenericInboundResourcePersistence.mapRecord(definition, 'OrderItem', line);
    }
  }

  private static String sourceLineId(Object line) {
    Object properties=GenericIntegrationRuntime.valueAtPath(line,'properties');
    if(properties instanceof List<Object>) for(Object property:(List<Object>)properties) {
      if(GenericIntegrationRuntime.valueAtPath(property,'name')=='_quickbridge_source_id') return (String)GenericIntegrationRuntime.valueAtPath(property,'value');
    }
    return null;
  }

  public void persistChildren(List<Id> parentIds, List<Map<String,Object>> rows,
    ConnectorExecutionResult result, List<IntegrationWorkRequest> failures) {
    List<SObject> children = new List<SObject>(); List<Map<String,Object>> parentRows = new List<Map<String,Object>>();
    for (Integer i=0; i<rows.size(); i++) {
      for (Object raw : (List<Object>)GenericIntegrationRuntime.valueAtPath(rows[i], contract.childCollection)) {
        SObject child = GenericInboundResourcePersistence.mapRecord(definition, 'OrderItem', (Map<String,Object>)raw);
        child.put('OrderId', parentIds[i]); children.add(child); parentRows.add(rows[i]);
      }
    }
    if (children.isEmpty()) return;
    Set<String> childIdentities=new Set<String>();
    String identityName=definition.salesforceExternalIdField;
    for(SObject child:children) {
      String identity=(String)child.get(identityName);
      GenericResourceContract.require(String.isNotBlank(identity) && !childIdentities.contains(identity),'Order lines require distinct external identities.');
      childIdentities.add(identity);
    }
    Map<String,SObject> existing=new Map<String,SObject>();
    for(SObject child:Database.queryWithBinds('SELECT Id,OrderId,PricebookEntryId,'+identityName+' FROM OrderItem WHERE '+identityName+' IN :ids',
      new Map<String,Object>{'ids'=>childIdentities},AccessLevel.USER_MODE)) {
      String identity=(String)child.get(identityName);
      GenericResourceContract.require(!existing.containsKey(identity),'Duplicate stored order-line external identity.');
      existing.put(identity,child);
    }
    List<SObject> creates=new List<SObject>(); List<SObject> updates=new List<SObject>();
    Map<Id,Map<String,Object>> updateParents=new Map<Id,Map<String,Object>>();
    List<Map<String,Object>> createParents=new List<Map<String,Object>>();
    for(Integer i=0;i<children.size();i++) {
      SObject child=children[i]; SObject current=existing.get((String)child.get(identityName));
      if(current==null) {creates.add(child);createParents.add(parentRows[i]);}
      else {
        GenericResourceContract.require(current.get('OrderId')==child.get('OrderId') && current.get('PricebookEntryId')==child.get('PricebookEntryId'),
          'An existing order line cannot be reassigned to another order or price book entry.');
        SObject changed=OrderItem.SObjectType.newSObject(current.Id);
        for(String field:child.getPopulatedFieldsAsMap().keySet()) if(field!='OrderId' && field!='PricebookEntryId') changed.put(field,child.get(field));
        updates.add(changed);updateParents.put(changed.Id,parentRows[i]);
      }
    }
    if(!creates.isEmpty()) {
      SObjectAccessDecision createAccess=Security.stripInaccessible(AccessType.CREATABLE,creates);
      GenericResourceContract.require(createAccess.getRemovedFields().isEmpty(),'Order line create access is missing.');
      Database.SaveResult[] saved=Database.insert(createAccess.getRecords(),false);
      for(Integer i=0;i<saved.size();i++) if(!saved[i].isSuccess()) GenericInboundResourcePersistence.fail(definition,createParents[i],
        'Order line: '+GenericInboundResourcePersistence.errors(saved[i].getErrors()),result,failures);
    }
    if(!updates.isEmpty()) {
      SObjectAccessDecision updateAccess=Security.stripInaccessible(AccessType.UPDATABLE,updates);
      GenericResourceContract.require(updateAccess.getRemovedFields().isEmpty(),'Order line update access is missing.');
      Database.SaveResult[] saved=Database.update(updateAccess.getRecords(),false);
      for(Integer i=0;i<saved.size();i++) if(!saved[i].isSuccess()) GenericInboundResourcePersistence.fail(definition,updateParents.get(updates[i].Id),
        'Order line: '+GenericInboundResourcePersistence.errors(saved[i].getErrors()),result,failures);
    }
  }
}