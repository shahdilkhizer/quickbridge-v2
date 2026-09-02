public without sharing class QuickbridgeUsageService {
  private static final Set<String> METRICS = new Set<String>{ 'Synced', 'Error', 'Endpoint' };
  public static void record(String uniqueKey, String connectorKey, String metric, Integer amount) {
    if (String.isBlank(uniqueKey) || String.isBlank(connectorKey) || !METRICS.contains(metric)) return;
    Integration_Usage_Event__c eventRow = new Integration_Usage_Event__c(
      Unique_Key__c = uniqueKey.left(255), Product_Key__c = connectorKey.trim().toLowerCase(), Metric__c = metric,
      Count__c = amount == null ? 1 : Math.max(0, amount), Occurred_At__c = System.now(), Processed__c = false, Processing_Status__c = 'Pending'
    );
    Database.upsert(eventRow, Integration_Usage_Event__c.Fields.Unique_Key__c, false);
  }

  @future
  public static void aggregatePending() {
    List<Integration_Usage_Event__c> rows = [SELECT Id, Product_Key__c, Metric__c, Count__c FROM Integration_Usage_Event__c WHERE Processed__c = false AND Processing_Status__c IN ('Pending','Failed') LIMIT 500 FOR UPDATE];
    if (rows.isEmpty()) return;
    Set<String> keys = new Set<String>(); for (Integration_Usage_Event__c row : rows) keys.add(row.Product_Key__c);
    Map<String, Integration_Usage_Summary__c> summaryByKey = new Map<String, Integration_Usage_Summary__c>();
    for (Integration_Usage_Summary__c summary : [SELECT Id, Product_Key__c, Synced_Records__c, Error_Count__c, Endpoint_Usage__c FROM Integration_Usage_Summary__c WHERE Product_Key__c IN :keys FOR UPDATE]) summaryByKey.put(summary.Product_Key__c, summary);
    for (Integration_Usage_Event__c row : rows) {
      Integration_Usage_Summary__c summary = summaryByKey.get(row.Product_Key__c);
      if (summary == null) { summary = new Integration_Usage_Summary__c(Name=row.Product_Key__c, Product_Key__c=row.Product_Key__c, Synced_Records__c=0, Error_Count__c=0, Endpoint_Usage__c=0); summaryByKey.put(row.Product_Key__c, summary); }
      Decimal amount = row.Count__c == null ? 0 : row.Count__c;
      if (row.Metric__c == 'Synced') summary.Synced_Records__c += amount;
      if (row.Metric__c == 'Error') summary.Error_Count__c += amount;
      if (row.Metric__c == 'Endpoint') summary.Endpoint_Usage__c += amount;
      summary.Last_Updated_At__c = System.now(); row.Processed__c=true; row.Processing_Status__c='Processed'; row.Processed_At__c=System.now();
    }
    Database.upsert(summaryByKey.values(), Integration_Usage_Summary__c.Fields.Product_Key__c, false); Database.update(rows, false);
  }
}