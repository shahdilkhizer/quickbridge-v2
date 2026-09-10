/** Validate resource contracts through the same resolver used by execution. */
public inherited sharing class GenericResourceReadiness {
  public static Map<String,List<String>> automationIssues(Set<String> keys) {
    Map<String,List<String>> issues=new Map<String,List<String>>();
    Map<String,String> types=new Map<String,String>();
    for(Integration_Connector__mdt connector:[SELECT Connector_Key__c,Integration_Type__c FROM Integration_Connector__mdt WHERE Connector_Key__c IN :keys]) types.put(connector.Connector_Key__c.toLowerCase(),connector.Integration_Type__c);
    Set<String> integrationTypes=new Set<String>(types.values());Set<String> scheduled=new Set<String>();
    for(Scheduled_Integration_Job__c job:[SELECT Integration_Type__c,Source_Object__c FROM Scheduled_Integration_Job__c
      WHERE Integration_Type__c IN :integrationTypes AND Direction__c='Inbound' AND Status__c IN ('Ready','Active','Claimed','Running')]) {
      scheduled.add(job.Integration_Type__c+':'+job.Source_Object__c);
    }
    for(Integration_Operation__mdt operation:[SELECT Connector_Key__c,Operation_Key__c,Salesforce_Object__c,External_Entity__c,Direction__c,Run_On_Record_Save__c,Resource_Contract_JSON__c
      FROM Integration_Operation__mdt WHERE Connector_Key__c IN :keys AND Active__c=true]) {
      if(String.isBlank(operation.Resource_Contract_JSON__c)) continue;
      String key=operation.Connector_Key__c.toLowerCase();if(!issues.containsKey(key)) issues.put(key,new List<String>());
      if(operation.Direction__c=='Outbound' && operation.Run_On_Record_Save__c!=true) issues.get(key).add(operation.Operation_Key__c+': record-save outbound is disabled.');
      if(operation.Direction__c=='Inbound') {
        String prefix=types.get(key)+':';
        if(!scheduled.contains(prefix+operation.Operation_Key__c) && !scheduled.contains(prefix+operation.Salesforce_Object__c) && !scheduled.contains(prefix+operation.External_Entity__c))
          issues.get(key).add(operation.Operation_Key__c+': no runnable inbound schedule exists.');
      }
    }
    return issues;
  }
  public static Map<String,List<String>> inspect(Set<String> keys) {
    Map<String,List<String>> issues = new Map<String,List<String>>();
    Map<String,String> pricebooks=new Map<String,String>();
    GenericResourceContract.primeConfig(keys);
    GenericIntegrationRuntime.primeMappingCache(keys);
    for (Integration_Operation__mdt operation : [SELECT Connector_Key__c,Operation_Key__c,Direction__c,Resource_Contract_JSON__c
      FROM Integration_Operation__mdt WHERE Connector_Key__c IN :keys AND Active__c = true]) {
      if (String.isBlank(operation.Resource_Contract_JSON__c)) continue;
      String key = operation.Connector_Key__c.toLowerCase();
      if (!issues.containsKey(key)) issues.put(key,new List<String>());
      try {
        ConnectorExecutionRequest request = new ConnectorExecutionRequest();
        request.connectorKey = key; request.operationKey = operation.Operation_Key__c; request.direction = operation.Direction__c;
        GenericIntegrationRuntime.OperationDefinition definition = GenericIntegrationRuntime.resolve(request);
        GenericResourceContract contract = GenericResourceContract.parse(definition.resourceContractJson);
        if (request.direction == 'Inbound') {
          contract.initialSince(key);
          GenericResourceContract.require(String.isNotBlank(definition.sinceQueryParam), 'Inbound resource requires a watermark query parameter.');
          Set<String> mapped = new Set<String>();
          for (GenericIntegrationRuntime.MappingRule mapping : definition.mappings) {
            if (mapping.salesforceObject.equalsIgnoreCase(definition.salesforceObject) &&
              new Set<String>{'inbound','both','bidirectional'}.contains(mapping.direction.toLowerCase())) mapped.add(mapping.salesforceField.toLowerCase());
          }
          Map<String,Schema.SObjectField> fields = ConnectorExecutionRequest.resolveSObjectType(definition.salesforceObject).getDescribe().fields.getMap();
          for (Schema.SObjectField field : fields.values()) {
            Schema.DescribeFieldResult description = field.getDescribe();
            if (description.isCreateable() && !description.isNillable() && !description.isDefaultedOnCreate() && !description.isAutoNumber()) {
              GenericResourceContract.require(mapped.contains(description.getName().toLowerCase()), 'Missing required inbound mapping: ' + description.getName());
            }
          }
          if (contract.graphProfile != null) {
            String pricebook=GenericResourceContract.config(key,contract.pricebookConfig);
            GenericResourceContract.require(String.isNotBlank(pricebook), 'Configure the inbound order price book.');
            pricebooks.put(key,pricebook);
          }
        } else {
          GenericResourceContract.require(definition.requestCardinality == 'Record', 'Resource outbound requires record cardinality.');
        }
        GenericResourceContract.require(String.isNotBlank(definition.retryStatuses) && definition.retryStatuses.contains('429'), 'Resource retry policy must include HTTP 429.');
      } catch (Exception error) { issues.get(key).add(operation.Operation_Key__c + ': ' + ConnectorExecutionResult.sanitizeError(error.getMessage())); }
    }
    if(!pricebooks.isEmpty()) {
      Set<String> names=new Set<String>(pricebooks.values());Map<String,Integer> counts=new Map<String,Integer>();
      for(Pricebook2 book:[SELECT Name FROM Pricebook2 WHERE Name IN :names AND IsActive=true WITH USER_MODE]) {
        counts.put(book.Name,(counts.containsKey(book.Name)?counts.get(book.Name):0)+1);
      }
      for(String key:pricebooks.keySet()) if(counts.get(pricebooks.get(key))!=1) issues.get(key).add('The configured price book must identify exactly one active price book.');
    }
    return issues;
  }
}