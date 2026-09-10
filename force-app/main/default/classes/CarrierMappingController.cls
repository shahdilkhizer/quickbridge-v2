public with sharing class CarrierMappingController {
  public class Option {
    @AuraEnabled public String label;
    @AuraEnabled public String value;
    public Option(String label, String value) { this.label = label; this.value = value; }
  }
  public class MappingRow {
    @AuraEnabled public String salesforceField;
    @AuraEnabled public String externalPath;
    @AuraEnabled public String direction;
    @AuraEnabled public Boolean active;
  }
  public class Workspace {
    @AuraEnabled public List<CarrierOperationModels.Definition> operations;
    @AuraEnabled public List<Option> objects;
    @AuraEnabled public List<Option> fields;
    @AuraEnabled public List<MappingRow> mappings;
  }
  public class SaveRequest {
    public String connectorKey;
    public String operationKey;
    public String salesforceObject;
    public List<MappingRow> mappings;
  }
  public class SaveResponse { @AuraEnabled public String deploymentId; }

  @AuraEnabled(cacheable=true)
  public static Workspace getWorkspace(String connectorKey, String salesforceObject) {
    requireManage();
    Workspace workspace = new Workspace();
    workspace.operations = CarrierOperationCatalog.definitionsFor(connectorKey);
    workspace.objects = discoverObjects();
    workspace.fields = String.isBlank(salesforceObject) ? new List<Option>() : fieldsFor(salesforceObject);
    workspace.mappings = String.isBlank(salesforceObject) ? new List<MappingRow>() : mappingsFor(connectorKey, null, salesforceObject);
    return workspace;
  }

  @AuraEnabled(cacheable=true)
  public static List<MappingRow> getMappings(String connectorKey, String operationKey, String salesforceObject) {
    requireManage();
    CarrierOperationCatalog.requireDefinition(connectorKey, operationKey);
    return mappingsFor(connectorKey, operationKey, salesforceObject);
  }

  @AuraEnabled
  public static SaveResponse saveMappings(String requestJson) {
    requireManage();
    SaveRequest request;
    try { request = (SaveRequest)JSON.deserialize(requestJson, SaveRequest.class); }
    catch (Exception ignored) { throw handled('Carrier mapping request is invalid.'); }
    if (request == null || String.isBlank(request.salesforceObject)) throw handled('Select a Salesforce object.');
    CarrierOperationModels.Definition definition = CarrierOperationCatalog.requireDefinition(request.connectorKey, request.operationKey);
    Map<String, Schema.SObjectField> fields = requireObject(request.salesforceObject).getDescribe().fields.getMap();
    List<Field_Mapping__mdt> existing = [
      SELECT DeveloperName FROM Field_Mapping__mdt WHERE Integration__c = :definition.connectorKey
        AND Action__c = :definition.operationKey AND SF_Object__c = :request.salesforceObject
    ];
    Metadata.DeployContainer container = new Metadata.DeployContainer();
    for (Field_Mapping__mdt row : existing) container.addMetadata(toMetadata(row.DeveloperName, definition, request.salesforceObject, null, false));
    Set<String> identities = new Set<String>();
    for (MappingRow row : request.mappings == null ? new List<MappingRow>() : request.mappings) {
      validateRow(row, fields);
      String identity = String.join(new List<String>{definition.connectorKey,definition.operationKey,request.salesforceObject,row.salesforceField,row.externalPath,row.direction}, '|');
      if (!identities.add(identity)) throw handled('Duplicate carrier field mappings are not allowed.');
      container.addMetadata(toMetadata('Carrier_' + digest(identity), definition, request.salesforceObject, row, row.active != false));
    }
    SaveResponse response = new SaveResponse();
    response.deploymentId = Metadata.Operations.enqueueDeployment(container, null);
    return response;
  }

  private static List<Option> discoverObjects() {
    List<Option> result = new List<Option>();
    Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();
    List<String> candidates = new List<String>();
    for (String name : globalDescribe.keySet()) {
      if (!name.endsWith('__Share') && !name.endsWith('__History')) candidates.add(name);
    }
    for (Integer start = 0; start < candidates.size(); start += 100) {
      List<String> batch = new List<String>();
      Integer finish = Math.min(start + 100, candidates.size());
      for (Integer index = start; index < finish; index++) batch.add(candidates[index]);
      for (Schema.DescribeSObjectResult describe : Schema.describeSObjects(batch)) {
        if (!describe.isAccessible() || !describe.isQueryable() || describe.isCustomSetting()) continue;
        result.add(new Option(describe.getLabel() + ' (' + describe.getName() + ')', describe.getName()));
      }
    }
    return result;
  }
  private static List<Option> fieldsFor(String objectName) {
    List<Option> result = new List<Option>();
    for (Schema.SObjectField field : requireObject(objectName).getDescribe().fields.getMap().values()) {
      Schema.DescribeFieldResult describe = field.getDescribe();
      if (describe.isAccessible() && describe.getName() != 'Id' && describe.getType() != Schema.DisplayType.Address) result.add(new Option(describe.getLabel() + ' (' + describe.getName() + ')', describe.getName()));
    }
    return result;
  }
  private static List<MappingRow> mappingsFor(String connectorKey, String operationKey, String objectName) {
    List<MappingRow> result = new List<MappingRow>();
    String connector = CarrierOperationCatalog.normalize(connectorKey);
    List<Field_Mapping__mdt> rows = String.isBlank(operationKey) ? [
      SELECT SF_Field__c, External_Field__c, Sync_Direction__c, Is_Active__c FROM Field_Mapping__mdt
      WHERE Integration__c = :connector AND SF_Object__c = :objectName ORDER BY SF_Field__c
    ] : [
      SELECT SF_Field__c, External_Field__c, Sync_Direction__c, Is_Active__c FROM Field_Mapping__mdt
      WHERE Integration__c = :connector AND SF_Object__c = :objectName AND Action__c = :operationKey ORDER BY SF_Field__c
    ];
    for (Field_Mapping__mdt row : rows) {
      MappingRow item = new MappingRow(); item.salesforceField=row.SF_Field__c; item.externalPath=row.External_Field__c; item.direction=row.Sync_Direction__c; item.active=row.Is_Active__c; result.add(item);
    }
    return result;
  }
  private static Metadata.CustomMetadata toMetadata(String developerName, CarrierOperationModels.Definition definition, String objectName, MappingRow row, Boolean active) {
    Metadata.CustomMetadata item = new Metadata.CustomMetadata(); item.fullName='Field_Mapping__mdt.'+developerName; item.label=(definition.connectorKey+' '+definition.operationKey+' '+(row==null?'inactive':row.salesforceField)).left(40);
    add(item,'Integration__c',definition.connectorKey); add(item,'Action__c',definition.operationKey); add(item,'SF_Object__c',objectName);
    add(item,'SF_Field__c',row==null?'Id':row.salesforceField); add(item,'External_Field__c',row==null?'inactive':row.externalPath); add(item,'Sync_Direction__c',row==null?'Both':row.direction); add(item,'Is_Active__c',active); add(item,'Target_Object_API_Name__c','Carrier');
    return item;
  }
  private static void add(Metadata.CustomMetadata record,String field,Object value){Metadata.CustomMetadataValue setting=new Metadata.CustomMetadataValue();setting.field=field;setting.value=value;record.values.add(setting);}
  private static void validateRow(MappingRow row,Map<String,Schema.SObjectField> fields){if(row==null||String.isBlank(row.salesforceField)||!fields.containsKey(row.salesforceField)||!fields.get(row.salesforceField).getDescribe().isAccessible())throw handled('Selected Salesforce field is invalid.');if(String.isBlank(row.externalPath)||!Pattern.matches('^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z0-9_]+){0,19}$',row.externalPath))throw handled('Carrier field paths are invalid.');String direction=String.isBlank(row.direction)?'Both':row.direction;if(!new Set<String>{'Outbound','Inbound','Both'}.contains(direction))throw handled('Carrier mapping direction is invalid.');if((direction=='Inbound'||direction=='Both')&&!fields.get(row.salesforceField).getDescribe().isUpdateable())throw handled('Selected response field is not updateable.');}
  private static Schema.SObjectType requireObject(String objectName){if(String.isBlank(objectName)||!Pattern.matches('^[A-Za-z][A-Za-z0-9_]{0,79}$',objectName))throw handled('Salesforce object is invalid.');Schema.SObjectType typeValue=Schema.getGlobalDescribe().get(objectName);if(typeValue==null||!typeValue.getDescribe().isAccessible())throw handled('Salesforce object is unavailable.');return typeValue;}
  private static String digest(String value){return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256',Blob.valueOf(value))).left(32);}
  private static void requireManage(){QuickbridgeAdminSecurity.requireManage();}
  private static AuraHandledException handled(String message){AuraHandledException error=new AuraHandledException(message);error.setMessage(message);return error;}
}