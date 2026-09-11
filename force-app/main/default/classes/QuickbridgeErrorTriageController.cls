public with sharing class QuickbridgeErrorTriageController {
  private static final Integer PAGE_LIMIT = 50;
  @TestVisible
  private static Boolean bypassReadinessForTests = false;
  public class TriagePage {
    @AuraEnabled
    public List<Row> rows = new List<Row>();
    @AuraEnabled
    public String nextCursor;
    @AuraEnabled
    public Integer pageSize;
  }
  public class Row {
    @AuraEnabled
    public Id id;
    @AuraEnabled
    public String connectorKey;
    @AuraEnabled
    public String operationKey;
    @AuraEnabled
    public String signature;
    @AuraEnabled
    public Integer occurrenceCount;
    @AuraEnabled
    public String category;
    @AuraEnabled
    public String message;
    @AuraEnabled
    public String sourceObject;
    @AuraEnabled
    public String sourceRecordId;
    @AuraEnabled
    public String recordUrl;
    @AuraEnabled
    public Boolean retryable;
    @AuraEnabled
    public Integer retryCount;
    @AuraEnabled
    public String retryStatus;
    @AuraEnabled
    public Integer httpStatusCode;
    @AuraEnabled
    public Datetime createdAt;
    @AuraEnabled
    public String retryHistory;
    @AuraEnabled
    public String retryDisabledReason;
    @AuraEnabled
    public String routeScreen;
  }
  public class Filter {
    public String category;
    public String sourceObject;
    public Datetime fromDate;
    public Datetime toDate;
    public String retryStatus;
  }
  public class RetryResult {
    @AuraEnabled
    public Id errorLogId;
    @AuraEnabled
    public Boolean successful;
    @AuraEnabled
    public String message;
  }

  @AuraEnabled(cacheable=false)
  public static TriagePage getPage(
    String sessionToken,
    String connectorKey,
    String filterJson,
    String cursor,
    Integer pageSize,
    String mode
  ) {
    QuickbridgeAdminSecurity.requireSession(sessionToken);
    String key = requireConnector(connectorKey);
    Filter filter = parseFilter(filterJson);
    Integer safeSize = pageSize == null
      ? 20
      : Math.max(1, Math.min(PAGE_LIMIT, pageSize));
    Datetime cursorDate;
    Id cursorId;
    if (String.isNotBlank(cursor)) {
      try {
        List<String> p = EncodingUtil.base64Decode(cursor)
          .toString()
          .split('\\|');
        cursorDate = Datetime.newInstance(Long.valueOf(p[0]));
        cursorId = (Id) p[1];
      } catch (Exception e) {
        handled('The pagination cursor is invalid.');
      }
    }
    String fallbackPattern = '%' + key + '%';
    Boolean retryOnly = mode == 'Retry';
    Boolean pendingOnly = mode == 'Pending';
    String category = filter.category;
    String sourceObject = filter.sourceObject;
    Datetime fromDate = filter.fromDate;
    Datetime toDate = filter.toDate;
    String retryStatus = filter.retryStatus;
    Map<String, Object> binds = new Map<String, Object>{
      'connectorKey' => key,
      'fallbackPattern' => fallbackPattern
    };
    List<String> conditions = new List<String>{
      '(Connector_Key__c = :connectorKey OR (Connector_Key__c = null AND External_Reference__c LIKE :fallbackPattern))'
    };
    if (cursorDate != null) {
      conditions.add(
        '(CreatedDate < :cursorDate OR (CreatedDate = :cursorDate AND Id < :cursorId))'
      );
      binds.put('cursorDate', cursorDate);
      binds.put('cursorId', cursorId);
    }
    if (category != null) {
      conditions.add('Error_Category__c = :category');
      binds.put('category', category);
    }
    if (sourceObject != null) {
      conditions.add('Source_Object__c = :sourceObject');
      binds.put('sourceObject', sourceObject);
    }
    if (fromDate != null) {
      conditions.add('CreatedDate >= :fromDate');
      binds.put('fromDate', fromDate);
    }
    if (toDate != null) {
      conditions.add('CreatedDate <= :toDate');
      binds.put('toDate', toDate);
    }
    if (retryStatus != null) {
      conditions.add('Retry_Status__c = :retryStatus');
      binds.put('retryStatus', retryStatus);
    }
    if (retryOnly)
      conditions.add('Is_Retryable__c = true');
    if (pendingOnly)
      conditions.add(
        '(Is_Retryable__c = false AND Retry_Status__c != \'Success\')'
      );
    String query =
      'SELECT Id,Connector_Key__c,Operation_Key__c,Error_Signature__c,Error_Category__c,Error_Message__c,Source_Object__c,Source_Record_Id__c,Is_Retryable__c,Retry_Count__c,Retry_Status__c,Http_Status_Code__c,Retry_History_Notes__c,CreatedDate,External_Reference__c FROM Error_Log__c WHERE ' +
      String.join(conditions, ' AND ') +
      ' ORDER BY CreatedDate DESC, Id DESC LIMIT ' +
      safeSize;
    List<Error_Log__c> source = Database.queryWithBinds(
      query,
      binds,
      AccessLevel.USER_MODE
    );
    TriagePage result = new TriagePage();
    result.pageSize = safeSize;
    Map<String, Row> groups = new Map<String, Row>();
    for (Error_Log__c item : source) {
      String groupKey = String.isBlank(item.Error_Signature__c)
        ? String.valueOf(item.Id)
        : item.Error_Signature__c;
      if (!groups.containsKey(groupKey))
        groups.put(groupKey, toRow(item));
      else
        groups.get(groupKey).occurrenceCount++;
    }
    result.rows.addAll(groups.values());
    if (source.size() == safeSize) {
      Error_Log__c last = source[source.size() - 1];
      result.nextCursor = EncodingUtil.base64Encode(
        Blob.valueOf(String.valueOf(last.CreatedDate.getTime()) + '|' + last.Id)
      );
    }
    return result;
  }

  @AuraEnabled
  public static List<RetryResult> retry(
    String sessionToken,
    List<Id> errorLogIds
  ) {
    QuickbridgeAdminSecurity.requireRun();
    QuickbridgeAdminSecurity.requireSession(sessionToken);
    if (errorLogIds == null || errorLogIds.isEmpty())
      handled('Select at least one retryable error.');
    Set<Id> requested = new Set<Id>(errorLogIds);
    if (requested.size() > 50)
      handled('Select no more than 50 errors.');
    List<Error_Log__c> errors = [
      SELECT
        Id,
        Connector_Key__c,
        Operation_Key__c,
        Is_Retryable__c,
        Source_Record_Id__c,
        Source_Object__c,
        External_Reference__c
      FROM Error_Log__c
      WHERE Id IN :requested
    ];
    Map<Id, RetryResult> resultsByError = new Map<Id, RetryResult>();
    Set<String> connectors = new Set<String>();
    Set<String> sourceIds = new Set<String>();
    for (Error_Log__c errorRow : errors) {
      RetryResult result = new RetryResult();
      result.errorLogId = errorRow.Id;
      result.successful = false;
      resultsByError.put(errorRow.Id, result);
      if (errorRow.Is_Retryable__c != true) {
        result.message = 'This error is terminal and cannot be retried automatically.';
        continue;
      }
      String key = resolveConnector(errorRow);
      connectors.add(key);
      sourceIds.add(errorRow.Source_Record_Id__c);
    }
    for (String key : connectors) {
      if (!Test.isRunningTest() || !bypassReadinessForTests) {
        ConnectorReadinessService.Assessment ready = ConnectorReadinessService.assess(
          key,
          true
        );
        if (!ready.operationalReady)
          handled(String.join(ready.issues, ' '));
      }
    }
    Map<String, Id> workByKey = new Map<String, Id>();
    for (Integration_Work_Item__c item : [
      SELECT
        Id,
        Integration__c,
        Operation__c,
        Source_Object__c,
        Source_Record_Id__c
      FROM Integration_Work_Item__c
      WHERE Integration__c IN :connectors AND Source_Record_Id__c IN :sourceIds
      ORDER BY CreatedDate DESC
    ]) {
      String workKey =
        item.Integration__c +
        '|' +
        item.Operation__c +
        '|' +
        item.Source_Object__c +
        '|' +
        item.Source_Record_Id__c;
      if (!workByKey.containsKey(workKey))
        workByKey.put(workKey, item.Id);
    }
    Map<Id, Id> errorByWork = new Map<Id, Id>();
    for (Error_Log__c errorRow : errors) {
      RetryResult result = resultsByError.get(errorRow.Id);
      if (String.isNotBlank(result.message))
        continue;
      Id workId = workByKey.get(
        resolveConnector(errorRow) +
          '|' +
          errorRow.Operation_Key__c +
          '|' +
          errorRow.Source_Object__c +
          '|' +
          errorRow.Source_Record_Id__c
      );
      if (workId == null) {
        result.message = 'The original work item could not be found.';
        continue;
      }
      errorByWork.put(workId, errorRow.Id);
    }
    for (
      IntegrationWorkService.ManualRetryResult workResult : IntegrationWorkService.manualRetry(
        new List<Id>(errorByWork.keySet())
      )
    ) {
      RetryResult result = resultsByError.get(
        errorByWork.get(workResult.workItemId)
      );
      result.successful = workResult.successful;
      result.message = IntegrationErrorLogService.sanitizeForUser(
        workResult.message
      );
    }
    List<RetryResult> results = new List<RetryResult>();
    for (Id requestedId : errorLogIds)
      if (resultsByError.containsKey(requestedId))
        results.add(resultsByError.get(requestedId));
    QuickbridgeAdminSecurity.audit(
      'ERROR_BULK_REPLAY',
      String.join(new List<String>(connectors), ','),
      'Completed',
      String.valueOf(results.size()),
      null
    );
    return results;
  }

  private static Filter parseFilter(String value) {
    if (String.isBlank(value))
      return new Filter();
    try {
      Filter result = (Filter) JSON.deserialize(value, Filter.class);
      if (
        result.fromDate != null &&
        result.toDate != null &&
        result.fromDate > result.toDate
      )
        handled('The error date window is invalid.');
      return result;
    } catch (AuraHandledException e) {
      throw e;
    } catch (Exception e) {
      handled('Error filters are malformed.');
      return null;
    }
  }
  private static Row toRow(Error_Log__c item) {
    Row row = new Row();
    row.id = item.Id;
    row.connectorKey = item.Connector_Key__c;
    row.operationKey = item.Operation_Key__c;
    row.signature = item.Error_Signature__c;
    row.occurrenceCount = 1;
    row.category = item.Error_Category__c;
    row.message = IntegrationErrorLogService.sanitizeForUser(
      item.Error_Message__c
    );
    row.sourceObject = item.Source_Object__c;
    row.sourceRecordId = item.Source_Record_Id__c;
    row.recordUrl = validId(item.Source_Record_Id__c)
      ? '/' + item.Source_Record_Id__c
      : null;
    row.retryable = item.Is_Retryable__c;
    row.retryCount = item.Retry_Count__c == null
      ? 0
      : item.Retry_Count__c.intValue();
    row.retryStatus = item.Retry_Status__c;
    row.httpStatusCode = item.Http_Status_Code__c == null
      ? null
      : item.Http_Status_Code__c.intValue();
    row.createdAt = item.CreatedDate;
    row.retryHistory = IntegrationErrorLogService.sanitizeForUser(
      item.Retry_History_Notes__c
    );
    row.retryDisabledReason = item.Is_Retryable__c == true
      ? null
      : 'Provider or platform classified this failure as terminal.';
    String category = String.valueOf(item.Error_Category__c).toLowerCase();
    row.routeScreen = category.contains('auth') || category.contains('config')
      ? 'settings'
      : category.contains('mapping') || category.contains('schema')
          ? 'mapping'
          : category.contains('schedule') || category.contains('lease')
              ? 'scheduler'
              : null;
    return row;
  }
  private static Boolean validId(String value) {
    try {
      return String.isNotBlank(value) && ((Id) value) != null;
    } catch (Exception e) {
      return false;
    }
  }
  private static String resolveConnector(Error_Log__c row) {
    if (String.isNotBlank(row.Connector_Key__c))
      return row.Connector_Key__c.toLowerCase();
    String value = String.valueOf(row.External_Reference__c).toLowerCase();
    for (Integration_Connector__mdt connector : [
      SELECT Connector_Key__c
      FROM Integration_Connector__mdt
      WHERE Enabled__c = TRUE
    ])
      if (value.contains(connector.Connector_Key__c.toLowerCase()))
        return connector.Connector_Key__c.toLowerCase();
    handled('The error connector could not be resolved.');
    return null;
  }
  private static String requireConnector(String connectorKey) {
    String key = String.isBlank(connectorKey)
      ? null
      : connectorKey.trim().toLowerCase();
    if (
      [
        SELECT COUNT()
        FROM Integration_Connector__mdt
        WHERE Connector_Key__c = :key AND Enabled__c = TRUE
      ] == 0
    )
      handled('Unsupported connector.');
    return key;
  }
  private static void handled(String message) {
    AuraHandledException error = new AuraHandledException(message);
    error.setMessage(message);
    throw error;
  }
}