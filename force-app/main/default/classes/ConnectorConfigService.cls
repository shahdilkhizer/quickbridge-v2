public with sharing class ConnectorConfigService {
  @AuraEnabled(cacheable=true)
  public static Connector_Instance__c getInstance(String connectorKey) {
    String normalizedKey = normalize(connectorKey);
    if (String.isBlank(normalizedKey)) {
      return null;
    }
    List<Connector_Instance__c> rows = [
      SELECT
        Id,
        Name,
        Connector_Key__c,
        Connector_Label__c,
        Active__c,
        Environment__c,
        Health_Status__c,
        Named_Credential__c,
        External_Credential__c,
        Last_Health_Check_At__c
      FROM Connector_Instance__c
      WHERE Connector_Key__c = :normalizedKey
      LIMIT 1
    ];
    return rows.isEmpty() ? null : rows[0];
  }

  public static String getConfigValue(String connectorKey, String fieldKey) {
    String normalizedKey = normalize(connectorKey);
    if (String.isBlank(normalizedKey) || String.isBlank(fieldKey)) {
      return null;
    }
    List<Connector_Config_Value__c> rows = [
      SELECT Value__c
      FROM Connector_Config_Value__c
      WHERE Connector_Key__c = :normalizedKey AND Field_Key__c = :fieldKey
      LIMIT 1
    ];
    return rows.isEmpty() ? null : rows[0].Value__c;
  }

  public static Boolean isActive(String connectorKey) {
    Connector_Instance__c instanceRecord = getInstance(connectorKey);
    return instanceRecord != null && instanceRecord.Active__c == true;
  }

  public static String namedCredentialFor(String connectorKey) {
    Connector_Instance__c instanceRecord = getInstance(connectorKey);
    return instanceRecord == null ? null : instanceRecord.Named_Credential__c;
  }

  public static void updateHealth(String connectorKey, String healthStatus) {
    Connector_Instance__c instanceRecord = getInstance(connectorKey);
    if (instanceRecord == null) {
      return;
    }
    instanceRecord.Health_Status__c = String.isBlank(healthStatus)
      ? 'Unknown'
      : healthStatus.left(60);
    instanceRecord.Last_Health_Check_At__c = System.now();
    Database.update(instanceRecord, false);
  }

  private static String normalize(String value) {
    return String.isBlank(value) ? null : value.trim().toLowerCase();
  }
}