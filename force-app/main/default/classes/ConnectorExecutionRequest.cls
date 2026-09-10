public inherited sharing class ConnectorExecutionRequest {
  public static final String DIRECTION_INBOUND = 'Inbound';
  public static final String DIRECTION_OUTBOUND = 'Outbound';

  public String connectorKey { get; set; }
  public String operationKey { get; set; }
  public String direction { get; set; }
  public String salesforceObject { get; set; }
  public String externalEntity { get; set; }
  public List<Id> recordIds { get; set; }
  public String cursor { get; set; }
  public Datetime sinceValue { get; set; }
  public Datetime syncStartedAt { get; set; }
  public Boolean initialSync { get; set; }
  public Integer scopeSize { get; set; }
  public String payload { get; set; }
  public String correlationKey { get; set; }
  public Id scheduleId { get; set; }
  public Id workItemId { get; set; }
  public String leaseToken { get; set; }
  public Integer pageNumber { get; set; }
  public Integer retryAttempt { get; set; }

  public ConnectorExecutionRequest() {
    recordIds = new List<Id>();
    initialSync = false;
    scopeSize = 50;
    pageNumber = 1;
    retryAttempt = 0;
  }

  public ConnectorExecutionRequest validate() {
    GenericIntegrationRuntime.OperationDefinition definition =
      GenericIntegrationRuntime.resolve(this);
    GenericIntegrationRuntime.validateRequestLimits(this);
    validateRecordIds(definition);
    return this;
  }

  public ConnectorExecutionRequest normalizedCopy() {
    GenericIntegrationRuntime.OperationDefinition definition =
      GenericIntegrationRuntime.resolve(this);
    ConnectorExecutionRequest copyValue = copyOf(this);
    copyValue.connectorKey = definition.connectorKey;
    copyValue.operationKey = definition.operationKey;
    copyValue.direction = GenericIntegrationRuntime.normalizeDirectionForHandler(
      direction
    );
    copyValue.salesforceObject = definition.salesforceObject;
    copyValue.externalEntity = definition.externalEntity;
    copyValue.recordIds = recordIds == null
      ? new List<Id>()
      : new List<Id>(recordIds);
    GenericIntegrationRuntime.validateRequestLimits(copyValue);
    copyValue.validateRecordIds(definition);
    return copyValue;
  }

  public String operationIdentity() {
    GenericIntegrationRuntime.OperationDefinition definition =
      GenericIntegrationRuntime.resolve(this);
    return definition.identity(direction);
  }

  private static ConnectorExecutionRequest copyOf(
    ConnectorExecutionRequest source
  ) {
    ConnectorExecutionRequest copyValue = new ConnectorExecutionRequest();
    copyValue.connectorKey = source.connectorKey;
    copyValue.operationKey = source.operationKey;
    copyValue.direction = source.direction;
    copyValue.salesforceObject = source.salesforceObject;
    copyValue.externalEntity = source.externalEntity;
    copyValue.cursor = source.cursor;
    copyValue.sinceValue = source.sinceValue;
    copyValue.syncStartedAt = source.syncStartedAt;
    copyValue.initialSync = source.initialSync;
    copyValue.scopeSize = source.scopeSize;
    copyValue.payload = source.payload;
    copyValue.correlationKey = source.correlationKey;
    copyValue.scheduleId = source.scheduleId;
    copyValue.workItemId = source.workItemId;
    copyValue.leaseToken = source.leaseToken;
    copyValue.pageNumber = source.pageNumber;
    copyValue.retryAttempt = source.retryAttempt;
    copyValue.recordIds = source.recordIds == null
      ? new List<Id>()
      : new List<Id>(source.recordIds);
    return copyValue;
  }

  private void validateRecordIds(
    GenericIntegrationRuntime.OperationDefinition definition
  ) {
    if (
      recordIds == null ||
      recordIds.isEmpty() ||
      String.isBlank(definition.salesforceObject)
    ) {
      return;
    }
    Schema.SObjectType expectedType = resolveSObjectType(
      definition.salesforceObject
    );
    if (expectedType == null) {
      throw new ConnectorExecutionRequestException(
        'The configured Salesforce object is unavailable.'
      );
    }
    for (Id recordId : recordIds) {
      if (recordId == null || recordId.getSObjectType() != expectedType) {
        throw new ConnectorExecutionRequestException(
          'A record ID does not belong to the configured Salesforce object.'
        );
      }
    }
  }

  public static Schema.SObjectType resolveSObjectType(String configuredObject) {
    Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();
    Schema.SObjectType exactType = globalDescribe.get(configuredObject);
    if (exactType != null) {
      return exactType;
    }
    if (String.isBlank(configuredObject)) {
      return null;
    }
    String cleanConfigured = cleanObjectName(configuredObject);
    Boolean expectsCustomObject = configuredObject.toLowerCase().endsWith('__c');
    for (String candidate : globalDescribe.keySet()) {
      if (
        candidate.toLowerCase().endsWith('__c') == expectsCustomObject &&
        cleanObjectName(candidate) == cleanConfigured
      ) {
        return globalDescribe.get(candidate);
      }
    }
    return null;
  }

  private static String cleanObjectName(String objectName) {
    String cleanName = objectName == null ? '' : objectName.toLowerCase();
    if (cleanName.endsWith('__c')) {
      cleanName = cleanName.substring(0, cleanName.length() - 3);
    }
    Integer namespaceSeparator = cleanName.lastIndexOf('__');
    if (namespaceSeparator >= 0) {
      cleanName = cleanName.substring(namespaceSeparator + 2);
    }
    return cleanName.replaceAll('[^a-z0-9]', '');
  }

  public class ConnectorExecutionRequestException extends Exception {}
}