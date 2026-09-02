public inherited sharing class ConnectorReadinessService {
  // Backward-compatible DTO retained for the original configuration probe.
  public class Evaluation {
    @AuraEnabled public Boolean ready;
    @AuraEnabled public String message;
  }

  public class Assessment {
    @AuraEnabled public String connectorKey;
    @AuraEnabled public Boolean configurationReady;
    @AuraEnabled public Boolean healthReady;
    @AuraEnabled public Boolean active;
    @AuraEnabled public Boolean operationalReady;
    @AuraEnabled public List<String> issues = new List<String>();
  }

  public static Assessment assess(String connectorKey, Boolean requireActive) {
    String keyValue = requireConnectorKey(connectorKey);
    return assessAll(new Set<String>{ keyValue }, requireActive).get(keyValue);
  }

  public static Evaluation evaluateForProbe(
    Connector_Instance__c connectorInstance
  ) {
    Assessment assessment = assessmentForInstance(connectorInstance, false);
    return evaluation(
      assessment.configurationReady,
      assessment,
      new Set<String>{ 'A successful credential health probe is required.', 'The connector is inactive.' }
    );
  }

  public static Evaluation evaluateForActivation(
    Connector_Instance__c connectorInstance
  ) {
    Assessment assessment = assessmentForInstance(connectorInstance, false);
    return evaluation(
      assessment.configurationReady && assessment.healthReady,
      assessment,
      new Set<String>{ 'The connector is inactive.' }
    );
  }

  public static Map<String, Evaluation> evaluateForDashboard(
    List<Connector_Instance__c> connectorInstances
  ) {
    Map<String, Evaluation> result = new Map<String, Evaluation>();
    Set<String> connectorKeys = new Set<String>();
    for (Connector_Instance__c connectorInstance : connectorInstances == null
      ? new List<Connector_Instance__c>()
      : connectorInstances) {
      if (connectorInstance != null && String.isNotBlank(connectorInstance.Connector_Key__c)) {
        connectorKeys.add(requireConnectorKey(connectorInstance.Connector_Key__c));
      }
    }
    Map<String, Assessment> assessments = assessAll(connectorKeys, true);
    for (String connectorKey : assessments.keySet()) {
      Assessment assessment = assessments.get(connectorKey);
      result.put(
        connectorKey,
        evaluation(assessment.operationalReady, assessment, new Set<String>())
      );
    }
    return result;
  }

  public static String expectedNamedCredential(String connectorKey) {
    return ConnectorCredentialPolicy.expectedNamedCredential(connectorKey);
  }

  public static Map<String, Assessment> assessAll(
    Set<String> connectorKeys,
    Boolean requireActive
  ) {
    Set<String> safeKeys = new Set<String>();
    for (String connectorKey : connectorKeys == null
      ? new Set<String>()
      : connectorKeys) {
      safeKeys.add(requireConnectorKey(connectorKey));
    }
    Map<String, Assessment> results = new Map<String, Assessment>();
    if (safeKeys.isEmpty()) return results;

    Map<String, Integration_Connector__mdt> definitionByKey =
      new Map<String, Integration_Connector__mdt>();
    for (Integration_Connector__mdt definition : [
      SELECT Connector_Key__c, Enabled__c, Has_Mapping__c
      FROM Integration_Connector__mdt
      WHERE Connector_Key__c IN :safeKeys AND Enabled__c = true
    ]) {
      definitionByKey.put(definition.Connector_Key__c.toLowerCase(), definition);
    }

    Map<String, Connector_Instance__c> instanceByKey =
      new Map<String, Connector_Instance__c>();
    for (Connector_Instance__c instanceRecord : [
      SELECT Id, Connector_Key__c, Active__c, Health_Status__c,
        Named_Credential__c, External_Credential__c
      FROM Connector_Instance__c
      WHERE Connector_Key__c IN :safeKeys
    ]) {
      instanceByKey.put(instanceRecord.Connector_Key__c.toLowerCase(), instanceRecord);
    }

    Map<String, Set<String>> requiredConfigByConnector =
      new Map<String, Set<String>>();
    for (Connector_Config_Field__mdt configDefinition : [
      SELECT Connector_Key__c, Field_Key__c
      FROM Connector_Config_Field__mdt
      WHERE Connector_Key__c IN :safeKeys
        AND Required__c = true
        AND Secret__c = false
    ]) {
      addValue(
        requiredConfigByConnector,
        configDefinition.Connector_Key__c.toLowerCase(),
        configDefinition.Field_Key__c
      );
    }
    Map<String, Set<String>> populatedConfigByConnector =
      new Map<String, Set<String>>();
    for (Connector_Config_Value__c configValue : [
      SELECT Connector_Key__c, Field_Key__c, Value__c
      FROM Connector_Config_Value__c
      WHERE Connector_Key__c IN :safeKeys
        AND Is_Secret_Reference__c = false
    ]) {
      if (String.isNotBlank(configValue.Value__c)) {
        addValue(
          populatedConfigByConnector,
          configValue.Connector_Key__c.toLowerCase(),
          configValue.Field_Key__c
        );
      }
    }

    Map<String, List<Integration_Operation__mdt>> operationsByConnector =
      new Map<String, List<Integration_Operation__mdt>>();
    for (Integration_Operation__mdt operation : [
      SELECT Connector_Key__c, Operation_Key__c, Salesforce_Object__c,
        Direction__c
      FROM Integration_Operation__mdt
      WHERE Connector_Key__c IN :safeKeys AND Active__c = true
    ]) {
      String connectorKey = operation.Connector_Key__c.toLowerCase();
      if (!operationsByConnector.containsKey(connectorKey)) {
        operationsByConnector.put(
          connectorKey,
          new List<Integration_Operation__mdt>()
        );
      }
      operationsByConnector.get(connectorKey).add(operation);
    }
    Set<String> capabilityOnlyMappingConnectors = new Set<String>();
    for (Integration_Connector_Capability__mdt capability : [
      SELECT Connector_Key__c, Capability_Key__c
      FROM Integration_Connector_Capability__mdt
      WHERE Connector_Key__c IN :safeKeys AND Enabled__c = true
    ]) {
      String capabilityKey = String.isBlank(capability.Capability_Key__c)
        ? ''
        : capability.Capability_Key__c.toLowerCase();
      if (
        capabilityKey == 'carrier.operation' ||
        capabilityKey == 'payment.checkout'
      ) {
        capabilityOnlyMappingConnectors.add(
          capability.Connector_Key__c.toLowerCase()
        );
      }
    }
    Map<String, List<Integration_Operation_Mapping__mdt>> mappingsByConnector =
      new Map<String, List<Integration_Operation_Mapping__mdt>>();
    for (Integration_Operation_Mapping__mdt mapping : [
      SELECT Connector_Key__c, Operation_Key__c, Salesforce_Object__c,
        Salesforce_Field__c
      FROM Integration_Operation_Mapping__mdt
      WHERE Connector_Key__c IN :safeKeys AND Active__c = true
    ]) {
      String connectorKey = mapping.Connector_Key__c.toLowerCase();
      if (!mappingsByConnector.containsKey(connectorKey)) {
        mappingsByConnector.put(
          connectorKey,
          new List<Integration_Operation_Mapping__mdt>()
        );
      }
      mappingsByConnector.get(connectorKey).add(mapping);
    }

    for (String connectorKey : safeKeys) {
      Assessment result = newAssessment(connectorKey);
      Integration_Connector__mdt definition = definitionByKey.get(connectorKey);
      Connector_Instance__c instanceRecord = instanceByKey.get(connectorKey);
      if (definition == null) {
        result.issues.add('The connector metadata is missing or disabled.');
        result.configurationReady = false;
      }
      if (instanceRecord == null) {
        result.issues.add('The connector instance is missing.');
        result.configurationReady = false;
      } else {
        result.active = instanceRecord.Active__c;
        result.healthReady = instanceRecord.Health_Status__c == 'Ready';
        if (String.isBlank(instanceRecord.Named_Credential__c)) {
          result.issues.add('The Named Credential reference is missing.');
          result.configurationReady = false;
        } else if (
          instanceRecord.Named_Credential__c !=
            ConnectorCredentialPolicy.expectedNamedCredential(connectorKey)
        ) {
          result.issues.add('The connector references an unexpected Named Credential.');
          result.configurationReady = false;
        }
        if (String.isBlank(instanceRecord.External_Credential__c)) {
          result.issues.add('The External Credential reference is missing.');
          result.configurationReady = false;
        } else if (
          instanceRecord.External_Credential__c !=
            ConnectorCredentialPolicy.expectedExternalCredential(connectorKey)
        ) {
          result.issues.add('The connector references an unexpected External Credential.');
          result.configurationReady = false;
        }
      }
      Set<String> missingConfig = new Set<String>(
        requiredConfigByConnector.containsKey(connectorKey)
          ? requiredConfigByConnector.get(connectorKey)
          : new Set<String>()
      );
      missingConfig.removeAll(
        populatedConfigByConnector.containsKey(connectorKey)
          ? populatedConfigByConnector.get(connectorKey)
          : new Set<String>()
      );
      if (!missingConfig.isEmpty()) {
        List<String> missing = new List<String>(missingConfig);
        missing.sort();
        result.issues.add(
          'Required configuration is missing: ' + String.join(missing, ', ') + '.'
        );
        result.configurationReady = false;
      }
      if (definition != null && definition.Has_Mapping__c == true) {
        if (
          operationsByConnector.containsKey(connectorKey) ||
          !capabilityOnlyMappingConnectors.contains(connectorKey)
        ) {
          validateMappingLists(
            operationsByConnector.get(connectorKey),
            mappingsByConnector.get(connectorKey),
            result
          );
        }
      }
      if (!result.healthReady) {
        result.issues.add('A successful credential health probe is required.');
      }
      results.put(connectorKey, finish(result, requireActive));
    }
    return results;
  }

  private static Assessment newAssessment(String connectorKey) {
    Assessment result = new Assessment();
    result.connectorKey = connectorKey;
    result.configurationReady = true;
    result.healthReady = false;
    result.active = false;
    result.operationalReady = false;
    return result;
  }

  private static Assessment assessmentForInstance(
    Connector_Instance__c connectorInstance,
    Boolean requireActive
  ) {
    if (
      connectorInstance == null ||
      String.isBlank(connectorInstance.Connector_Key__c)
    ) {
      Assessment missing = newAssessment(null);
      missing.configurationReady = false;
      missing.issues.add('The connector instance is missing.');
      return finish(missing, requireActive);
    }
    return assess(connectorInstance.Connector_Key__c, requireActive);
  }

  private static Evaluation evaluation(
    Boolean ready,
    Assessment assessment,
    Set<String> ignoredIssues
  ) {
    Evaluation result = new Evaluation();
    result.ready = ready == true;
    List<String> messages = new List<String>();
    for (String issue : assessment == null || assessment.issues == null
      ? new List<String>()
      : assessment.issues) {
      if (ignoredIssues == null || !ignoredIssues.contains(issue)) {
        messages.add(issue);
      }
    }
    result.message = result.ready
      ? 'Configuration is ready.'
      : (messages.isEmpty() ? 'Connector readiness requirements are not met.' : String.join(messages, ' '));
    return result;
  }

  private static void addValue(
    Map<String, Set<String>> valuesByConnector,
    String connectorKey,
    String value
  ) {
    if (!valuesByConnector.containsKey(connectorKey)) {
      valuesByConnector.put(connectorKey, new Set<String>());
    }
    valuesByConnector.get(connectorKey).add(value);
  }

  private static void validateMappingLists(
    List<Integration_Operation__mdt> operations,
    List<Integration_Operation_Mapping__mdt> mappings,
    Assessment result
  ) {
    if (operations == null || operations.isEmpty()) {
      result.issues.add('No active integration operations are configured.');
      result.configurationReady = false;
      return;
    }
    Set<String> activeOperationKeys = new Set<String>();
    Map<String, Schema.SObjectType> objectTypes = new Map<String, Schema.SObjectType>();
    for (Integration_Operation__mdt operation : operations) {
      activeOperationKeys.add(operation.Operation_Key__c);
      Schema.SObjectType objectType = ConnectorExecutionRequest.resolveSObjectType(
        operation.Salesforce_Object__c
      );
      if (objectType == null) {
        result.issues.add(
          'Configured Salesforce object is unavailable: ' +
          operation.Salesforce_Object__c + '.'
        );
        result.configurationReady = false;
        continue;
      }
      objectTypes.put(operation.Salesforce_Object__c, objectType);
      Schema.DescribeSObjectResult describeResult = objectType.getDescribe();
      String direction = String.isBlank(operation.Direction__c)
        ? ''
        : operation.Direction__c.toLowerCase();
      if (direction.contains('inbound') && !describeResult.isCreateable()) {
        result.issues.add(
          'Create access is missing for ' + operation.Salesforce_Object__c + '.'
        );
        result.configurationReady = false;
      }
      if (direction.contains('outbound') && !describeResult.isAccessible()) {
        result.issues.add(
          'Read access is missing for ' + operation.Salesforce_Object__c + '.'
        );
        result.configurationReady = false;
      }
    }
    Integer mappingCount = 0;
    for (Integration_Operation_Mapping__mdt mapping : mappings == null
      ? new List<Integration_Operation_Mapping__mdt>()
      : mappings) {
      if (!activeOperationKeys.contains(mapping.Operation_Key__c)) continue;
      mappingCount++;
      Schema.SObjectType objectType = objectTypes.get(mapping.Salesforce_Object__c);
      if (objectType == null) {
        objectType = ConnectorExecutionRequest.resolveSObjectType(
          mapping.Salesforce_Object__c
        );
      }
      String fieldName = String.isBlank(mapping.Salesforce_Field__c)
        ? null
        : mapping.Salesforce_Field__c.substringBefore('.');
      if (
        objectType == null ||
        String.isBlank(fieldName) ||
        !objectType.getDescribe().fields.getMap().containsKey(fieldName)
      ) {
        result.issues.add(
          'Configured mapping field is unavailable: ' +
          mapping.Salesforce_Object__c + '.' + mapping.Salesforce_Field__c + '.'
        );
        result.configurationReady = false;
      }
    }
    if (mappingCount == 0) {
      result.issues.add('No active field mappings are configured.');
      result.configurationReady = false;
    }
  }

  private static Assessment finish(Assessment result, Boolean requireActive) {
    if (requireActive == true && !result.active) {
      result.issues.add('The connector is inactive.');
    }
    result.operationalReady =
      result.configurationReady &&
      result.healthReady &&
      (requireActive != true || result.active);
    return result;
  }

  private static String requireConnectorKey(String value) {
    String result = String.isBlank(value) ? null : value.trim().toLowerCase();
    if (
      String.isBlank(result) ||
      !Pattern.matches('^[a-z][a-z0-9_-]{0,79}$', result)
    ) {
      throw new ConnectorReadinessException('Connector key is invalid.');
    }
    return result;
  }

  public class ConnectorReadinessException extends Exception {}
}