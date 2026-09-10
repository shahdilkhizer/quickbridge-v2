/** Allowlisted REST behavior; inherited sharing preserves the caller's data boundary. */
public inherited sharing class GenericResourceContract {
  public String profile;
  public String envelope;
  public String resource;
  public String hostConfig;
  public String hostSuffix;
  public String versionConfig;
  public String defaultVersion;
  public String initialDateConfig;
  public Boolean deleteEnabled;
  public List<String> updateFields;
  public List<String> immutableCollections;
  public List<String> requiredScopes;
  public String graphProfile;
  public String childCollection;
  public String customerPath;
  public String productPath;
  public String currencyPath;
  public String pricebookConfig;
  private static Map<String,Map<String,String>> configCache = new Map<String,Map<String,String>>();
  public static void primeConfig(Set<String> keys) {
    Set<String> missing = new Set<String>();
    for (String key : keys) if (!configCache.containsKey(key.toLowerCase())) { missing.add(key.toLowerCase()); configCache.put(key.toLowerCase(), new Map<String,String>()); }
    if (missing.isEmpty()) return;
    for (Connector_Config_Value__c row : [SELECT Connector_Key__c,Field_Key__c,Value__c FROM Connector_Config_Value__c WHERE Connector_Key__c IN :missing AND Is_Secret_Reference__c = false]) {
      configCache.get(row.Connector_Key__c.toLowerCase()).put(row.Field_Key__c,row.Value__c);
    }
  }
  public static String config(String connectorKey,String fieldKey) {
    primeConfig(new Set<String>{connectorKey});
    return configCache.get(connectorKey.toLowerCase()).get(fieldKey);
  }
  @TestVisible private static void resetConfig() { configCache.clear(); }

  public static GenericResourceContract parse(String value) {
    if (String.isBlank(value)) return null;
    GenericResourceContract contract = (GenericResourceContract) JSON.deserializeStrict(value, GenericResourceContract.class);
    require(contract.profile == 'VersionedRestResource', 'Unsupported resource profile.');
    require(Pattern.matches('[a-z][a-z0-9_]*', contract.envelope == null ? '' : contract.envelope), 'Invalid resource envelope.');
    require(Pattern.matches('[a-z][a-z0-9_]*', contract.resource == null ? '' : contract.resource), 'Invalid resource name.');
    require(contract.hostSuffix == '.myshopify.com', 'Unsupported resource host boundary.');
    require(String.isNotBlank(contract.hostConfig) && String.isNotBlank(contract.versionConfig), 'Resource configuration keys are required.');
    require(contract.graphProfile == null || contract.graphProfile == 'SalesOrderLines', 'Unsupported child persistence profile.');
    return contract;
  }

  public String version(String connectorKey) {
    String configured = config(connectorKey, versionConfig);
    String value = String.isBlank(configured) ? defaultVersion : configured;
    require(value != null && Pattern.matches('20[0-9]{2}-(01|04|07|10)', value), 'Configure a quarterly API version.');
    Date released = Date.valueOf(value + '-01');
    require(released <= Date.today() && released.addMonths(12).addDays(15) > Date.today(), 'The configured API version is future or expired.');
    return value;
  }

  public void apply(GenericIntegrationRuntime.OperationDefinition definition) {
    String domain = config(definition.connectorKey, hostConfig);
    require(domain != null && Pattern.matches('[a-z0-9][a-z0-9-]*\\.myshopify\\.com', domain.toLowerCase()), 'Configure a canonical storeDomain ending in .myshopify.com.');
    String apiVersion = version(definition.connectorKey);
    definition.approvedBaseUrl = 'https://' + domain.toLowerCase() + '/admin/api/' + apiVersion;
    definition.relativeEndpoint = '/admin/api/' + apiVersion + '/' + resource + '.json';
    require(String.isNotBlank(definition.salesforceExternalIdField), 'Resource synchronization requires an external ID field.');
    Schema.DescribeFieldResult identityField = ConnectorExecutionRequest.resolveSObjectType(definition.salesforceObject)
      .getDescribe().fields.getMap().get(definition.salesforceExternalIdField).getDescribe();
    require(identityField.isExternalId(), 'Resource identity must be an external ID field.');
    require(String.isBlank(definition.requestTemplate), 'Resource mappings cannot be replaced with a request template.');
  }

  public Datetime initialSince(String connectorKey) {
    String value = config(connectorKey, initialDateConfig);
    require(String.isNotBlank(value), 'Configure the initial synchronization date.');
    Date day = Date.valueOf(value);
    require(day <= Date.today(), 'Initial synchronization date cannot be in the future.');
    return Datetime.newInstanceGmt(day, Time.newInstance(0, 0, 0, 0));
  }

  public String endpoint(GenericIntegrationRuntime.OperationDefinition definition, String externalId) {
    if (String.isBlank(externalId)) return definition.relativeEndpoint;
    require(Pattern.matches('[0-9]+', externalId), 'External resource identity must be numeric.');
    return definition.relativeEndpoint.substringBeforeLast('.json') + '/' + externalId + '.json';
  }

  public String body(String mappedJson, Boolean updating) {
    Map<String, Object> mapped = (Map<String, Object>) JSON.deserializeUntyped(mappedJson);
    if (updating && updateFields != null) {
      Set<String> allowed = new Set<String>(updateFields);
      for (String key : new Set<String>(mapped.keySet())) if (!allowed.contains(key)) mapped.remove(key);
    }
    return JSON.serialize(new Map<String, Object>{ envelope => mapped });
  }

  public static void require(Boolean condition, String message) {
    if (condition != true) throw new ResourceContractException(message);
  }
  public class ResourceContractException extends Exception {}
}