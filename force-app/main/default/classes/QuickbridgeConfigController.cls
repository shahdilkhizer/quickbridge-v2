public with sharing class QuickbridgeConfigController {
  @TestVisible private static Boolean bypassSecurityForTests = false;

  public class Dashboard {
    @AuraEnabled public List<ConnectorCard> connectors;
    @AuraEnabled public List<ErrorSummary> recentErrors;
    @AuraEnabled public Boolean canAdminister;

    public Dashboard() {
      connectors = new List<ConnectorCard>();
      recentErrors = new List<ErrorSummary>();
    }
  }

  public class ConnectorCard {
    @AuraEnabled public String key;
    @AuraEnabled public String label;
    @AuraEnabled public Boolean active;
    @AuraEnabled public Boolean ready;
    @AuraEnabled public String readinessMessage;
    @AuraEnabled public String health;
    @AuraEnabled public Integer successCount = 0;
    @AuraEnabled public Integer pendingCount = 0;
    @AuraEnabled public Integer retryCount = 0;
    @AuraEnabled public Integer failureCount = 0;
    @AuraEnabled public Datetime lastRun;
    @AuraEnabled public Datetime nextRun;
    @AuraEnabled public String scheduleState;
  }

  public class ErrorSummary {
    @AuraEnabled public Id id;
    @AuraEnabled public String connector;
    @AuraEnabled public String category;
    @AuraEnabled public String message;
    @AuraEnabled public String sourceObject;
    @AuraEnabled public String sourceRecordId;
    @AuraEnabled public String retryStatus;
    @AuraEnabled public Datetime createdAt;
  }

  public class ConnectorConfiguration {
    @AuraEnabled public String connectorKey;
    @AuraEnabled public String connectorLabel;
    @AuraEnabled public String environment;
    @AuraEnabled public String namedCredential;
    @AuraEnabled public String externalCredential;
    @AuraEnabled public List<ConfigurationField> fields = new List<ConfigurationField>();
  }

  public class ConfigurationField {
    @AuraEnabled public String key;
    @AuraEnabled public String label;
    @AuraEnabled public String dataType;
    @AuraEnabled public Boolean required;
    @AuraEnabled public String value;
  }

  @AuraEnabled(cacheable=true)
  public static Dashboard getDashboard() {
    assertReadAccess();
    Dashboard result = new Dashboard();
    result.canAdminister = canAdminister();
    Map<String, ConnectorCard> byKey = connectorDefinitions();
    Set<String> connectorKeys = byKey.keySet();
    Map<String, ConnectorReadinessService.Assessment> readinessByKey =
      ConnectorReadinessService.assessAll(connectorKeys, true);

    for (Connector_Instance__c instance : [
      SELECT Connector_Key__c, Active__c, Named_Credential__c,
        Health_Status__c, Last_Health_Check_At__c
      FROM Connector_Instance__c
      WHERE Connector_Key__c IN :connectorKeys
    ]) {
      String keyValue = normalize(instance.Connector_Key__c);
      ConnectorCard card = byKey.get(keyValue);
      if (card == null) continue;
      ConnectorReadinessService.Assessment assessment = readinessByKey.get(
        keyValue
      );
      card.active = instance.Active__c;
      card.health = String.isBlank(instance.Health_Status__c)
        ? 'Unknown'
        : instance.Health_Status__c;
      card.ready = assessment != null && assessment.operationalReady;
      card.readinessMessage = card.ready
        ? 'Connector configuration, permissions, credentials, and health are ready.'
        : readinessMessage(assessment);
    }

    for (AggregateResult aggregateRow : [
      SELECT Integration__c connector, Status__c statusValue, COUNT(Id) countValue
      FROM Integration_Work_Item__c
      WHERE Integration__c IN :connectorKeys
      GROUP BY Integration__c, Status__c
    ]) {
      ConnectorCard card = byKey.get(normalize((String) aggregateRow.get('connector')));
      if (card == null) continue;
      Integer countValue = (Integer) aggregateRow.get('countValue');
      String statusValue = (String) aggregateRow.get('statusValue');
      if (statusValue == IntegrationWorkService.STATUS_COMPLETED) card.successCount += countValue;
      else if (statusValue == IntegrationWorkService.STATUS_RETRY) card.retryCount += countValue;
      else if (statusValue == IntegrationWorkService.STATUS_FAILED) card.failureCount += countValue;
      else card.pendingCount += countValue;
    }

    Map<String, String> connectorByIntegrationType = connectorKeysByIntegrationType();
    for (Scheduled_Integration_Job__c scheduleRow : [
      SELECT Integration_Type__c, Status__c, Last_Run_At__c, Next_Run_At__c
      FROM Scheduled_Integration_Job__c
      ORDER BY Next_Run_At__c ASC NULLS LAST
    ]) {
      ConnectorCard card = byKey.get(
        connectorByIntegrationType.get(normalize(scheduleRow.Integration_Type__c))
      );
      if (card == null) continue;
      if (card.lastRun == null || (scheduleRow.Last_Run_At__c != null && scheduleRow.Last_Run_At__c > card.lastRun)) {
        card.lastRun = scheduleRow.Last_Run_At__c;
      }
      if (card.nextRun == null || (scheduleRow.Next_Run_At__c != null && scheduleRow.Next_Run_At__c < card.nextRun)) {
        card.nextRun = scheduleRow.Next_Run_At__c;
      }
      card.scheduleState = scheduleRow.Status__c;
    }

    result.connectors.addAll(byKey.values());
    result.connectors.sort(new ConnectorCardComparator());
    if (Schema.sObjectType.Error_Log__c.isAccessible()) {
      for (Error_Log__c errorRow : [
        SELECT Id, Error_Category__c, Error_Message__c, Source_Object__c,
          Source_Record_Id__c, Retry_Status__c, External_Reference__c, CreatedDate
        FROM Error_Log__c
        ORDER BY CreatedDate DESC
        LIMIT 20
      ]) {
        ErrorSummary summary = new ErrorSummary();
        summary.id = errorRow.Id;
        summary.connector = connectorFromReference(errorRow.External_Reference__c);
        summary.category = errorRow.Error_Category__c;
        summary.message = IntegrationErrorLogService.sanitizeForUser(errorRow.Error_Message__c);
        summary.sourceObject = errorRow.Source_Object__c;
        summary.sourceRecordId = errorRow.Source_Record_Id__c;
        summary.retryStatus = errorRow.Retry_Status__c;
        summary.createdAt = errorRow.CreatedDate;
        result.recentErrors.add(summary);
      }
    }
    return result;
  }

  @AuraEnabled(cacheable=true)
  public static ConnectorConfiguration getConnectorConfiguration(String connectorKey) {
    assertConfigReadAccess();
    String keyValue = requireConnector(connectorKey);
    List<Connector_Instance__c> instances = [
      SELECT Id, Connector_Label__c, Environment__c, Named_Credential__c,
        External_Credential__c
      FROM Connector_Instance__c
      WHERE Connector_Key__c = :keyValue
      LIMIT 1
    ];
    if (instances.isEmpty()) {
      throw new AuraHandledException('Connector configuration is missing.');
    }

    Map<String, String> valueByKey = new Map<String, String>();
    for (Connector_Config_Value__c configValue : [
      SELECT Field_Key__c, Value__c
      FROM Connector_Config_Value__c
      WHERE Connector_Key__c = :keyValue AND Is_Secret_Reference__c = false
    ]) {
      valueByKey.put(configValue.Field_Key__c, configValue.Value__c);
    }

    Connector_Instance__c instanceRecord = instances[0];
    ConnectorConfiguration result = new ConnectorConfiguration();
    result.connectorKey = keyValue;
    result.connectorLabel = instanceRecord.Connector_Label__c;
    result.environment = instanceRecord.Environment__c;
    result.namedCredential = instanceRecord.Named_Credential__c;
    result.externalCredential = instanceRecord.External_Credential__c;
    for (Connector_Config_Field__mdt fieldDefinition : configDefinitions(keyValue)) {
      ConfigurationField fieldValue = new ConfigurationField();
      fieldValue.key = fieldDefinition.Field_Key__c;
      fieldValue.label = fieldDefinition.Label__c;
      fieldValue.dataType = fieldDefinition.Data_Type__c;
      fieldValue.required = fieldDefinition.Required__c;
      fieldValue.value = valueByKey.get(fieldDefinition.Field_Key__c);
      result.fields.add(fieldValue);
    }
    return result;
  }

  @AuraEnabled
  public static ConnectorConfiguration saveConnectorConfiguration(
    String connectorKey,
    String valuesJson
  ) {
    assertAdminAccess();
    assertConfigWriteAccess();
    String keyValue = requireConnector(connectorKey);
    Map<String, Object> submittedValues;
    try {
      submittedValues = (Map<String, Object>) JSON.deserializeUntyped(valuesJson);
    } catch (Exception ignored) {
      throw new AuraHandledException('Configuration values are invalid.');
    }
    if (submittedValues == null) submittedValues = new Map<String, Object>();

    List<Connector_Config_Field__mdt> definitions = configDefinitions(keyValue);
    Map<String, Connector_Config_Field__mdt> definitionByKey =
      new Map<String, Connector_Config_Field__mdt>();
    for (Connector_Config_Field__mdt definition : definitions) {
      definitionByKey.put(definition.Field_Key__c, definition);
    }
    for (String submittedKey : submittedValues.keySet()) {
      if (!definitionByKey.containsKey(submittedKey)) {
        throw new AuraHandledException('Unsupported connector configuration field.');
      }
    }

    List<Connector_Instance__c> instances = [
      SELECT Id FROM Connector_Instance__c
      WHERE Connector_Key__c = :keyValue
      LIMIT 1
    ];
    if (instances.isEmpty()) {
      throw new AuraHandledException('Connector configuration is missing.');
    }

    Map<String, Connector_Config_Value__c> existingByKey =
      new Map<String, Connector_Config_Value__c>();
    for (Connector_Config_Value__c existingValue : [
      SELECT Id, Field_Key__c, Value__c
      FROM Connector_Config_Value__c
      WHERE Connector_Key__c = :keyValue AND Is_Secret_Reference__c = false
      FOR UPDATE
    ]) {
      existingByKey.put(existingValue.Field_Key__c, existingValue);
    }

    List<Connector_Config_Value__c> toInsert = new List<Connector_Config_Value__c>();
    List<Connector_Config_Value__c> toUpdate = new List<Connector_Config_Value__c>();
    for (Connector_Config_Field__mdt definition : definitions) {
      String normalizedValue = normalizeConfigValue(
        definition,
        submittedValues.get(definition.Field_Key__c)
      );
      Connector_Config_Value__c valueRecord = existingByKey.get(definition.Field_Key__c);
      if (valueRecord == null) {
        valueRecord = new Connector_Config_Value__c(
          Name = (keyValue + ' ' + definition.Label__c).left(80),
          Connector_Instance__c = instances[0].Id,
          Connector_Key__c = keyValue,
          Field_Key__c = definition.Field_Key__c,
          Is_Secret_Reference__c = false,
          Value__c = normalizedValue
        );
        toInsert.add(valueRecord);
      } else if (valueRecord.Value__c != normalizedValue) {
        valueRecord.Value__c = normalizedValue;
        toUpdate.add(valueRecord);
      }
    }

    if (!toInsert.isEmpty()) {
      List<SObject> insertable = Security.stripInaccessible(
        AccessType.CREATABLE,
        toInsert
      ).getRecords();
      assertSaveResults(Database.insert(insertable, false));
    }
    if (!toUpdate.isEmpty()) {
      List<SObject> updateable = Security.stripInaccessible(
        AccessType.UPDATABLE,
        toUpdate
      ).getRecords();
      assertSaveResults(Database.update(updateable, false));
    }
    return getConnectorConfiguration(keyValue);
  }

  @AuraEnabled
  public static void runConnector(String connectorKey) {
    assertAdminAccess();
    String keyValue = requireConnector(connectorKey);
    ConnectorReadinessService.Assessment assessment =
      ConnectorReadinessService.assess(keyValue, true);
    if (!assessment.operationalReady) {
      throw new AuraHandledException(readinessMessage(assessment));
    }
    String integrationType = integrationTypeFor(keyValue);
    List<Scheduled_Integration_Job__c> schedules = [
      SELECT Id, Status__c, Next_Run_At__c
      FROM Scheduled_Integration_Job__c
      WHERE Integration_Type__c = :integrationType AND Status__c != 'Deleted'
      FOR UPDATE
    ];
    for (Scheduled_Integration_Job__c scheduleRow : schedules) {
      scheduleRow.Status__c = 'Ready';
      scheduleRow.Next_Run_At__c = System.now();
      scheduleRow.Lease_Token__c = null;
      scheduleRow.Lease_Expires_At__c = null;
    }
    if (!schedules.isEmpty()) Database.update(schedules, false);
    new IntegrationHeartbeat().execute(null);
  }

  @AuraEnabled
  public static void setConnectorPaused(String connectorKey, Boolean paused) {
    assertAdminAccess();
    String keyValue = requireConnector(connectorKey);
    if (paused != true) {
      ConnectorHealthProbeResult probeResult = ConnectorHealthService.probe(
        keyValue
      );
      ConnectorReadinessService.Assessment assessment =
        ConnectorReadinessService.assess(keyValue, false);
      if (!probeResult.successful || !assessment.operationalReady) {
        throw new AuraHandledException(readinessMessage(assessment));
      }
    }
    List<Connector_Instance__c> instances = [
      SELECT Id, Active__c, Named_Credential__c FROM Connector_Instance__c
      WHERE Connector_Key__c = :keyValue LIMIT 1 FOR UPDATE
    ];
    if (instances.isEmpty()) throw new AuraHandledException('Connector configuration is missing.');
    instances[0].Active__c = paused != true;
    update instances[0];
    String integrationType = integrationTypeFor(keyValue);
    List<Scheduled_Integration_Job__c> schedules = [
      SELECT Id, Status__c, Next_Run_At__c
      FROM Scheduled_Integration_Job__c
      WHERE Integration_Type__c = :integrationType AND Status__c != 'Deleted'
    ];
    for (Scheduled_Integration_Job__c scheduleRow : schedules) {
      scheduleRow.Status__c = paused == true ? 'Paused' : 'Ready';
      if (paused != true) scheduleRow.Next_Run_At__c = System.now();
    }
    if (!schedules.isEmpty()) Database.update(schedules, false);
  }

  @AuraEnabled
  public static void replayWorkItem(Id workItemId) {
    assertAdminAccess();
    if (workItemId == null) throw new AuraHandledException('Work item is required.');
    IntegrationWorkService.manualRetry(workItemId);
  }

  @AuraEnabled
  public static ConnectorHealthProbeResult runHealthProbe(String connectorKey) {
    assertAdminAccess();
    String keyValue = requireConnector(connectorKey);
    return ConnectorHealthService.probe(keyValue);
  }

  // Retained for existing admin automation and tests while the UI uses runHealthProbe.
  @AuraEnabled
  public static ConnectorCredentialProbe.ProbeResult probeConnector(
    String connectorKey
  ) {
    assertAdminAccess();
    return ConnectorCredentialProbe.probe(requireConnector(connectorKey));
  }

  private static Map<String, ConnectorCard> connectorDefinitions() {
    Map<String, ConnectorCard> result = new Map<String, ConnectorCard>();
    for (Integration_Connector__mdt definition : [
      SELECT Connector_Key__c, Provider_Label__c, Enabled__c
      FROM Integration_Connector__mdt
      WHERE Enabled__c = true
      ORDER BY Display_Order__c
    ]) {
      String keyValue = normalize(definition.Connector_Key__c);
      if (String.isBlank(keyValue)) continue;
      ConnectorCard card = new ConnectorCard();
      card.key = keyValue;
      card.label = definition.Provider_Label__c;
      card.active = false;
      card.ready = false;
      card.health = 'Unknown';
      card.readinessMessage = 'Connector instance configuration is missing.';
      result.put(keyValue, card);
    }
    return result;
  }

  private static void assertReadAccess() {
    if (Test.isRunningTest() && bypassSecurityForTests) return;
    if (!Schema.sObjectType.Connector_Instance__c.isAccessible() ||
        !Schema.sObjectType.Integration_Work_Item__c.isAccessible() ||
        !Schema.sObjectType.Scheduled_Integration_Job__c.isAccessible()) {
      throw new AuraHandledException('Quickbridge read access is required.');
    }
  }

  private static void assertConfigReadAccess() {
    if (Test.isRunningTest() && bypassSecurityForTests) return;
    if (!Schema.sObjectType.Connector_Instance__c.isAccessible() ||
        !Schema.sObjectType.Connector_Config_Value__c.isAccessible() ||
        !Schema.sObjectType.Connector_Config_Value__c.fields.Field_Key__c.isAccessible() ||
        !Schema.sObjectType.Connector_Config_Value__c.fields.Value__c.isAccessible()) {
      throw new AuraHandledException('Quickbridge configuration read access is required.');
    }
  }

  private static void assertConfigWriteAccess() {
    if (Test.isRunningTest() && bypassSecurityForTests) return;
    if (!Schema.sObjectType.Connector_Config_Value__c.isCreateable() ||
        !Schema.sObjectType.Connector_Config_Value__c.isUpdateable() ||
        !Schema.sObjectType.Connector_Config_Value__c.fields.Connector_Instance__c.isCreateable() ||
        !Schema.sObjectType.Connector_Config_Value__c.fields.Connector_Key__c.isCreateable() ||
        !Schema.sObjectType.Connector_Config_Value__c.fields.Field_Key__c.isCreateable() ||
        !Schema.sObjectType.Connector_Config_Value__c.fields.Is_Secret_Reference__c.isCreateable() ||
        !Schema.sObjectType.Connector_Config_Value__c.fields.Value__c.isCreateable() ||
        !Schema.sObjectType.Connector_Config_Value__c.fields.Value__c.isUpdateable()) {
      throw new AuraHandledException('Quickbridge configuration edit access is required.');
    }
  }

  private static void assertAdminAccess() {
    if (!canAdminister()) throw new AuraHandledException('Quickbridge administrator access is required.');
  }

  private static Boolean canAdminister() {
    if (Test.isRunningTest() && bypassSecurityForTests) return true;
    return Schema.sObjectType.Connector_Instance__c.isUpdateable() &&
      Schema.sObjectType.Integration_Work_Item__c.isUpdateable() &&
      Schema.sObjectType.Scheduled_Integration_Job__c.isUpdateable();
  }

  private static String requireConnector(String connectorKey) {
    String value = normalize(connectorKey);
    if (String.isBlank(value)) {
      throw new AuraHandledException('Unsupported connector.');
    }
    List<Integration_Connector__mdt> definitions = [
      SELECT Connector_Key__c
      FROM Integration_Connector__mdt
      WHERE Connector_Key__c = :value AND Enabled__c = true
      LIMIT 1
    ];
    if (definitions.isEmpty()) {
      throw new AuraHandledException('Unsupported connector.');
    }
    return value;
  }

  private static String integrationTypeFor(String connectorKey) {
    Integration_Connector__mdt definition = [
      SELECT Integration_Type__c
      FROM Integration_Connector__mdt
      WHERE Connector_Key__c = :connectorKey AND Enabled__c = true
      LIMIT 1
    ];
    return String.isBlank(definition.Integration_Type__c)
      ? connectorKey
      : definition.Integration_Type__c;
  }

  private static Map<String, String> connectorKeysByIntegrationType() {
    Map<String, String> result = new Map<String, String>();
    for (Integration_Connector__mdt definition : [
      SELECT Connector_Key__c, Integration_Type__c, Provider_Label__c
      FROM Integration_Connector__mdt
      WHERE Enabled__c = true
    ]) {
      String connectorKey = normalize(definition.Connector_Key__c);
      result.put(normalize(definition.Integration_Type__c), connectorKey);
      result.put(normalize(definition.Provider_Label__c), connectorKey);
      result.put(connectorKey, connectorKey);
    }
    return result;
  }

  private static String readinessMessage(
    ConnectorReadinessService.Assessment assessment
  ) {
    if (assessment == null || assessment.issues == null || assessment.issues.isEmpty()) {
      return 'Connector readiness could not be verified.';
    }
    return String.join(assessment.issues, ' ');
  }

  private static String connectorFromReference(String value) {
    if (String.isBlank(value)) return null;
    String normalized = value.toLowerCase();
    if (normalized.contains('shopify')) return 'shopify';
    if (normalized.contains('qbo') || normalized.contains('quickbooks')) return 'qbo';
    return null;
  }

  private static String normalize(String value) {
    return String.isBlank(value) ? '' : value.trim().toLowerCase().replaceAll('[^a-z0-9]', '');
  }

  private static List<Connector_Config_Field__mdt> configDefinitions(String keyValue) {
    return [
      SELECT Connector_Key__c, Field_Key__c, Label__c, Data_Type__c,
        Required__c, Secret__c, Sort_Order__c
      FROM Connector_Config_Field__mdt
      WHERE Connector_Key__c = :keyValue AND Secret__c = false
      ORDER BY Sort_Order__c, Label__c
    ];
  }

  private static String normalizeConfigValue(
    Connector_Config_Field__mdt definition,
    Object rawValue
  ) {
    String value = rawValue == null ? '' : String.valueOf(rawValue).trim();
    if (definition.Required__c && String.isBlank(value)) {
      throw new AuraHandledException(definition.Label__c + ' is required.');
    }
    String dataType = String.isBlank(definition.Data_Type__c)
      ? 'text'
      : definition.Data_Type__c.trim().toLowerCase();
    if (dataType == 'boolean') {
      if (String.isBlank(value)) return 'false';
      String normalizedBoolean = value.toLowerCase();
      if (normalizedBoolean != 'true' && normalizedBoolean != 'false') {
        throw new AuraHandledException(definition.Label__c + ' must be true or false.');
      }
      return normalizedBoolean;
    }
    if (dataType == 'date' && String.isNotBlank(value)) {
      try {
        Date.valueOf(value);
      } catch (Exception ignored) {
        throw new AuraHandledException(definition.Label__c + ' must be a valid date.');
      }
    }
    if (value.length() > 32768) {
      throw new AuraHandledException(definition.Label__c + ' is too long.');
    }
    return value;
  }

  private static void assertSaveResults(List<Database.SaveResult> results) {
    for (Database.SaveResult saveResult : results) {
      if (saveResult.isSuccess()) continue;
      String message = saveResult.getErrors().isEmpty()
        ? 'Unknown configuration persistence error.'
        : IntegrationErrorLogService.sanitizeForUser(saveResult.getErrors()[0].getMessage());
      throw new AuraHandledException('Configuration could not be saved: ' + message);
    }
  }

  private class ConnectorCardComparator implements Comparator<ConnectorCard> {
    public Integer compare(ConnectorCard leftValue, ConnectorCard rightValue) {
      return leftValue.label.toLowerCase().compareTo(rightValue.label.toLowerCase());
    }
  }
}