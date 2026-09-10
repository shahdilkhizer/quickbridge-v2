/** Reserve transport capacity in a transaction before the callout transaction. */
public inherited sharing class GenericResourceRateLimit {
  public static Boolean reserve(String connectorKey, Integer count) {
    GenericResourceContract.require(count > 0 && count <= 30, 'Resource requests must be dispatched in groups of at most 30.');
    return reserveMany(new Map<String,Integer>{connectorKey.toLowerCase()=>count}).get(connectorKey.toLowerCase()) == count;
  }
  public static Map<String,Integer> reserveMany(Map<String,Integer> requested) {
    Map<String,Integer> admitted = new Map<String,Integer>();
    if (requested.isEmpty()) return admitted;
    List<Connector_Instance__c> instances = [SELECT Id, Connector_Key__c, Rate_Window_Start__c, Rate_Window_Used__c
      FROM Connector_Instance__c WHERE Connector_Key__c IN :requested.keySet() FOR UPDATE];
    List<Connector_Instance__c> changes = new List<Connector_Instance__c>();
    for (Connector_Instance__c row : instances) {
      String key = row.Connector_Key__c.toLowerCase();
      GenericResourceContract.require(!admitted.containsKey(key), 'Resource synchronization requires one instance per connector.');
      if (row.Rate_Window_Start__c == null || row.Rate_Window_Start__c.addSeconds(60) <= System.now()) {
        row.Rate_Window_Start__c = System.now(); row.Rate_Window_Used__c = 0;
      }
      Integer used = row.Rate_Window_Used__c == null ? 0 : row.Rate_Window_Used__c.intValue();
      Integer count = Math.max(0, Math.min(requested.get(key), 30-used));
      admitted.put(key, count); row.Rate_Window_Used__c = used + count; changes.add(row);
    }
    GenericResourceContract.require(admitted.size() == requested.size(), 'Resource connector instance is missing.');
    update changes;
    return admitted;
  }
}