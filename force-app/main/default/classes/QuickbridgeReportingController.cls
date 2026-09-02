public with sharing class QuickbridgeReportingController {
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

  private class ProductUsageComparator implements Comparator<ProductUsage> { public Integer compare(ProductUsage leftValue, ProductUsage rightValue){ return leftValue.label.toLowerCase().compareTo(rightValue.label.toLowerCase()); } }
  private static Integer decimalToInteger(Decimal value){ return value == null ? 0 : value.intValue(); }
  private static Decimal percent(Integer value, Integer limitValue){ if(limitValue==null||limitValue<=0)return 0; return Math.min(100, (Decimal.valueOf(value)*100)/limitValue).setScale(1); }
  private static void handled(String message){ AuraHandledException error=new AuraHandledException(message); error.setMessage(message); throw error; }
}