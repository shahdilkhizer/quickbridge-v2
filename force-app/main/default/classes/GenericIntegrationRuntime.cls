/**
 * Configuration, mapping, and persistence support for the additive generic
 * inbound/outbound handlers. This class deliberately does not perform HTTP
 * callouts; only the two handler classes own transport execution.
 */
public inherited sharing class GenericIntegrationRuntime {
  private static final Set<String> SUPPORTED_DIRECTIONS = new Set<String>{
    'inbound',
    'outbound',
    'bidirectional',
    'both'
  };
  private static final Set<String> SUPPORTED_TRANSFORMS = new Set<String>{
    '',
    'identity',
    'string',
    'lower',
    'upper',
    'integer',
    'decimal',
    'boolean',
    'date',
    'datetime',
    'base64',
    'urlencode'
  };
  private static final Set<String> SUPPORTED_PAGINATION = new Set<String>{
    '',
    'none',
    'cursor',
    'jsonurl',
    'url',
    'linkheader',
    'offset'
  };

  @TestVisible
  private static Map<String, OperationDefinition> testDefinitions =
    new Map<String, OperationDefinition>();

  public class OperationDefinition {
    public String connectorKey { get; set; }
    public String operationKey { get; set; }
    public String direction { get; set; }
    public String salesforceObject { get; set; }
    public String externalEntity { get; set; }
    public String namedCredential { get; set; }
    public String approvedBaseUrl { get; set; }
    public String relativeEndpoint { get; set; }
    public String httpMethod { get; set; }
    public Integer timeoutMilliseconds { get; set; }
    public Integer maximumPages { get; set; }
    public String paginationType { get; set; }
    public String nextPath { get; set; }
    public String cursorQueryParam { get; set; }
    public String pageQueryParam { get; set; }
    public Integer pageSize { get; set; }
    public String sinceQueryParam { get; set; }
    public String requestCardinality { get; set; }
    public String requestTemplate { get; set; }
    public String headersJson { get; set; }
    public String queryParamsJson { get; set; }
    public String responseCollectionPath { get; set; }
    public String responseIdPath { get; set; }
    public String responseContentType { get; set; }
    public String persistenceMode { get; set; }
    public String retryStatuses { get; set; }
    public Integer retryDelaySeconds { get; set; }
    public String inboundSignatureHeader { get; set; }
    public String inboundSignatureAlgorithm { get; set; }
    public String inboundSecretKey { get; set; }
    public String inboundTimestampHeader { get; set; }
    public Integer inboundMaxAgeSeconds { get; set; }
    public String inboundIdempotencyPath { get; set; }
    public String salesforceExternalIdField { get; set; }
    public List<MappingRule> mappings { get; set; }

    public OperationDefinition() {
      timeoutMilliseconds = ConnectorHttpClient.DEFAULT_TIMEOUT_MILLISECONDS;
      maximumPages = ConnectorHttpClient.DEFAULT_MAX_PAGES;
      pageSize = 100;
      requestCardinality = 'Record';
      persistenceMode = 'Upsert';
      responseContentType = 'JSON';
      mappings = new List<MappingRule>();
    }

    public String identity(String requestedDirection) {
      return identity(
        connectorKey,
        operationKey,
        requestedDirection,
        salesforceObject,
        externalEntity
      );
    }
  }

  public class MappingRule {
    public String connectorKey { get; set; }
    public String operationKey { get; set; }
    public String direction { get; set; }
    public String salesforceObject { get; set; }
    public String salesforceField { get; set; }
    public String externalPath { get; set; }
    public String transform { get; set; }
    public String defaultValue { get; set; }
    public Boolean required { get; set; }
    public Boolean isExternalId { get; set; }
    public String nullBehavior { get; set; }
    public String collectionPath { get; set; }
    public String parentSalesforceField { get; set; }
    public String parentExternalPath { get; set; }
    public Integer sortOrder { get; set; }
  }

  public static OperationDefinition resolve(
    ConnectorExecutionRequest request
  ) {
    if (request == null) {
      throw new GenericIntegrationRuntimeException(
        'A generic integration request is required.'
      );
    }
    assertSafeToken(request.connectorKey, 'Connector key');
    assertSafeToken(request.operationKey, 'Operation key');
    String requestedDirection = normalizeDirection(request.direction);
    String requestedObject = request.salesforceObject;
    String requestedEntity = request.externalEntity;

    String testIdentity = identity(
      request.connectorKey,
      request.operationKey,
      requestedDirection,
      requestedObject,
      requestedEntity
    );
    if (Test.isRunningTest() && testDefinitions.containsKey(testIdentity)) {
      OperationDefinition testDefinition = copyDefinition(
        testDefinitions.get(testIdentity)
      );
      validateDefinition(testDefinition, requestedDirection, false);
      return testDefinition;
    }
    if (Test.isRunningTest()) {
      OperationDefinition matchingTestDefinition;
      for (OperationDefinition candidate : testDefinitions.values()) {
        if (
          normalize(candidate.connectorKey) == normalize(request.connectorKey) &&
          normalize(candidate.operationKey) == normalize(request.operationKey) &&
          (normalizeDirection(candidate.direction) == requestedDirection ||
          normalizeDirection(candidate.direction) == 'Bidirectional') &&
          (String.isBlank(requestedObject) ||
          equivalentObject(candidate.salesforceObject, requestedObject)) &&
          (String.isBlank(requestedEntity) ||
          equivalentObject(candidate.externalEntity, requestedEntity))
        ) {
          matchingTestDefinition = candidate;
          break;
        }
      }
      if (matchingTestDefinition != null) {
        OperationDefinition testDefinition = copyDefinition(
          matchingTestDefinition
        );
        validateDefinition(testDefinition, requestedDirection, false);
        return testDefinition;
      }
    }

    List<Integration_Operation__mdt> rows = [
      SELECT
        Active__c,
        Connector_Key__c,
        Operation_Key__c,
        Direction__c,
        Salesforce_Object__c,
        External_Entity__c,
        Named_Credential__c,
        Approved_Base_URL__c,
        Relative_Endpoint__c,
        Http_Method__c,
        Timeout_Milliseconds__c,
        Maximum_Pages__c,
        Pagination_Type__c,
        Next_Path__c,
        Cursor_Query_Param__c,
        Page_Query_Param__c,
        Page_Size__c,
        Since_Query_Param__c,
        Request_Cardinality__c,
        Request_Template__c,
        Headers_JSON__c,
        Query_Params_JSON__c,
        Response_Collection_Path__c,
        Response_Id_Path__c,
        Response_Content_Type__c,
        Persistence_Mode__c,
        Retry_Statuses__c,
        Retry_Delay_Seconds__c,
        Inbound_Signature_Header__c,
        Inbound_Signature_Algorithm__c,
        Inbound_Secret_Key__c,
        Inbound_Timestamp_Header__c,
        Inbound_Max_Age_Seconds__c,
        Inbound_Idempotency_Path__c,
        Salesforce_External_Id_Field__c
      FROM Integration_Operation__mdt
      WHERE
        Active__c = true
        AND Connector_Key__c = :request.connectorKey
        AND Operation_Key__c = :request.operationKey
    ];

    OperationDefinition resolved;
    for (Integration_Operation__mdt row : rows) {
      String rowDirection = normalizeDirection(row.Direction__c);
      if (
        rowDirection == requestedDirection ||
        rowDirection == 'Bidirectional'
      ) {
        resolved = fromMetadata(row);
        break;
      }
    }
    if (resolved == null) {
      throw new GenericIntegrationRuntimeException(
        'No active generic operation configuration exists for ' +
          request.connectorKey +
          '.' +
          request.operationKey +
          '.' +
          requestedDirection +
          '.'
      );
    }

    loadMappings(resolved);
    validateDefinition(resolved, requestedDirection, true);
    return resolved;
  }

  public static String normalizeDirectionForHandler(String value) {
    return normalizeDirection(value);
  }

  public static void validateRequestLimits(ConnectorExecutionRequest request) {
    if (request == null) {
      throw new GenericIntegrationRuntimeException(
        'A generic integration request is required.'
      );
    }
    if (request.scopeSize == null || request.scopeSize < 1 || request.scopeSize > 2000) {
      throw new GenericIntegrationRuntimeException(
        'Scope size must be between 1 and 2000.'
      );
    }
    if (
      request.pageNumber == null ||
      request.pageNumber < 1 ||
      request.pageNumber > ConnectorHttpClient.ABSOLUTE_MAX_PAGES
    ) {
      throw new GenericIntegrationRuntimeException(
        'Page number is outside the supported range.'
      );
    }
    if (
      request.retryAttempt == null ||
      request.retryAttempt < 0 ||
      request.retryAttempt > 5
    ) {
      throw new GenericIntegrationRuntimeException(
        'Retry attempt is outside the supported range.'
      );
    }
    if (request.payload != null && request.payload.length() > 1000000) {
      throw new GenericIntegrationRuntimeException(
        'Payload exceeds the shared integration size limit.'
      );
    }
    if (request.cursor != null && request.cursor.length() > 4000) {
      throw new GenericIntegrationRuntimeException(
        'Cursor exceeds the shared integration size limit.'
      );
    }
    if (request.recordIds != null && request.recordIds.size() > 2000) {
      throw new GenericIntegrationRuntimeException(
        'Record scope exceeds the shared integration size limit.'
      );
    }
  }

  @TestVisible
  public static void registerTestDefinition(OperationDefinition definition) {
    if (!Test.isRunningTest() || definition == null) {
      throw new GenericIntegrationRuntimeException(
        'Test operation registration is only available with a definition.'
      );
    }
    validateDefinition(definition, normalizeDirection(definition.direction), false);
    String direction = normalizeDirection(definition.direction);
    if (direction == 'Bidirectional') {
      testDefinitions.put(
        definition.identity('Inbound'),
        copyDefinition(definition)
      );
      testDefinitions.put(
        definition.identity('Outbound'),
        copyDefinition(definition)
      );
    } else {
      testDefinitions.put(
        definition.identity(direction),
        copyDefinition(definition)
      );
    }
  }

  @TestVisible
  public static void clearTestDefinitions() {
    testDefinitions.clear();
  }

  public static Map<String, String> headersFor(OperationDefinition definition) {
    Map<String, String> headers = parseStringMap(definition.headersJson, 'headers');
    if (!headers.containsKey('Accept')) {
      headers.put('Accept', 'application/json');
    }
    if (
      String.isNotBlank(definition.requestTemplate) ||
      definition.requestCardinality != 'None'
    ) {
      if (!headers.containsKey('Content-Type')) {
        headers.put('Content-Type', 'application/json');
      }
    }
    return headers;
  }

  public static Map<String, String> queryParametersFor(
    OperationDefinition definition,
    ConnectorExecutionRequest request
  ) {
    Map<String, String> parameters = parseStringMap(
      definition.queryParamsJson,
      'query parameters'
    );
    if (String.isNotBlank(definition.cursorQueryParam) && String.isNotBlank(request.cursor)) {
      parameters.put(definition.cursorQueryParam, request.cursor);
    }
    if (String.isNotBlank(definition.pageQueryParam)) {
      parameters.put(
        definition.pageQueryParam,
        String.valueOf(request.pageNumber == null ? 1 : request.pageNumber)
      );
    }
    if (String.isNotBlank(definition.sinceQueryParam) && request.sinceValue != null) {
      parameters.put(
        definition.sinceQueryParam,
        request.sinceValue.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'')
      );
    }
    return parameters;
  }

  public static String buildSourceQuery(
    OperationDefinition definition,
    ConnectorExecutionRequest request
  ) {
    Schema.SObjectType objectType = resolveObjectType(definition.salesforceObject);
    Map<String, Schema.SObjectField> fields = objectType.getDescribe().fields.getMap();
    Set<String> selected = new Set<String>{ 'Id' };
    for (MappingRule mapping : definition.mappings) {
      if (
        !isOutboundMapping(mapping) ||
        !equivalentObject(mapping.salesforceObject, definition.salesforceObject)
      ) {
        continue;
      }
      selected.add(resolveFieldName(fields, mapping.salesforceField));
    }
    if (String.isNotBlank(definition.salesforceExternalIdField)) {
      selected.add(resolveFieldName(fields, definition.salesforceExternalIdField));
    }
    List<String> orderedFields = new List<String>(selected);
    orderedFields.sort();
    String query =
      'SELECT ' +
      String.join(orderedFields, ',') +
      ' FROM ' +
      objectType.getDescribe().getName();
    if (request.recordIds == null || request.recordIds.isEmpty()) {
      throw new GenericIntegrationRuntimeException(
        'Generic outbound execution requires explicit record IDs during the additive validation phase.'
      );
    }
    return query + ' WHERE Id IN :recordIds ORDER BY Id';
  }

  private class ChildCollectionGroup {
    public String collectionPath;
    public String childObject;
    public String parentField;
    public List<MappingRule> mappings = new List<MappingRule>();
  }

  private static List<ChildCollectionGroup> resolveChildCollectionGroups(
    OperationDefinition definition
  ) {
    List<ChildCollectionGroup> groups = new List<ChildCollectionGroup>();
    Map<String, ChildCollectionGroup> groupsByKey = new Map<String, ChildCollectionGroup>();
    for (MappingRule mapping : definition.mappings) {
      if (
        !isOutboundMapping(mapping) ||
        String.isBlank(mapping.collectionPath) ||
        String.isBlank(mapping.parentSalesforceField) ||
        String.isBlank(mapping.salesforceObject) ||
        equivalentObject(mapping.salesforceObject, definition.salesforceObject)
      ) {
        continue;
      }
      String groupKey = String.join(
        new List<String>{
          normalize(mapping.collectionPath),
          normalize(mapping.salesforceObject),
          normalize(mapping.parentSalesforceField)
        },
        '::'
      );
      if (!groupsByKey.containsKey(groupKey)) {
        ChildCollectionGroup newGroup = new ChildCollectionGroup();
        newGroup.collectionPath = mapping.collectionPath;
        newGroup.childObject = mapping.salesforceObject;
        newGroup.parentField = mapping.parentSalesforceField;
        groupsByKey.put(groupKey, newGroup);
        groups.add(newGroup);
      }
      groupsByKey.get(groupKey).mappings.add(mapping);
    }
    return groups;
  }

  private static Map<String, Map<Id, List<SObject>>> queryChildCollections(
    List<ChildCollectionGroup> groups,
    Set<Id> parentIds
  ) {
    Map<String, Map<Id, List<SObject>>> result = new Map<String, Map<Id, List<SObject>>>();
    if (groups.isEmpty() || parentIds.isEmpty()) {
      return result;
    }

    for (ChildCollectionGroup groupItem : groups) {
      Schema.SObjectType childType = resolveObjectType(groupItem.childObject);
      if (childType == null) {
        continue;
      }
      Map<String, Schema.SObjectField> childFields = childType.getDescribe().fields.getMap();
      String resolvedParentField = resolveFieldName(childFields, groupItem.parentField);

      Set<String> selectFields = new Set<String>{ 'Id', resolvedParentField };
      for (MappingRule rule : groupItem.mappings) {
        if (String.isNotBlank(rule.salesforceField)) {
          if (rule.salesforceField.contains('.')) {
            selectFields.add(rule.salesforceField);
          } else if (childFields.containsKey(rule.salesforceField)) {
            selectFields.add(resolveFieldName(childFields, rule.salesforceField));
          }
        }
      }

      List<String> orderedFields = new List<String>(selectFields);
      orderedFields.sort();
      String query =
        'SELECT ' +
        String.join(orderedFields, ',') +
        ' FROM ' +
        childType.getDescribe().getName() +
        ' WHERE ' +
        resolvedParentField +
        ' IN :parentIds ORDER BY ' +
        resolvedParentField +
        ', Id';

      List<SObject> childRows = Database.query(query);
      Map<Id, List<SObject>> byParent = new Map<Id, List<SObject>>();
      for (SObject childRow : childRows) {
        Id parentId = (Id) childRow.get(resolvedParentField);
        if (parentId == null) {
          continue;
        }
        if (!byParent.containsKey(parentId)) {
          byParent.put(parentId, new List<SObject>());
        }
        byParent.get(parentId).add(childRow);
      }
      result.put(groupItem.collectionPath, byParent);
    }
    return result;
  }

  public static String buildRequestBody(
    OperationDefinition definition,
    List<SObject> records,
    ConnectorExecutionRequest request
  ) {
    if (String.isNotBlank(request.payload)) {
      validateJsonIfRequired(request.payload, definition.responseContentType);
      return request.payload;
    }

    List<ChildCollectionGroup> childGroups = resolveChildCollectionGroups(definition);
    Set<Id> parentIds = new Set<Id>();
    if (records != null) {
      for (SObject record : records) {
        if (record.Id != null) {
          parentIds.add(record.Id);
        }
      }
    }
    Map<String, Map<Id, List<SObject>>> childDataByCollection = queryChildCollections(
      childGroups,
      parentIds
    );

    List<Object> payloads = new List<Object>();
    for (SObject recordValue : records == null ? new List<SObject>() : records) {
      Map<String, Object> mapped = new Map<String, Object>();
      for (MappingRule mapping : definition.mappings) {
        if (
          !isOutboundMapping(mapping) ||
          !equivalentObject(mapping.salesforceObject, definition.salesforceObject)
        ) {
          continue;
        }
        Object sourceValue = readSObjectField(recordValue, mapping.salesforceField);
        Object transformed = transform(sourceValue, mapping.transform);
        if (transformed == null) {
          if (String.isNotBlank(mapping.defaultValue)) {
            transformed = transform(mapping.defaultValue, mapping.transform);
          } else if (mapping.required == true) {
            throw new GenericIntegrationRuntimeException(
              'Required outbound mapping is blank: ' + mapping.salesforceField
            );
          } else if (normalize(mapping.nullBehavior) != 'include') {
            continue;
          }
        }
        putPath(mapped, mapping.externalPath, transformed);
      }

      for (ChildCollectionGroup groupItem : childGroups) {
        Map<Id, List<SObject>> byParent = childDataByCollection.get(groupItem.collectionPath);
        List<SObject> children = (byParent != null && recordValue.Id != null)
          ? byParent.get(recordValue.Id)
          : null;
        List<Object> childPayloads = new List<Object>();
        if (children != null) {
          for (SObject childRecord : children) {
            Map<String, Object> childMapped = new Map<String, Object>();
            for (MappingRule childMapping : groupItem.mappings) {
              Object sourceValue = String.isBlank(childMapping.salesforceField)
                ? null
                : readSObjectField(childRecord, childMapping.salesforceField);
              Object transformed = transform(sourceValue, childMapping.transform);
              if (transformed == null) {
                if (String.isNotBlank(childMapping.defaultValue)) {
                  transformed = transform(childMapping.defaultValue, childMapping.transform);
                } else if (childMapping.required == true) {
                  throw new GenericIntegrationRuntimeException(
                    'Required child outbound mapping is blank: ' + childMapping.salesforceField
                  );
                } else if (normalize(childMapping.nullBehavior) != 'include') {
                  continue;
                }
              }
              putPath(childMapped, childMapping.externalPath, transformed);
            }
            childPayloads.add(childMapped);
          }
        }
        if (!childPayloads.isEmpty()) {
          putPath(mapped, groupItem.collectionPath, childPayloads);
        }
      }

      Object payload = String.isBlank(definition.requestTemplate)
        ? mapped
        : applyTemplate(
            JSON.deserializeUntyped(definition.requestTemplate),
            recordValue
          );
      payloads.add(payload);
    }

    Boolean collection = normalize(definition.requestCardinality) == 'collection';
    if (collection) {
      return JSON.serialize(payloads);
    }
    return payloads.isEmpty() ? '{}' : JSON.serialize(payloads[0]);
  }

  public static List<Object> responseRows(
    OperationDefinition definition,
    String responseBody
  ) {
    Object parsed = parseResponseBody(responseBody);
    Object collection = String.isBlank(definition.responseCollectionPath)
      ? parsed
      : readPath(parsed, definition.responseCollectionPath);
    if (collection == null) {
      return new List<Object>();
    }
    if (collection instanceof List<Object>) {
      return (List<Object>) collection;
    }
    return new List<Object>{ collection };
  }

  public static Object parseResponseBody(String responseBody) {
    return parseJson(responseBody);
  }

  public static Object valueAtPath(Object root, String path) {
    return readPath(root, path);
  }

  public static ConnectorExecutionResult persistInbound(
    OperationDefinition definition,
    String responseBody
  ) {
    ConnectorExecutionResult result = ConnectorExecutionResult.success();
    if (normalize(definition.persistenceMode) == 'none') {
      return result;
    }

    List<Object> rows = responseRows(definition, responseBody);
    if (rows.isEmpty()) {
      return result;
    }
    Map<String, List<SObject>> recordsByObject = new Map<String, List<SObject>>();
    Map<String, Schema.SObjectField> externalFields = new Map<String, Schema.SObjectField>();

    for (Object rowValue : rows) {
      if (!(rowValue instanceof Map<String, Object>)) {
        result.mergeFrom(
          ConnectorExecutionResult.failed(
            'Inbound response collection contains a non-object row.',
            false,
            null
          )
        );
        continue;
      }
      Map<String, Object> row = (Map<String, Object>) rowValue;
      String objectName = definition.salesforceObject;
      List<MappingRule> inboundMappings = mappingsFor(
        definition,
        ConnectorExecutionRequest.DIRECTION_INBOUND,
        objectName
      );
      if (inboundMappings.isEmpty()) {
        throw new GenericIntegrationRuntimeException(
          'No inbound mappings are configured for ' + objectName + '.'
        );
      }
      Schema.SObjectType objectType = resolveObjectType(objectName);
      SObject target = objectType.newSObject();
      Map<String, Schema.SObjectField> fields = objectType.getDescribe().fields.getMap();
      for (MappingRule mapping : inboundMappings) {
        String fieldName = resolveFieldName(fields, mapping.salesforceField);
        Object value = readPath(row, mapping.externalPath);
        value = transform(value, mapping.transform);
        if (value == null && String.isNotBlank(mapping.defaultValue)) {
          value = transform(mapping.defaultValue, mapping.transform);
        }
        if (value == null) {
          if (mapping.required == true) {
            throw new GenericIntegrationRuntimeException(
              'Required inbound mapping is blank: ' + mapping.salesforceField
            );
          }
          if (normalize(mapping.nullBehavior) != 'include') {
            continue;
          }
        }
        target.put(fieldName, value);
        if (mapping.isExternalId == true) {
          externalFields.put(objectName, fields.get(fieldName));
        }
      }
      if (
        String.isNotBlank(definition.responseIdPath) &&
        String.isNotBlank(definition.salesforceExternalIdField)
      ) {
        String externalField = resolveFieldName(
          fields,
          definition.salesforceExternalIdField
        );
        Object externalId = readPath(row, definition.responseIdPath);
        if (externalId != null) {
          target.put(externalField, String.valueOf(externalId));
          externalFields.put(objectName, fields.get(externalField));
        }
      }
      if (!recordsByObject.containsKey(objectName)) {
        recordsByObject.put(objectName, new List<SObject>());
      }
      recordsByObject.get(objectName).add(target);
    }

    for (String objectName : recordsByObject.keySet()) {
      List<SObject> records = recordsByObject.get(objectName);
      SObjectAccessDecision decision = Security.stripInaccessible(
        AccessType.UPSERTABLE,
        records
      );
      List<SObject> safeRecords = decision.getRecords();
      Schema.SObjectField externalField = externalFields.get(objectName);
      if (externalField == null) {
        Database.SaveResult[] saveResults = Database.insert(safeRecords, false);
        addSaveResults(result, saveResults);
      } else {
        Database.UpsertResult[] upsertResults = Database.upsert(
          safeRecords,
          externalField,
          false
        );
        addUpsertResults(result, upsertResults);
      }
    }
    return result;
  }

  private static void addSaveResults(
    ConnectorExecutionResult result,
    Database.SaveResult[] saveResults
  ) {
    result.processedCount += saveResults == null ? 0 : saveResults.size();
    for (Database.SaveResult saveResult : saveResults == null
      ? new List<Database.SaveResult>()
      : saveResults) {
      addSaveResult(result, saveResult);
    }
  }

  private static void addUpsertResults(
    ConnectorExecutionResult result,
    Database.UpsertResult[] upsertResults
  ) {
    result.processedCount += upsertResults == null ? 0 : upsertResults.size();
    for (Database.UpsertResult upsertResult : upsertResults == null
      ? new List<Database.UpsertResult>()
      : upsertResults) {
      addUpsertResult(result, upsertResult);
    }
  }

  private static void addUpsertResult(
    ConnectorExecutionResult result,
    Database.UpsertResult upsertResult
  ) {
    if (upsertResult != null && upsertResult.isSuccess()) {
      result.successfulCount++;
      return;
    }
    result.failedCount++;
    if (upsertResult != null) {
      for (Database.Error errorValue : upsertResult.getErrors()) {
        result.addError(
          errorValue.getStatusCode() + ': ' + errorValue.getMessage()
        );
      }
    }
  }

  private static void addSaveResult(
    ConnectorExecutionResult result,
    Database.SaveResult saveResult
  ) {
    if (saveResult != null && saveResult.isSuccess()) {
      result.successfulCount++;
      return;
    }
    result.failedCount++;
    if (saveResult != null) {
      for (Database.Error errorValue : saveResult.getErrors()) {
        result.addError(
          errorValue.getStatusCode() + ': ' + errorValue.getMessage()
        );
      }
    }
  }

  public static ConnectorExecutionResult persistOutboundResponse(
    OperationDefinition definition,
    List<SObject> records,
    String responseBody
  ) {
    List<String> responseBodies = new List<String>();
    for (Integer indexValue = 0; indexValue < (records == null ? 0 : records.size()); indexValue++) {
      responseBodies.add(responseBody);
    }
    return persistOutboundResponses(definition, records, responseBodies);
  }

  public static ConnectorExecutionResult persistOutboundResponses(
    OperationDefinition definition,
    List<SObject> records,
    List<String> responseBodies
  ) {
    ConnectorExecutionResult result = ConnectorExecutionResult.success();
    if (records == null || records.isEmpty()) {
      return result;
    }
    List<MappingRule> responseMappings = mappingsFor(
      definition,
      'Response',
      definition.salesforceObject
    );
    if (responseMappings.isEmpty() && String.isBlank(definition.responseIdPath)) {
      result.processedCount = records.size();
      result.successfulCount = records.size();
      return result;
    }

    List<SObject> updates = new List<SObject>();
    for (Integer indexValue = 0; indexValue < records.size(); indexValue++) {
      SObject recordValue = records[indexValue];
      String responseBody = responseBodies == null || responseBodies.size() <= indexValue
        ? null
        : responseBodies[indexValue];
      Object parsed = String.isBlank(responseBody)
        ? null
        : parseJson(responseBody);
      SObject updateRecord = recordValue.getSObjectType().newSObject(recordValue.Id);
      for (MappingRule mapping : responseMappings) {
        Object value = parsed == null ? null : readPath(parsed, mapping.externalPath);
        value = transform(value, mapping.transform);
        if (value != null || normalize(mapping.nullBehavior) == 'include') {
          updateRecord.put(mapping.salesforceField, value);
        }
      }
      if (
        String.isNotBlank(definition.responseIdPath) &&
        String.isNotBlank(definition.salesforceExternalIdField) &&
        parsed != null
      ) {
        Object externalId = readPath(parsed, definition.responseIdPath);
        if (externalId != null) {
          updateRecord.put(
            definition.salesforceExternalIdField,
            String.valueOf(externalId)
          );
        }
      }
      updates.add(updateRecord);
    }
    SObjectAccessDecision decision = Security.stripInaccessible(
      AccessType.UPDATABLE,
      updates
    );
    Database.SaveResult[] saveResults = Database.update(
      decision.getRecords(),
      false
    );
    result.processedCount = saveResults.size();
    for (Database.SaveResult saveResult : saveResults) {
      if (saveResult.isSuccess()) {
        result.successfulCount++;
      } else {
        result.failedCount++;
        result.dmlOperation = 'UPDATE';
        result.errorCategory = 'SALESFORCE_DML_FAILURE';
        result.classMethod = 'GenericIntegrationRuntime.persistOutboundResponses';
        result.retryRecordIds.add(records[saveResults.indexOf(saveResult)].Id);
        for (Database.Error errorValue : saveResult.getErrors()) {
          result.addError(errorValue.getStatusCode() + ': ' + errorValue.getMessage());
        }
      }
    }
    return result;
  }

  public static String nextCursor(
    OperationDefinition definition,
    ConnectorHttpClient.Response response,
    ConnectorExecutionRequest request,
    Integer returnedCount
  ) {
    String pagination = normalize(definition.paginationType);
    if (pagination == 'linkheader') {
      return normalizeNextUrl(
        definition,
        ConnectorHttpClient.extractLinkNext(response.header('Link'))
      );
    }
    if (pagination == 'jsonurl' || pagination == 'url') {
      return normalizeNextUrl(
        definition,
        ConnectorHttpClient.extractJsonNext(response.body, definition.nextPath)
      );
    }
    if (pagination == 'cursor') {
      return ConnectorHttpClient.extractCursor(response.body, definition.nextPath);
    }
    if (pagination == 'offset') {
      Integer currentOffset = String.isBlank(request.cursor)
        ? 0
        : Integer.valueOf(request.cursor);
      Integer nextOffset = ConnectorHttpClient.nextOffset(
        currentOffset,
        definition.pageSize,
        returnedCount,
        null
      );
      return nextOffset == null ? null : String.valueOf(nextOffset);
    }
    return null;
  }

  public static Boolean isRetryable(
    OperationDefinition definition,
    Integer statusCode
  ) {
    if (statusCode == null) {
      return false;
    }
    Set<Integer> configured = new Set<Integer>();
    if (String.isNotBlank(definition.retryStatuses)) {
      for (String value : definition.retryStatuses.split(',')) {
        if (String.isBlank(value) || !Pattern.matches('^[0-9]{3}$', value.trim())) {
          throw new GenericIntegrationRuntimeException(
            'Retry status configuration is invalid.'
          );
        }
        configured.add(Integer.valueOf(value.trim()));
      }
    }
    if (!configured.isEmpty()) {
      return configured.contains(statusCode);
    }
    return IntegrationRetryPolicy.isRetryable(statusCode);
  }

  public static Integer retryDelaySeconds(
    OperationDefinition definition,
    ConnectorHttpClient.Response response
  ) {
    if (response != null && response.retryAfterSeconds != null) {
      return response.retryAfterSeconds;
    }
    return definition.retryDelaySeconds == null
      ? 60
      : Math.max(1, Math.min(86400, definition.retryDelaySeconds));
  }

  public static void validateInboundEvent(
    OperationDefinition definition,
    String payload,
    Map<String, String> headers
  ) {
    if (String.isBlank(payload)) {
      throw new GenericIntegrationRuntimeException(
        'Inbound event payload is required.'
      );
    }
    if (String.isBlank(definition.inboundSignatureHeader)) {
      return;
    }
    String signature = headerValue(headers, definition.inboundSignatureHeader);
    String timestamp = headerValue(headers, definition.inboundTimestampHeader);
    String secret = String.isBlank(definition.inboundSecretKey)
      ? null
      : ConnectorConfigService.getConfigValue(
          definition.connectorKey,
          definition.inboundSecretKey
        );
    if (normalize(definition.inboundSignatureAlgorithm) == 'hmacsha256') {
      HmacRequestVerifier.Result verification = HmacRequestVerifier.verify(
        payload,
        signature,
        timestamp,
        secret,
        definition.inboundMaxAgeSeconds
      );
      if (!verification.ok) {
        throw new GenericIntegrationRuntimeException(verification.message);
      }
      return;
    }
    throw new GenericIntegrationRuntimeException(
      'The configured inbound signature algorithm is unsupported.'
    );
  }

  private static OperationDefinition fromMetadata(
    Integration_Operation__mdt row
  ) {
    OperationDefinition definition = new OperationDefinition();
    definition.connectorKey = row.Connector_Key__c;
    definition.operationKey = row.Operation_Key__c;
    definition.direction = row.Direction__c;
    definition.salesforceObject = row.Salesforce_Object__c;
    definition.externalEntity = row.External_Entity__c;
    definition.namedCredential = row.Named_Credential__c;
    definition.approvedBaseUrl = row.Approved_Base_URL__c;
    definition.relativeEndpoint = row.Relative_Endpoint__c;
    definition.httpMethod = row.Http_Method__c;
    definition.timeoutMilliseconds = row.Timeout_Milliseconds__c == null
      ? definition.timeoutMilliseconds
      : row.Timeout_Milliseconds__c.intValue();
    definition.maximumPages = row.Maximum_Pages__c == null
      ? definition.maximumPages
      : row.Maximum_Pages__c.intValue();
    definition.paginationType = row.Pagination_Type__c;
    definition.nextPath = row.Next_Path__c;
    definition.cursorQueryParam = row.Cursor_Query_Param__c;
    definition.pageQueryParam = row.Page_Query_Param__c;
    definition.pageSize = row.Page_Size__c == null
      ? definition.pageSize
      : row.Page_Size__c.intValue();
    definition.sinceQueryParam = row.Since_Query_Param__c;
    definition.requestCardinality = row.Request_Cardinality__c;
    definition.requestTemplate = row.Request_Template__c;
    definition.headersJson = row.Headers_JSON__c;
    definition.queryParamsJson = row.Query_Params_JSON__c;
    definition.responseCollectionPath = row.Response_Collection_Path__c;
    definition.responseIdPath = row.Response_Id_Path__c;
    definition.responseContentType = row.Response_Content_Type__c;
    definition.persistenceMode = row.Persistence_Mode__c;
    definition.retryStatuses = row.Retry_Statuses__c;
    definition.retryDelaySeconds = row.Retry_Delay_Seconds__c == null
      ? null
      : row.Retry_Delay_Seconds__c.intValue();
    definition.inboundSignatureHeader = row.Inbound_Signature_Header__c;
    definition.inboundSignatureAlgorithm = row.Inbound_Signature_Algorithm__c;
    definition.inboundSecretKey = row.Inbound_Secret_Key__c;
    definition.inboundTimestampHeader = row.Inbound_Timestamp_Header__c;
    definition.inboundMaxAgeSeconds = row.Inbound_Max_Age_Seconds__c == null
      ? null
      : row.Inbound_Max_Age_Seconds__c.intValue();
    definition.inboundIdempotencyPath = row.Inbound_Idempotency_Path__c;
    definition.salesforceExternalIdField = row.Salesforce_External_Id_Field__c;
    return definition;
  }

  // Metadata is immutable within a transaction; prime all requested connectors in bulk.
  private static Set<String> loadedMappingConnectors = new Set<String>();
  private static List<Integration_Operation_Mapping__mdt> cachedMappingRows =
    new List<Integration_Operation_Mapping__mdt>();
  private static List<Field_Mapping__mdt> cachedOverrideRows = new List<Field_Mapping__mdt>();
  @TestVisible private static List<Integration_Operation_Mapping__mdt> testMappingRows;
  @TestVisible private static List<Field_Mapping__mdt> testOverrideRows;

  public static void primeMappingCache(Set<String> connectorKeys) {
    Set<String> missing = new Set<String>();
    for (String key : connectorKeys) {
      if (String.isNotBlank(key) && !loadedMappingConnectors.contains(key.toLowerCase())) {
        missing.add(key.toLowerCase());
      }
    }
    if (missing.isEmpty()) return;
    Set<String> aliases = new Set<String>();
    for (String key : missing) aliases.addAll(mappingAliases(key));
    cachedMappingRows.addAll(Test.isRunningTest() && testMappingRows != null
      ? testMappingRows
      : [
        SELECT Active__c, Connector_Key__c, Operation_Key__c, Direction__c,
          Salesforce_Object__c, Salesforce_Field__c, External_Path__c, Transform__c,
          Default_Value__c, Required__c, Is_External_Id__c, Null_Behavior__c,
          Collection_Path__c, Parent_Salesforce_Field__c, Parent_External_Path__c, Sort_Order__c
        FROM Integration_Operation_Mapping__mdt
        WHERE Active__c = true AND Connector_Key__c IN :missing
        ORDER BY Sort_Order__c ASC
      ]);
    cachedOverrideRows.addAll(Test.isRunningTest() && testOverrideRows != null
      ? testOverrideRows
      : [
        SELECT Integration__c, Action__c, SF_Object__c, SF_Field__c,
          External_Field__c, Sync_Direction__c, Is_Active__c
        FROM Field_Mapping__mdt
        WHERE Is_Active__c = true AND Integration__c IN :aliases
      ]);
    loadedMappingConnectors.addAll(missing);
  }

  // Does not resolve an endpoint, require credentials, or perform callouts.
  public static Boolean hasRecordSaveChildObject(Integration_Operation__mdt operation, String objectName) {
    primeMappingCache(new Set<String>{ operation.Connector_Key__c });
    for (Integration_Operation_Mapping__mdt row : cachedMappingRows) {
      if (row.Active__c == true && row.Connector_Key__c.equalsIgnoreCase(operation.Connector_Key__c) &&
          row.Operation_Key__c.equalsIgnoreCase(operation.Operation_Key__c) &&
          equivalentObject(row.Salesforce_Object__c, objectName) &&
          String.isNotBlank(row.Parent_Salesforce_Field__c)) return true;
    }
    return false;
  }

  // Does not resolve an endpoint, require credentials, or perform callouts.
  public static List<MappingRule> recordSaveMappings(
    Integration_Operation__mdt operation, Boolean includeOverrides
  ) {
    OperationDefinition definition = new OperationDefinition();
    definition.connectorKey = operation.Connector_Key__c;
    definition.operationKey = operation.Operation_Key__c;
    definition.salesforceObject = operation.Salesforce_Object__c;
    definition.externalEntity = operation.External_Entity__c;
    definition.salesforceExternalIdField = operation.Salesforce_External_Id_Field__c;
    loadMappings(definition, includeOverrides);
    return definition.mappings;
  }

  private static Set<String> mappingAliases(String connectorKey) {
    Set<String> aliases = new Set<String>{ connectorKey.toLowerCase() };
    if (normalize(connectorKey) == 'qbo') aliases.addAll(new Set<String>{ 'qbonline', 'quickbooks' });
    return aliases;
  }

  @TestVisible private static void resetMappingCache() {
    loadedMappingConnectors.clear();
    cachedMappingRows.clear();
    cachedOverrideRows.clear();
  }

  private static void loadMappings(OperationDefinition definition) {
    loadMappings(definition, true);
  }

  private static void loadMappings(OperationDefinition definition, Boolean includeOverrides) {
    primeMappingCache(new Set<String>{ definition.connectorKey });
    List<Integration_Operation_Mapping__mdt> rows = new List<Integration_Operation_Mapping__mdt>();
    for (Integration_Operation_Mapping__mdt row : cachedMappingRows) {
      if (row.Active__c == true &&
          row.Connector_Key__c.equalsIgnoreCase(definition.connectorKey) &&
          row.Operation_Key__c.equalsIgnoreCase(definition.operationKey)) rows.add(row);
    }
    for (Integration_Operation_Mapping__mdt row : rows) {
      MappingRule mapping = new MappingRule();
      mapping.connectorKey = row.Connector_Key__c;
      mapping.operationKey = row.Operation_Key__c;
      mapping.direction = row.Direction__c;
      mapping.salesforceObject = row.Salesforce_Object__c;
      mapping.salesforceField = row.Salesforce_Field__c;
      mapping.externalPath = row.External_Path__c;
      mapping.transform = row.Transform__c;
      mapping.defaultValue = row.Default_Value__c;
      mapping.required = row.Required__c == true;
      mapping.isExternalId = row.Is_External_Id__c == true;
      mapping.nullBehavior = row.Null_Behavior__c;
      mapping.collectionPath = row.Collection_Path__c;
      mapping.parentSalesforceField = row.Parent_Salesforce_Field__c;
      mapping.parentExternalPath = row.Parent_External_Path__c;
      mapping.sortOrder = row.Sort_Order__c == null ? 999 : row.Sort_Order__c.intValue();
      definition.mappings.add(mapping);
    }
    if (includeOverrides == true) applyFieldMappingOverrides(definition);
  }

  private static void applyFieldMappingOverrides(OperationDefinition definition) {
    Set<String> connectorAliases = mappingAliases(definition.connectorKey);
    List<Field_Mapping__mdt> overrides = new List<Field_Mapping__mdt>();
    for (Field_Mapping__mdt row : cachedOverrideRows) {
      if (row.Is_Active__c == true && row.Integration__c != null &&
          connectorAliases.contains(row.Integration__c.toLowerCase())) overrides.add(row);
    }
    Map<String, String> childCollectionPaths = new Map<String, String>();
    Map<String, String> childParentFields = new Map<String, String>();
    for (MappingRule defMap : definition.mappings) {
      if (String.isNotBlank(defMap.collectionPath) && String.isNotBlank(defMap.salesforceObject)) {
        childCollectionPaths.put(normalize(defMap.salesforceObject), defMap.collectionPath);
        if (String.isNotBlank(defMap.parentSalesforceField)) {
          childParentFields.put(normalize(defMap.salesforceObject), defMap.parentSalesforceField);
        }
      }
    }
    Map<String, MappingRule> overrideByKey = new Map<String, MappingRule>();
    for (Field_Mapping__mdt row : overrides) {
      Boolean isParent = equivalentObject(row.SF_Object__c, definition.salesforceObject);
      Boolean isChild = childCollectionPaths.containsKey(normalize(row.SF_Object__c));
      if (!isParent && !isChild) continue;
      if (String.isNotBlank(row.Action__c) &&
          normalize(row.Action__c) != normalize(definition.operationKey) &&
          normalize(row.Action__c) != normalize(definition.externalEntity)) continue;
      MappingRule mapping = new MappingRule();
      mapping.connectorKey = definition.connectorKey;
      mapping.operationKey = definition.operationKey;
      mapping.direction = overrideDirection(row.Sync_Direction__c);
      mapping.salesforceObject = row.SF_Object__c;
      mapping.salesforceField = row.SF_Field__c;
      mapping.externalPath = row.External_Field__c;
      mapping.transform = 'identity';
      mapping.required = false;
      mapping.isExternalId = normalize(row.SF_Field__c) ==
        normalize(definition.salesforceExternalIdField);
      mapping.nullBehavior = 'Omit';
      mapping.sortOrder = 500;
      if (isChild) {
        mapping.collectionPath = childCollectionPaths.get(normalize(row.SF_Object__c));
        mapping.parentSalesforceField = childParentFields.get(normalize(row.SF_Object__c));
      }
      validateMapping(mapping, definition);
      overrideByKey.put(mappingKey(mapping), mapping);
    }
    if (overrideByKey.isEmpty()) return;
    List<MappingRule> merged = new List<MappingRule>();
    for (MappingRule defaultMapping : definition.mappings) {
      if (!overrideByKey.containsKey(mappingKey(defaultMapping))) merged.add(defaultMapping);
    }
    merged.addAll(overrideByKey.values());
    definition.mappings = merged;
  }

  private static String mappingKey(MappingRule mapping) {
    return normalize(mapping.salesforceObject) + ':' +
      normalize(mapping.salesforceField) + ':' + normalizeMappingDirection(mapping.direction);
  }

  private static String overrideDirection(String value) {
    String normalized = normalize(value);
    if (normalized == 'twoway' || normalized == 'both' || normalized == 'bidirectional') return 'Both';
    if (
      normalized == 'outbound' || normalized.startsWith('sfto') ||
      normalized.startsWith('salesforceto') || normalized.contains('toexternal')
    ) return 'Outbound';
    if (
      normalized == 'inbound' || normalized.endsWith('tosf') ||
      normalized.endsWith('tosalesforce') || normalized.contains('fromexternal')
    ) return 'Inbound';
    return 'Both';
  }

  private static String normalizeMappingDirection(String value) {
    String normalized = normalize(value);
    return normalized == 'twoway' || normalized == 'bidirectional' ? 'both' : normalized;
  }

  private static void validateDefinition(
    OperationDefinition definition,
    String requestedDirection,
    Boolean requireMetadataTransport
  ) {
    if (definition == null) {
      throw new GenericIntegrationRuntimeException('Operation definition is required.');
    }
    assertSafeToken(definition.connectorKey, 'Connector key');
    assertSafeToken(definition.operationKey, 'Operation key');
    String configuredDirection = normalizeDirection(definition.direction);
    if (
      configuredDirection != requestedDirection &&
      configuredDirection != 'Bidirectional'
    ) {
      throw new GenericIntegrationRuntimeException(
        'Configured operation direction does not match the request.'
      );
    }
    if (String.isBlank(definition.salesforceObject)) {
      if (normalize(definition.persistenceMode) != 'none') {
        throw new GenericIntegrationRuntimeException(
          'A Salesforce object is required for a persistent operation.'
        );
      }
    } else {
      resolveObjectType(definition.salesforceObject);
    }
    if (String.isBlank(definition.externalEntity)) {
      throw new GenericIntegrationRuntimeException('External entity is required.');
    }
    if (requireMetadataTransport || String.isNotBlank(definition.namedCredential)) {
      ConnectorHttpClient.toNamedCredentialEndpoint(
        definition.namedCredential,
        definition.relativeEndpoint
      );
    }
    if (
      String.isNotBlank(definition.approvedBaseUrl) &&
      !definition.approvedBaseUrl.toLowerCase().startsWith('https://')
    ) {
      throw new GenericIntegrationRuntimeException(
        'Approved base URL must use HTTPS.'
      );
    }
    if (definition.timeoutMilliseconds < 1 || definition.timeoutMilliseconds > 120000) {
      throw new GenericIntegrationRuntimeException('Timeout is outside the supported range.');
    }
    if (
      definition.maximumPages < 1 ||
      definition.maximumPages > ConnectorHttpClient.ABSOLUTE_MAX_PAGES
    ) {
      throw new GenericIntegrationRuntimeException('Maximum pages is outside the supported range.');
    }
    if (definition.pageSize < 1 || definition.pageSize > 2000) {
      throw new GenericIntegrationRuntimeException('Page size is outside the supported range.');
    }
    if (!SUPPORTED_PAGINATION.contains(normalize(definition.paginationType))) {
      throw new GenericIntegrationRuntimeException('Pagination type is unsupported.');
    }
    if (String.isNotBlank(definition.headersJson)) {
      parseStringMap(definition.headersJson, 'headers');
    }
    if (String.isNotBlank(definition.queryParamsJson)) {
      parseStringMap(definition.queryParamsJson, 'query parameters');
    }
    if (String.isNotBlank(definition.requestTemplate)) {
      parseJson(definition.requestTemplate);
    }
    validatePath(definition.nextPath, 'next path', false);
    validatePath(definition.responseCollectionPath, 'response collection path', false);
    validatePath(definition.responseIdPath, 'response ID path', false);
    validatePath(definition.inboundIdempotencyPath, 'idempotency path', false);
    if (String.isNotBlank(definition.salesforceExternalIdField)) {
      resolveFieldName(
        resolveObjectType(definition.salesforceObject).getDescribe().fields.getMap(),
        definition.salesforceExternalIdField
      );
    }
    for (MappingRule mapping : definition.mappings) {
      validateMapping(mapping, definition);
    }
  }

  private static void validateMapping(
    MappingRule mapping,
    OperationDefinition definition
  ) {
    if (mapping == null) {
      throw new GenericIntegrationRuntimeException('Mapping rule is required.');
    }
    if (String.isBlank(mapping.salesforceObject)) {
      mapping.salesforceObject = definition.salesforceObject;
    }
    resolveObjectType(mapping.salesforceObject);
    Map<String, Schema.SObjectField> fields = resolveObjectType(
        mapping.salesforceObject
      )
      .getDescribe()
      .fields.getMap();
    resolveFieldName(fields, mapping.salesforceField);
    validatePath(mapping.externalPath, 'mapping external path', true);
    if (!SUPPORTED_TRANSFORMS.contains(normalize(mapping.transform))) {
      throw new GenericIntegrationRuntimeException(
        'Mapping transform is unsupported: ' + mapping.transform
      );
    }
    if (
      String.isNotBlank(mapping.collectionPath) &&
      !String.isNotBlank(definition.responseCollectionPath)
    ) {
      validatePath(mapping.collectionPath, 'mapping collection path', false);
    }
  }

  private static List<MappingRule> mappingsFor(
    OperationDefinition definition,
    String direction,
    String objectName
  ) {
    List<MappingRule> result = new List<MappingRule>();
    for (MappingRule mapping : definition.mappings) {
      String mappingDirection = normalize(mapping.direction);
      Boolean directionMatches =
        mappingDirection == normalize(direction) ||
        mappingDirection == 'both' ||
        (direction == 'Response' && mappingDirection == 'outboundresponse');
      if (
        directionMatches &&
        equivalentObject(mapping.salesforceObject, objectName)
      ) {
        result.add(mapping);
      }
    }
    return result;
  }

  private static Boolean isOutboundMapping(MappingRule mapping) {
    String direction = normalize(mapping.direction);
    return direction == 'outbound' || direction == 'both';
  }

  private static Object applyTemplate(Object template, SObject recordValue) {
    if (template instanceof Map<String, Object>) {
      Map<String, Object> source = (Map<String, Object>) template;
      Map<String, Object> result = new Map<String, Object>();
      for (String key : source.keySet()) {
        result.put(key, applyTemplate(source.get(key), recordValue));
      }
      return result;
    }
    if (template instanceof List<Object>) {
      List<Object> result = new List<Object>();
      for (Object item : (List<Object>) template) {
        result.add(applyTemplate(item, recordValue));
      }
      return result;
    }
    if (!(template instanceof String)) {
      return template;
    }
    String value = (String) template;
    Matcher exact = Pattern.compile('^\\{\\{([A-Za-z][A-Za-z0-9_.]*)\\}\\}$').matcher(value);
    if (exact.matches()) {
      return readSObjectField(recordValue, exact.group(1));
    }
    return value.replaceAll('\\{\\{[A-Za-z][A-Za-z0-9_.]*\\}\\}', '');
  }

  private static Object transform(Object value, String transformName) {
    if (value == null) {
      return null;
    }
    String transformValue = normalize(transformName);
    if (transformValue == '' || transformValue == 'identity') {
      return value;
    }
    String stringValue = String.valueOf(value);
    if (transformValue == 'string') {
      return stringValue;
    }
    if (transformValue == 'lower') {
      return stringValue.toLowerCase();
    }
    if (transformValue == 'upper') {
      return stringValue.toUpperCase();
    }
    if (transformValue == 'integer') {
      return Integer.valueOf(stringValue);
    }
    if (transformValue == 'decimal') {
      return Decimal.valueOf(stringValue);
    }
    if (transformValue == 'boolean') {
      return stringValue.equalsIgnoreCase('true') ||
        stringValue.equalsIgnoreCase('yes') ||
        stringValue == '1';
    }
    if (transformValue == 'date') {
      return Date.valueOf(stringValue);
    }
    if (transformValue == 'datetime') {
      return Datetime.valueOf(stringValue);
    }
    if (transformValue == 'base64') {
      return EncodingUtil.base64Encode(Blob.valueOf(stringValue));
    }
    if (transformValue == 'urlencode') {
      return EncodingUtil.urlEncode(stringValue, 'UTF-8');
    }
    throw new GenericIntegrationRuntimeException('Unsupported transform: ' + transformName);
  }

  private static Object readSObjectField(SObject recordValue, String fieldPath) {
    if (recordValue == null || String.isBlank(fieldPath)) {
      return null;
    }
    List<String> segments = fieldPath.split('\\.');
    SObject current = recordValue;
    for (Integer indexValue = 0; indexValue < segments.size(); indexValue++) {
      String segment = segments[indexValue];
      if (indexValue == segments.size() - 1) {
        return current.get(segment);
      }
      current = current.getSObject(segment);
      if (current == null) {
        return null;
      }
    }
    return null;
  }

  private static Object readPath(Object root, String path) {
    if (root == null || String.isBlank(path)) {
      return root;
    }
    Object current = root;
    for (String segment : path.split('\\.')) {
      if (current == null) {
        return null;
      }
      Matcher indexed = Pattern.compile('^([A-Za-z0-9_-]+)(?:\\[([0-9]+)\\])?$').matcher(segment);
      if (!indexed.matches()) {
        return null;
      }
      String key = indexed.group(1);
      if (current instanceof Map<String, Object>) {
        current = ((Map<String, Object>) current).get(key);
      } else {
        return null;
      }
      if (indexed.group(2) != null) {
        if (!(current instanceof List<Object>)) {
          return null;
        }
        Integer itemIndex = Integer.valueOf(indexed.group(2));
        List<Object> items = (List<Object>) current;
        current = itemIndex < items.size() ? items[itemIndex] : null;
      }
    }
    return current;
  }

  private static void putPath(Map<String, Object> target, String path, Object value) {
    List<String> segments = path.split('\\.');
    Map<String, Object> current = target;
    for (Integer indexValue = 0; indexValue < segments.size() - 1; indexValue++) {
      String segment = segments[indexValue];
      if (!current.containsKey(segment) || !(current.get(segment) instanceof Map<String, Object>)) {
        current.put(segment, new Map<String, Object>());
      }
      current = (Map<String, Object>) current.get(segment);
    }
    current.put(segments[segments.size() - 1], value);
  }

  private static Object parseJson(String body) {
    try {
      return JSON.deserializeUntyped(body);
    } catch (Exception exceptionValue) {
      throw new GenericIntegrationRuntimeException('Connector returned malformed JSON.');
    }
  }

  private static void validateJsonIfRequired(String body, String contentType) {
    if (String.isBlank(body) || normalize(contentType) == 'binary') {
      return;
    }
    parseJson(body);
  }

  private static Map<String, String> parseStringMap(String jsonValue, String label) {
    Map<String, String> result = new Map<String, String>();
    if (String.isBlank(jsonValue)) {
      return result;
    }
    Object parsed = parseJson(jsonValue);
    if (!(parsed instanceof Map<String, Object>)) {
      throw new GenericIntegrationRuntimeException(label + ' must be a JSON object.');
    }
    for (String key : ((Map<String, Object>) parsed).keySet()) {
      if (
        String.isBlank(key) ||
        !Pattern.matches('^[A-Za-z0-9_.\\-]{1,80}$', key)
      ) {
        throw new GenericIntegrationRuntimeException(label + ' contains an invalid key.');
      }
      Object value = ((Map<String, Object>) parsed).get(key);
      if (value != null && !(value instanceof String) && !(value instanceof Boolean) && !(value instanceof Decimal) && !(value instanceof Integer)) {
        throw new GenericIntegrationRuntimeException(label + ' values must be scalar.');
      }
      result.put(key, value == null ? null : String.valueOf(value));
    }
    return result;
  }

  private static String normalizeNextUrl(
    OperationDefinition definition,
    String nextUrl
  ) {
    if (String.isBlank(nextUrl)) {
      return null;
    }
    String candidate = nextUrl.trim();
    if (candidate.toLowerCase().startsWith('https://')) {
      if (String.isBlank(definition.approvedBaseUrl)) {
        throw new GenericIntegrationRuntimeException(
          'An approved base URL is required for absolute pagination links.'
        );
      }
      return ConnectorHttpClient.safeRelativeNext(
        definition.approvedBaseUrl,
        candidate
      );
    }
    if (
      candidate.toLowerCase().startsWith('http://') ||
      candidate.toLowerCase().startsWith('callout:') ||
      !candidate.startsWith('/')
    ) {
      throw new GenericIntegrationRuntimeException(
        'Pagination link left the configured Named Credential boundary.'
      );
    }
    ConnectorHttpClient.toNamedCredentialEndpoint(
      definition.namedCredential,
      candidate
    );
    return candidate;
  }

  private static String headerValue(Map<String, String> headers, String key) {
    if (headers == null || String.isBlank(key)) {
      return null;
    }
    if (headers.containsKey(key)) {
      return headers.get(key);
    }
    for (String candidate : headers.keySet()) {
      if (candidate.equalsIgnoreCase(key)) {
        return headers.get(candidate);
      }
    }
    return null;
  }

  private static Schema.SObjectType resolveObjectType(String objectName) {
    Schema.SObjectType result = ConnectorExecutionRequest.resolveSObjectType(objectName);
    if (result == null) {
      throw new GenericIntegrationRuntimeException(
        'Configured Salesforce object is unavailable: ' + objectName
      );
    }
    return result;
  }

  private static String resolveFieldName(
    Map<String, Schema.SObjectField> fields,
    String requestedField
  ) {
    if (
      String.isBlank(requestedField) ||
      !Pattern.matches('^[A-Za-z][A-Za-z0-9_]{0,79}$', requestedField)
    ) {
      throw new GenericIntegrationRuntimeException('A configured Salesforce field is invalid.');
    }
    if (fields.containsKey(requestedField)) {
      return fields.get(requestedField).getDescribe().getName();
    }
    String normalized = normalize(requestedField);
    String candidate;
    for (String fieldName : fields.keySet()) {
      if (normalize(fieldName) == normalized) {
        if (candidate != null && candidate != fieldName) {
          throw new GenericIntegrationRuntimeException(
            'A configured Salesforce field is ambiguous across namespaces.'
          );
        }
        candidate = fieldName;
      }
    }
    if (candidate == null) {
      throw new GenericIntegrationRuntimeException(
        'Configured Salesforce field is unavailable: ' + requestedField
      );
    }
    return fields.get(candidate).getDescribe().getName();
  }

  private static void validatePath(String value, String label, Boolean required) {
    if (String.isBlank(value)) {
      if (required) {
        throw new GenericIntegrationRuntimeException(label + ' is required.');
      }
      return;
    }
    if (!Pattern.matches('^[A-Za-z0-9_-]+(?:\\[[0-9]+\\])?(?:\\.[A-Za-z0-9_-]+(?:\\[[0-9]+\\])?)*$', value)) {
      throw new GenericIntegrationRuntimeException(label + ' is invalid.');
    }
  }

  private static void assertSafeToken(String value, String label) {
    if (String.isBlank(value) || !Pattern.matches('^[A-Za-z][A-Za-z0-9_. -]{0,79}$', value)) {
      throw new GenericIntegrationRuntimeException(label + ' is invalid.');
    }
  }

  private static String normalizeDirection(String value) {
    String normalized = normalize(value);
    if (normalized == 'inbound' || normalized == 'in' || normalized == 'tosalesforce') {
      return 'Inbound';
    }
    if (normalized == 'outbound' || normalized == 'out' || normalized == 'fromsalesforce') {
      return 'Outbound';
    }
    if (normalized == 'both' || normalized == 'bidirectional') {
      return 'Bidirectional';
    }
    throw new GenericIntegrationRuntimeException('Direction must be Inbound, Outbound, or Bidirectional.');
  }

  private static Boolean equivalentObject(String leftValue, String rightValue) {
    return normalize(leftValue) == normalize(rightValue);
  }

  private static String identity(
    String connectorKey,
    String operationKey,
    String direction,
    String salesforceObject,
    String externalEntity
  ) {
    return String.join(
      new List<String>{
        normalize(connectorKey),
        normalize(operationKey),
        normalize(direction),
        normalize(salesforceObject),
        normalize(externalEntity)
      },
      ':'
    );
  }

  private static OperationDefinition copyDefinition(OperationDefinition source) {
    OperationDefinition result = new OperationDefinition();
    result.connectorKey = source.connectorKey;
    result.operationKey = source.operationKey;
    result.direction = source.direction;
    result.salesforceObject = source.salesforceObject;
    result.externalEntity = source.externalEntity;
    result.namedCredential = source.namedCredential;
    result.approvedBaseUrl = source.approvedBaseUrl;
    result.relativeEndpoint = source.relativeEndpoint;
    result.httpMethod = source.httpMethod;
    result.timeoutMilliseconds = source.timeoutMilliseconds;
    result.maximumPages = source.maximumPages;
    result.paginationType = source.paginationType;
    result.nextPath = source.nextPath;
    result.cursorQueryParam = source.cursorQueryParam;
    result.pageQueryParam = source.pageQueryParam;
    result.pageSize = source.pageSize;
    result.sinceQueryParam = source.sinceQueryParam;
    result.requestCardinality = source.requestCardinality;
    result.requestTemplate = source.requestTemplate;
    result.headersJson = source.headersJson;
    result.queryParamsJson = source.queryParamsJson;
    result.responseCollectionPath = source.responseCollectionPath;
    result.responseIdPath = source.responseIdPath;
    result.responseContentType = source.responseContentType;
    result.persistenceMode = source.persistenceMode;
    result.retryStatuses = source.retryStatuses;
    result.retryDelaySeconds = source.retryDelaySeconds;
    result.inboundSignatureHeader = source.inboundSignatureHeader;
    result.inboundSignatureAlgorithm = source.inboundSignatureAlgorithm;
    result.inboundSecretKey = source.inboundSecretKey;
    result.inboundTimestampHeader = source.inboundTimestampHeader;
    result.inboundMaxAgeSeconds = source.inboundMaxAgeSeconds;
    result.inboundIdempotencyPath = source.inboundIdempotencyPath;
    result.salesforceExternalIdField = source.salesforceExternalIdField;
    result.mappings = new List<MappingRule>();
    for (MappingRule mapping : source.mappings == null ? new List<MappingRule>() : source.mappings) {
      MappingRule copied = new MappingRule();
      copied.connectorKey = mapping.connectorKey;
      copied.operationKey = mapping.operationKey;
      copied.direction = mapping.direction;
      copied.salesforceObject = mapping.salesforceObject;
      copied.salesforceField = mapping.salesforceField;
      copied.externalPath = mapping.externalPath;
      copied.transform = mapping.transform;
      copied.defaultValue = mapping.defaultValue;
      copied.required = mapping.required;
      copied.isExternalId = mapping.isExternalId;
      copied.nullBehavior = mapping.nullBehavior;
      copied.collectionPath = mapping.collectionPath;
      copied.parentSalesforceField = mapping.parentSalesforceField;
      copied.parentExternalPath = mapping.parentExternalPath;
      copied.sortOrder = mapping.sortOrder;
      result.mappings.add(copied);
    }
    return result;
  }

  private static String normalize(String value) {
    return String.isBlank(value) ? '' : value.toLowerCase().replaceAll('[^a-z0-9]', '');
  }

  public class GenericIntegrationRuntimeException extends Exception {}
}