public with sharing class QuickbridgeReportingController {
  @TestVisible private static Boolean bypassReadAccessForTests = false;

  public class Report {
    @AuraEnabled public List<ProductUsage> products = new List<ProductUsage>();
    @AuraEnabled public Datetime refreshedAt = System.now();
  }
  public class ProductUsage {
    @AuraEnabled public String connectorKey; @AuraEnabled public String label; @AuraEnabled public Boolean subscribed;
    @AuraEnabled public String subscriptionStatus; @AuraEnabled public Date expiryDate; @AuraEnabled public Integer daysRemaining;
    @AuraEnabled public Integer syncedRecords = 0; @AuraEnabled public Integer errors = 0; @AuraEnabled public Integer endpointUsage = 0;
    @AuraEnabled public Integer syncedRecordLimit = 0; @AuraEnabled public Integer errorLimit = 0; @AuraEnabled public Integer endpointLimit = 0;
    @AuraEnabled public Decimal syncedPercent = 0; @AuraEnabled public Decimal errorPercent = 0; @AuraEnabled public Decimal endpointPercent = 0;
    @AuraEnabled public Datetime lastUpdated;
  }

  public class OperationalOverview {
    @AuraEnabled public Integer activeConnectorCount = 0;
    @AuraEnabled public Integer readyConnectorCount = 0;
    @AuraEnabled public Integer attentionConnectorCount = 0;
    @AuraEnabled public Integer completedWorkCount = 0;
    @AuraEnabled public Integer backlogCount = 0;
    @AuraEnabled public Integer failedWorkCount = 0;
    @AuraEnabled public Integer overdueScheduleCount = 0;
    @AuraEnabled public Datetime lastSuccessfulWorkAt;
    @AuraEnabled public List<ConnectorOperationalRow> connectors = new List<ConnectorOperationalRow>();
  }

  public class ConnectorOperationalRow {
    @AuraEnabled public String connectorKey;
    @AuraEnabled public String label;
    @AuraEnabled public Boolean active = false;
    @AuraEnabled public Boolean ready = false;
    @AuraEnabled public String health = 'Unknown';
    @AuraEnabled public Integer completedWorkCount = 0;
    @AuraEnabled public Integer pendingWorkCount = 0;
    @AuraEnabled public Integer processingWorkCount = 0;
    @AuraEnabled public Integer retryWorkCount = 0;
    @AuraEnabled public Integer failedWorkCount = 0;
    @AuraEnabled public Integer overdueScheduleCount = 0;
    @AuraEnabled public Datetime lastSuccessfulWorkAt;
    @AuraEnabled public Datetime nextScheduledRunAt;
    @AuraEnabled public String scheduleState = 'Not scheduled';
  }

  @AuraEnabled(cacheable=false)
  public static Report getReport(String sessionToken, String connectorKey) {
    QuickbridgeAdminSecurity.requireSession(sessionToken);
    String filterKey = String.isBlank(connectorKey) ? null : connectorKey.trim().toLowerCase();
    Map<String, ProductUsage> byKey = new Map<String, ProductUsage>();
    for (Integration_Connector__mdt definition : [SELECT Connector_Key__c, Provider_Label__c FROM Integration_Connector__mdt WHERE Enabled__c = true ORDER BY Display_Order__c]) {
      String key = definition.Connector_Key__c.toLowerCase();
      if (filterKey != null && key != filterKey) continue;
      ProductUsage item = new ProductUsage(); item.connectorKey = key; item.label = definition.Provider_Label__c; byKey.put(key, item);
    }
    if (byKey.isEmpty() && filterKey != null) handled('Unsupported connector.');
    for (Connector_Instance__c instance : [SELECT Connector_Key__c, Entitlement_Status__c, Expiry_Date__c, Last_Entitlement_Refresh_At__c FROM Connector_Instance__c WHERE Connector_Key__c IN :byKey.keySet()]) {
      ProductUsage item = byKey.get(instance.Connector_Key__c.toLowerCase()); if (item == null) continue;
      item.subscriptionStatus = instance.Entitlement_Status__c; item.subscribed = instance.Entitlement_Status__c == 'Active' || instance.Entitlement_Status__c == 'Subscribed';
      item.expiryDate = instance.Expiry_Date__c; item.daysRemaining = instance.Expiry_Date__c == null ? null : Date.today().daysBetween(instance.Expiry_Date__c); item.lastUpdated = instance.Last_Entitlement_Refresh_At__c;
    }
    for (AggregateResult row : [SELECT Integration__c connector, Status__c statusValue, COUNT(Id) amount FROM Integration_Work_Item__c WHERE Integration__c IN :byKey.keySet() GROUP BY Integration__c, Status__c]) {
      ProductUsage item = byKey.get(String.valueOf(row.get('connector')).toLowerCase()); if (item == null) continue;
      String status = String.valueOf(row.get('statusValue')); Integer amount = Integer.valueOf(String.valueOf(row.get('amount')));
      if (status == IntegrationWorkService.STATUS_COMPLETED) item.syncedRecords += amount;
      if (status == IntegrationWorkService.STATUS_FAILED) item.errors += amount;
    }
    for (Integration_Usage_Summary__c summary : [SELECT Product_Key__c, Synced_Records__c, Error_Count__c, Endpoint_Usage__c, Last_Updated_At__c FROM Integration_Usage_Summary__c WHERE Product_Key__c IN :byKey.keySet()]) {
      ProductUsage item = byKey.get(summary.Product_Key__c.toLowerCase()); if (item == null) continue;
      item.endpointUsage = decimalToInteger(summary.Endpoint_Usage__c);
      item.lastUpdated = summary.Last_Updated_At__c == null ? item.lastUpdated : summary.Last_Updated_At__c;
    }
    for (Integration_Usage_Limit__mdt limitRow : [SELECT Product_Key__c, Synced_Record_Limit__c, Error_Limit__c, Endpoint_Limit__c FROM Integration_Usage_Limit__mdt]) {
      ProductUsage item = byKey.get(String.valueOf(limitRow.Product_Key__c).toLowerCase()); if (item == null) continue;
      item.syncedRecordLimit = decimalToInteger(limitRow.Synced_Record_Limit__c); item.errorLimit = decimalToInteger(limitRow.Error_Limit__c); item.endpointLimit = decimalToInteger(limitRow.Endpoint_Limit__c);
    }
    Report result = new Report();
    for (ProductUsage item : byKey.values()) {
      item.syncedPercent = percent(item.syncedRecords, item.syncedRecordLimit); item.errorPercent = percent(item.errors, item.errorLimit); item.endpointPercent = percent(item.endpointUsage, item.endpointLimit); result.products.add(item);
    }
    result.products.sort(new ProductUsageComparator()); return result;
  }

  /**
   * Returns a read-only snapshot of current connector health. It deliberately
   * does not create usage events, execute work, invoke a health probe, or
   * mutate schedule rows.
   */
  @AuraEnabled(cacheable=false)
  public static OperationalOverview getOperationalOverview(
    String sessionToken,
    String connectorKey
  ) {
    QuickbridgeAdminSecurity.requireSession(sessionToken);
    assertOperationalReadAccess();

    String filterKey = normalizedKey(connectorKey);
    Map<String, ConnectorOperationalRow> connectorsByKey =
      new Map<String, ConnectorOperationalRow>();
    Map<String, String> connectorByIntegrationType = new Map<String, String>();
    for (Integration_Connector__mdt definition : [
      SELECT Connector_Key__c, Provider_Label__c, Integration_Type__c
      FROM Integration_Connector__mdt
      WHERE Enabled__c = true
      ORDER BY Display_Order__c
    ]) {
      String keyValue = normalizedKey(definition.Connector_Key__c);
      if (filterKey != null && keyValue != filterKey) continue;

      ConnectorOperationalRow row = new ConnectorOperationalRow();
      row.connectorKey = keyValue;
      row.label = String.isBlank(definition.Provider_Label__c)
        ? definition.Connector_Key__c
        : definition.Provider_Label__c;
      connectorsByKey.put(keyValue, row);
      connectorByIntegrationType.put(normalizeLookup(definition.Integration_Type__c), keyValue);
      connectorByIntegrationType.put(normalizeLookup(definition.Provider_Label__c), keyValue);
      connectorByIntegrationType.put(normalizeLookup(keyValue), keyValue);
    }
    if (filterKey != null && connectorsByKey.isEmpty()) handled('Unsupported connector.');

    Set<String> connectorKeys = connectorsByKey.keySet();
    OperationalOverview result = new OperationalOverview();
    if (connectorKeys.isEmpty()) return result;

    Map<String, ConnectorReadinessService.Assessment> readinessByKey =
      ConnectorReadinessService.assessAll(connectorKeys, true);
    for (Connector_Instance__c instance : [
      SELECT Connector_Key__c, Active__c, Health_Status__c
      FROM Connector_Instance__c
      WHERE Connector_Key__c IN :connectorKeys
    ]) {
      ConnectorOperationalRow row = connectorsByKey.get(normalizedKey(instance.Connector_Key__c));
      if (row == null) continue;
      row.active = instance.Active__c == true;
      row.health = String.isBlank(instance.Health_Status__c)
        ? 'Unknown'
        : instance.Health_Status__c;
      ConnectorReadinessService.Assessment assessment = readinessByKey.get(row.connectorKey);
      row.ready = row.active && assessment != null && assessment.operationalReady;
    }

    for (AggregateResult aggregateRow : [
      SELECT Integration__c connector, Status__c statusValue, COUNT(Id) countValue,
        MAX(Completed_At__c) lastCompletedAt
      FROM Integration_Work_Item__c
      WHERE Integration__c IN :connectorKeys
      GROUP BY Integration__c, Status__c
    ]) {
      ConnectorOperationalRow row = connectorsByKey.get(
        normalizedKey((String) aggregateRow.get('connector'))
      );
      if (row == null) continue;
      Integer countValue = (Integer) aggregateRow.get('countValue');
      String statusValue = (String) aggregateRow.get('statusValue');
      if (statusValue == IntegrationWorkService.STATUS_COMPLETED) {
        row.completedWorkCount += countValue;
        Datetime completedAt = (Datetime) aggregateRow.get('lastCompletedAt');
        if (completedAt != null && (
          row.lastSuccessfulWorkAt == null || completedAt > row.lastSuccessfulWorkAt
        )) {
          row.lastSuccessfulWorkAt = completedAt;
        }
      } else if (statusValue == IntegrationWorkService.STATUS_PENDING) {
        row.pendingWorkCount += countValue;
      } else if (statusValue == IntegrationWorkService.STATUS_PROCESSING) {
        row.processingWorkCount += countValue;
      } else if (statusValue == IntegrationWorkService.STATUS_RETRY) {
        row.retryWorkCount += countValue;
      } else if (statusValue == IntegrationWorkService.STATUS_FAILED) {
        row.failedWorkCount += countValue;
      }
    }

    Datetime overdueCutoff = System.now().addMinutes(-5);
    for (Scheduled_Integration_Job__c scheduleRow : [
      SELECT Integration_Type__c, Status__c, Next_Run_At__c
      FROM Scheduled_Integration_Job__c
      WHERE Status__c != 'Deleted'
    ]) {
      String keyValue = connectorByIntegrationType.get(
        normalizeLookup(scheduleRow.Integration_Type__c)
      );
      ConnectorOperationalRow row = connectorsByKey.get(keyValue);
      if (row == null) continue;

      Boolean isPaused = scheduleRow.Status__c == 'Paused';
      Boolean isOverdue = !isPaused && scheduleRow.Next_Run_At__c != null &&
        scheduleRow.Next_Run_At__c < overdueCutoff;
      if (isOverdue) {
        row.overdueScheduleCount++;
        row.scheduleState = 'Overdue';
      } else if (row.scheduleState != 'Overdue' && (
        row.scheduleState == 'Not scheduled' || scheduleRow.Status__c == 'Ready'
      )) {
        row.scheduleState = scheduleRow.Status__c;
      }
      if (!isPaused && scheduleRow.Next_Run_At__c != null && (
        row.nextScheduledRunAt == null || scheduleRow.Next_Run_At__c < row.nextScheduledRunAt
      )) {
        row.nextScheduledRunAt = scheduleRow.Next_Run_At__c;
      }
    }

    for (ConnectorOperationalRow row : connectorsByKey.values()) {
      if (row.active) {
        result.activeConnectorCount++;
        if (row.ready) result.readyConnectorCount++;
        else result.attentionConnectorCount++;
      }
      result.completedWorkCount += row.completedWorkCount;
      result.backlogCount += row.pendingWorkCount + row.processingWorkCount + row.retryWorkCount;
      result.failedWorkCount += row.failedWorkCount;
      result.overdueScheduleCount += row.overdueScheduleCount;
      if (row.lastSuccessfulWorkAt != null && (
        result.lastSuccessfulWorkAt == null ||
        row.lastSuccessfulWorkAt > result.lastSuccessfulWorkAt
      )) {
        result.lastSuccessfulWorkAt = row.lastSuccessfulWorkAt;
      }
      result.connectors.add(row);
    }
    result.connectors.sort(new ConnectorOperationalRowComparator());
    return result;
  }

  private class ProductUsageComparator implements Comparator<ProductUsage> { public Integer compare(ProductUsage leftValue, ProductUsage rightValue){ return leftValue.label.toLowerCase().compareTo(rightValue.label.toLowerCase()); } }
  private class ConnectorOperationalRowComparator implements Comparator<ConnectorOperationalRow> {
    public Integer compare(ConnectorOperationalRow leftValue, ConnectorOperationalRow rightValue) {
      return leftValue.label.toLowerCase().compareTo(rightValue.label.toLowerCase());
    }
  }

  private static void assertOperationalReadAccess() {
    if (Test.isRunningTest() && bypassReadAccessForTests) return;
    if (
      !Schema.sObjectType.Connector_Instance__c.isAccessible() ||
      !Schema.sObjectType.Connector_Instance__c.fields.Connector_Key__c.isAccessible() ||
      !Schema.sObjectType.Connector_Instance__c.fields.Active__c.isAccessible() ||
      !Schema.sObjectType.Connector_Instance__c.fields.Health_Status__c.isAccessible() ||
      !Schema.sObjectType.Integration_Work_Item__c.isAccessible() ||
      !Schema.sObjectType.Integration_Work_Item__c.fields.Integration__c.isAccessible() ||
      !Schema.sObjectType.Integration_Work_Item__c.fields.Status__c.isAccessible() ||
      !Schema.sObjectType.Integration_Work_Item__c.fields.Completed_At__c.isAccessible() ||
      !Schema.sObjectType.Scheduled_Integration_Job__c.isAccessible() ||
      !Schema.sObjectType.Scheduled_Integration_Job__c.fields.Integration_Type__c.isAccessible() ||
      !Schema.sObjectType.Scheduled_Integration_Job__c.fields.Status__c.isAccessible() ||
      !Schema.sObjectType.Scheduled_Integration_Job__c.fields.Next_Run_At__c.isAccessible()
    ) {
      handled('Quickbridge operational reporting read access is required.');
    }
  }

  private static String normalizedKey(String value) {
    return String.isBlank(value) ? null : value.trim().toLowerCase();
  }

  private static String normalizeLookup(String value) {
    return String.isBlank(value)
      ? ''
      : value.trim().toLowerCase().replaceAll('[^a-z0-9]', '');
  }

  private static Integer decimalToInteger(Decimal value){ return value == null ? 0 : value.intValue(); }
  private static Decimal percent(Integer value, Integer limitValue){ if(limitValue==null||limitValue<=0)return 0; return Math.min(100, (Decimal.valueOf(value)*100)/limitValue).setScale(1); }
  private static void handled(String message){ AuraHandledException error=new AuraHandledException(message); error.setMessage(message); throw error; }
}