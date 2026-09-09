public with sharing class QuickbridgeErrorController {
  public class ErrorPage { @AuraEnabled public List<ErrorView> rows=new List<ErrorView>(); @AuraEnabled public Integer totalCount; @AuraEnabled public Integer pageNumber; @AuraEnabled public Integer pageSize; }
  public class ErrorView {
    @AuraEnabled public Id id; @AuraEnabled public String category; @AuraEnabled public String message; @AuraEnabled public String sourceObject;
    @AuraEnabled public String sourceRecordId; @AuraEnabled public String recordUrl; @AuraEnabled public Boolean retryable; @AuraEnabled public Integer retryCount;
    @AuraEnabled public String retryStatus; @AuraEnabled public Integer httpStatusCode; @AuraEnabled public Datetime createdAt; @AuraEnabled public String retryDisabledReason;
  }

  @AuraEnabled(cacheable=false)
  public static ErrorPage getErrors(String sessionToken, String connectorKey, Integer pageNumber, Integer pageSize, String mode) {
    QuickbridgeAdminSecurity.requireSession(sessionToken);
    String key = requireConnector(connectorKey); Integer safePage = pageNumber == null || pageNumber < 1 ? 1 : pageNumber; Integer safeSize = pageSize == null ? 10 : Math.max(1, Math.min(50, pageSize));
    Boolean retryMode = mode == 'Retry'; Boolean pendingMode = mode == 'Pending'; String referencePattern = '%' + key + '%';
    Set<String> workItemPrefixes = new Set<String>();
    for (Integration_Work_Item__c wi : [SELECT Id FROM Integration_Work_Item__c WHERE Integration__c = :key LIMIT 2000]) {
      workItemPrefixes.add(String.valueOf(wi.Id) + ':%');
    }
    List<Error_Log__c> candidates;
    if (workItemPrefixes.isEmpty()) {
      candidates = [SELECT Id, Error_Category__c, Error_Message__c, Source_Object__c, Source_Record_Id__c, Is_Retryable__c, Retry_Count__c, Retry_Status__c, Http_Status_Code__c, CreatedDate, External_Reference__c FROM Error_Log__c WHERE External_Reference__c LIKE :referencePattern ORDER BY CreatedDate DESC LIMIT 1000];
    } else {
      candidates = [SELECT Id, Error_Category__c, Error_Message__c, Source_Object__c, Source_Record_Id__c, Is_Retryable__c, Retry_Count__c, Retry_Status__c, Http_Status_Code__c, CreatedDate, External_Reference__c FROM Error_Log__c WHERE External_Reference__c LIKE :referencePattern OR External_Reference__c LIKE :workItemPrefixes ORDER BY CreatedDate DESC LIMIT 1000];
    }
    List<Error_Log__c> filtered = new List<Error_Log__c>();
    for (Error_Log__c row : candidates) {
      if (retryMode && row.Is_Retryable__c != true) continue;
      if (pendingMode && (row.Is_Retryable__c == true || row.Retry_Status__c == 'Success')) continue;
      filtered.add(row);
    }
    ErrorPage result=new ErrorPage(); result.totalCount=filtered.size(); result.pageNumber=safePage; result.pageSize=safeSize;
    Integer startIndex=(safePage-1)*safeSize; Integer endIndex=Math.min(startIndex+safeSize, filtered.size());
    for(Integer index=startIndex; index<endIndex; index++) result.rows.add(toView(filtered[index])); return result;
  }

  @AuraEnabled
  public static void replayError(String sessionToken, Id errorLogId) {
    QuickbridgeAdminSecurity.requireRun(); QuickbridgeAdminSecurity.requireSession(sessionToken);
    if(errorLogId==null) handled('Error log is required.');
    Error_Log__c errorRow=[SELECT Id, Is_Retryable__c, Retry_Status__c, Source_Record_Id__c, Source_Object__c, External_Reference__c FROM Error_Log__c WHERE Id=:errorLogId LIMIT 1];
    if(errorRow.Is_Retryable__c!=true) handled('This error is terminal and cannot be retried automatically.');
    String connectorKey=connectorFromReference(errorRow.External_Reference__c);
    ConnectorReadinessService.Assessment readiness=ConnectorReadinessService.assess(connectorKey,true); if(!readiness.operationalReady) handled(String.join(readiness.issues,' '));
    List<Integration_Work_Item__c> work=[SELECT Id FROM Integration_Work_Item__c WHERE Integration__c=:connectorKey AND Source_Object__c=:errorRow.Source_Object__c AND Source_Record_Id__c=:errorRow.Source_Record_Id__c ORDER BY CreatedDate DESC LIMIT 1];
    if(work.isEmpty()) handled('The original work item could not be found.');
    IntegrationWorkService.manualRetry(work[0].Id); QuickbridgeAdminSecurity.audit('ERROR_REPLAY',connectorKey,'Queued',null,errorLogId);
  }

  private static ErrorView toView(Error_Log__c row){ ErrorView view=new ErrorView(); view.id=row.Id; view.category=row.Error_Category__c; view.message=IntegrationErrorLogService.sanitizeForUser(row.Error_Message__c); view.sourceObject=row.Source_Object__c; view.sourceRecordId=row.Source_Record_Id__c; view.recordUrl=String.isBlank(row.Source_Record_Id__c)?null:'/'+row.Source_Record_Id__c; view.retryable=row.Is_Retryable__c; view.retryCount=row.Retry_Count__c==null?0:row.Retry_Count__c.intValue(); view.retryStatus=row.Retry_Status__c; view.httpStatusCode=row.Http_Status_Code__c==null?null:row.Http_Status_Code__c.intValue(); view.createdAt=row.CreatedDate; view.retryDisabledReason=row.Is_Retryable__c==true?null:'Provider or platform classified this failure as terminal.'; return view; }
  private static String requireConnector(String connectorKey){ String key=String.isBlank(connectorKey)?null:connectorKey.trim().toLowerCase(); if([SELECT COUNT() FROM Integration_Connector__mdt WHERE Connector_Key__c=:key AND Enabled__c=true]==0)handled('Unsupported connector.'); return key; }
  private static String connectorFromReference(String reference){
    String value=String.valueOf(reference).toLowerCase();
    for(Integration_Connector__mdt row:[SELECT Connector_Key__c FROM Integration_Connector__mdt WHERE Enabled__c=true]) {
      if(value.contains(row.Connector_Key__c.toLowerCase())) return row.Connector_Key__c.toLowerCase();
    }
    if (String.isNotBlank(reference) && reference.contains(':')) {
      String potentialWorkId = reference.substringBefore(':');
      if (potentialWorkId.length() >= 15 && potentialWorkId.length() <= 18) {
        List<Integration_Work_Item__c> items = [SELECT Integration__c FROM Integration_Work_Item__c WHERE Id = :potentialWorkId LIMIT 1];
        if (!items.isEmpty() && String.isNotBlank(items[0].Integration__c)) {
          return items[0].Integration__c.toLowerCase();
        }
      }
    }
    handled('The error connector could not be resolved.');
    return null;
  }
  private static void handled(String message){ AuraHandledException error=new AuraHandledException(message); error.setMessage(message); throw error; }
}