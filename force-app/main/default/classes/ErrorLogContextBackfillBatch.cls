public without sharing class ErrorLogContextBackfillBatch implements Database.Batchable<SObject> {
  public Database.QueryLocator start(Database.BatchableContext context) {
    return Database.getQueryLocator(
      [
        SELECT
          Id,
          External_Reference__c,
          Error_Category__c,
          Error_Message__c,
          Http_Status_Code__c,
          Connector_Key__c,
          Operation_Key__c,
          Error_Signature__c
        FROM Error_Log__c
        WHERE Connector_Key__c = NULL OR Error_Signature__c = NULL
      ]
    );
  }

  public void execute(
    Database.BatchableContext context,
    List<Error_Log__c> scope
  ) {
    Set<Id> workIds = new Set<Id>();
    for (Error_Log__c row : scope) {
      String prefix = String.valueOf(row.External_Reference__c)
        .substringBefore(':');
      try {
        if (String.isNotBlank(prefix))
          workIds.add((Id) prefix);
      } catch (Exception ignored) {
      }
    }
    Map<Id, Integration_Work_Item__c> workById = workIds.isEmpty()
      ? new Map<Id, Integration_Work_Item__c>()
      : new Map<Id, Integration_Work_Item__c>(
          [
            SELECT Id, Integration__c, Operation__c
            FROM Integration_Work_Item__c
            WHERE Id IN :workIds
          ]
        );
    for (Error_Log__c row : scope) {
      String prefix = String.valueOf(row.External_Reference__c)
        .substringBefore(':');
      Integration_Work_Item__c work;
      try {
        work = workById.get((Id) prefix);
      } catch (Exception ignored) {
      }
      if (work != null) {
        row.Connector_Key__c = work.Integration__c;
        row.Operation_Key__c = work.Operation__c;
      } else if (
        String.valueOf(row.External_Reference__c).startsWith('inbound:')
      ) {
        List<String> pieces = row.External_Reference__c.split(':');
        if (pieces.size() > 2) {
          row.Connector_Key__c = pieces[1];
          row.Operation_Key__c = pieces[2];
        }
      }
      row.Error_Signature__c = IntegrationErrorLogService.signatureFor(
        row.Connector_Key__c,
        row.Operation_Key__c,
        row.Error_Category__c,
        row.Error_Message__c,
        row.Http_Status_Code__c == null
          ? null
          : row.Http_Status_Code__c.intValue()
      );
    }
    Database.update(scope, false);
  }

  public void finish(Database.BatchableContext context) {
  }
}