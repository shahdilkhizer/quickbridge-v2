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
    public String resourceContractJson { get; set; }
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
      if (String.isNotBlank(mapping.salesforceField)) {
        if (mapping.salesforceField.contains('.')) {
          selected.add(mapping.salesforceField);
        } else {
          selected.add(resolveFieldName(fields, mapping.salesforceField));
        }
      }
    }
    if (String.isNotBlank(definition.salesforceExternalIdField)) {
      selected.add(resolveFieldName(fields, definition.salesforceExternalIdField));
    }
    if (fields.containsKey('lastmodifieddate')) {
      selected.add(resolveFieldName(fields, 'LastModifiedDate'));
    }
    List<String> orderedFields = new List<String>(selected);
    orderedFields.sort();
    String query =
      'SELECT ' +
      String.join(orderedFields, ',') +
      ' FROM ' +
      objectType.getDescribe().getName();
    if (request.recordIds != null && !request.recordIds.isEmpty()) {
      return query + ' WHERE Id IN :recordIds ORDER BY Id';
    }
    if (request.scheduleId != null) {
      String externalField = String.isNotBlank(definition.salesforceExternalIdField)
        ? resolveFieldName(fields, definition.salesforceExternalIdField)
        : null;
      String filter = '';
      if (fields.containsKey('qbo_customer_id__c')) {
        filter = 'QBO_Customer_ID__c != NULL AND ';
      }
      if (String.isNotBlank(externalField)) {
        return query + ' WHERE ' + filter + '(' + externalField + ' = NULL OR LastModifiedDate >= :sinceValue) ORDER BY LastModifiedDate DESC';
      }
      return query + ' WHERE ' + filter + 'LastModifiedDate >= :sinceValue ORDER BY LastModifiedDate DESC';
    }
    throw new GenericIntegrationRuntimeException(
      'Generic outbound execution requires explicit record IDs during the additive validation phase.'
    );
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
    return resolveChildCollectionGroups(definition, 'Outbound');
  }

  private static List<ChildCollectionGroup> resolveChildCollectionGroups(
    OperationDefinition definition,
    String direction
  ) {
    List<ChildCollectionGroup> groups = new List<ChildCollectionGroup>();
    Map<String, ChildCollectionGroup> groupsByKey = new Map<String, ChildCollectionGroup>();
    String targetDir = normalize(direction);
    for (MappingRule mapping : definition.mappings) {
      String mDir = normalize(mapping.direction);
      Boolean dirMatches = (targetDir == 'outbound')
        ? (mDir == 'outbound' || mDir == 'both')
        : (mDir == 'inbound' || mDir == 'both');
      if (
        !dirMatches ||
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
          } else {
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
    Map<String, List<Map<String, Object>>> rawRowsByObject = new Map<String, List<Map<String, Object>>>();
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
        putCoerced(target, fieldName, value, fields);
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
        rawRowsByObject.put(objectName, new List<Map<String, Object>>());
      }
      recordsByObject.get(objectName).add(target);
      rawRowsByObject.get(objectName).add(row);
    }

    for (String objectName : recordsByObject.keySet()) {
      List<SObject> records = recordsByObject.get(objectName);
      List<Map<String, Object>> rawRows = rawRowsByObject.get(objectName);
      prepareInboundParentRecords(definition, rawRows, records);

      SObjectAccessDecision decision = Security.stripInaccessible(
        AccessType.UPSERTABLE,
        records
      );
      List<SObject> safeRecords = decision.getRecords();
      Schema.SObjectField externalField = externalFields.get(objectName);
      if (externalField == null) {
        Database.SaveResult[] saveResults = Database.insert(safeRecords, false);
        addSaveResults(result, saveResults);
        for (Integer i = 0; i < saveResults.size(); i++) {
          if (saveResults[i].isSuccess()) {
            safeRecords[i].Id = saveResults[i].getId();
          }
        }
      } else {
        Database.UpsertResult[] upsertResults = Database.upsert(
          safeRecords,
          externalField,
          false
        );
        for (Integer i = 0; i < upsertResults.size(); i++) {
          if (upsertResults[i].isSuccess()) {
            safeRecords[i].Id = upsertResults[i].getId();
          }
        }
        List<SObject> retryRecords = new List<SObject>();
        List<Integer> retryIndices = new List<Integer>();
        for (Integer i = 0; i < upsertResults.size(); i++) {
          Database.UpsertResult ur = upsertResults[i];
          if (!ur.isSuccess()) {
            Boolean hasAddressError = false;
            for (Database.Error err : ur.getErrors()) {
              String msg = err.getMessage();
              if (msg.contains('country/territory') || msg.contains('Billing State') || msg.contains('Shipping State') || msg.contains('valid countries') || msg.contains('valid states')) {
                hasAddressError = true;
                break;
              }
            }
            if (hasAddressError) {
              SObject cleaned = safeRecords[i].clone(true, true, true, true);
              Map<String, Schema.SObjectField> objFields = cleaned.getSObjectType().getDescribe().fields.getMap();
              if (objFields.containsKey('billingstate')) cleaned.put('BillingState', null);
              if (objFields.containsKey('billingcountry')) cleaned.put('BillingCountry', null);
              if (objFields.containsKey('shippingstate')) cleaned.put('ShippingState', null);
              if (objFields.containsKey('shippingcountry')) cleaned.put('ShippingCountry', null);
              retryRecords.add(cleaned);
              retryIndices.add(i);
            } else {
              addUpsertResult(result, ur);
            }
          } else {
            addUpsertResult(result, ur);
          }
        }
        if (!retryRecords.isEmpty()) {
          Database.UpsertResult[] retryResults = Database.upsert(retryRecords, externalField, false);
          for (Integer r = 0; r < retryResults.size(); r++) {
            Database.UpsertResult rur = retryResults[r];
            addUpsertResult(result, rur);
            if (rur.isSuccess()) {
              Integer origIndex = retryIndices[r];
              safeRecords[origIndex] = retryRecords[r];
              safeRecords[origIndex].Id = rur.getId();
            }
          }
        }
      }
      persistInboundChildCollections(definition, rawRows, safeRecords, result);
    }
    return result;
  }

  private static Id standardPricebookIdCache;
  private static Id getStandardPricebookId() {
    if (standardPricebookIdCache != null) {
      return standardPricebookIdCache;
    }
    if (Test.isRunningTest()) {
      standardPricebookIdCache = Test.getStandardPricebookId();
    } else {
      List<Pricebook2> stdPbs = [
        SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1
      ];
      if (!stdPbs.isEmpty()) {
        standardPricebookIdCache = stdPbs[0].Id;
      }
    }
    return standardPricebookIdCache;
  }

  private static Id resolveDefaultPricebookId() {
    if (Test.isRunningTest()) {
      return Test.getStandardPricebookId();
    }
    List<Pricebook2> customStandard = [
      SELECT Id FROM Pricebook2 WHERE Name = 'Standard' AND IsActive = true LIMIT 1
    ];
    if (!customStandard.isEmpty()) {
      return customStandard[0].Id;
    }
    return getStandardPricebookId();
  }

  private static void prepareInboundParentRecords(
    OperationDefinition definition,
    List<Map<String, Object>> rawRows,
    List<SObject> records
  ) {
    if (records == null || records.isEmpty() || String.isBlank(definition.salesforceObject)) {
      return;
    }
    if (equivalentObject(definition.salesforceObject, 'Order')) {
      prepareInboundOrderParents(definition, rawRows, records);
    } else if (equivalentObject(definition.salesforceObject, 'Invoice__c')) {
      prepareInboundInvoiceParents(definition, rawRows, records);
    }
  }

  private static void prepareInboundInvoiceParents(
    OperationDefinition definition,
    List<Map<String, Object>> rawRows,
    List<SObject> records
  ) {
    Set<String> customerRefValues = new Set<String>();
    Set<String> customerRefNames = new Set<String>();
    for (Integer i = 0; i < records.size(); i++) {
      SObject rec = records[i];
      if (rec.get('Related_Account__c') == null) {
        Map<String, Object> raw = rawRows[i];
        Object custVal = readPath(raw, 'CustomerRef.value');
        if (custVal != null) {
          customerRefValues.add(String.valueOf(custVal));
        }
        Object custName = readPath(raw, 'CustomerRef.name');
        if (custName != null) {
          customerRefNames.add(String.valueOf(custName));
        }
      }
    }

    Map<String, Id> accByQboId = new Map<String, Id>();
    Map<String, Id> accByName = new Map<String, Id>();
    if (!customerRefValues.isEmpty() || !customerRefNames.isEmpty()) {
      for (Account acc : [
        SELECT Id, QuickbookID__c, Name
        FROM Account
        WHERE QuickbookID__c IN :customerRefValues OR Name IN :customerRefNames
      ]) {
        if (String.isNotBlank(acc.QuickbookID__c)) {
          accByQboId.put(acc.QuickbookID__c, acc.Id);
        }
        if (String.isNotBlank(acc.Name)) {
          accByName.put(acc.Name.toLowerCase(), acc.Id);
        }
      }
    }

    for (Integer i = 0; i < records.size(); i++) {
      SObject rec = records[i];
      Map<String, Object> raw = rawRows[i];

      if (rec.get('Related_Account__c') == null) {
        Object custVal = readPath(raw, 'CustomerRef.value');
        Object custName = readPath(raw, 'CustomerRef.name');
        if (custVal != null && accByQboId.containsKey(String.valueOf(custVal))) {
          rec.put('Related_Account__c', accByQboId.get(String.valueOf(custVal)));
        } else if (custName != null && accByName.containsKey(String.valueOf(custName).toLowerCase())) {
          rec.put('Related_Account__c', accByName.get(String.valueOf(custName).toLowerCase()));
        }
      }

      if (rec.get('Invoice_Date__c') == null) {
        Object txnDate = readPath(raw, 'TxnDate');
        if (txnDate != null) {
          try {
            rec.put('Invoice_Date__c', Date.valueOf(String.valueOf(txnDate)));
          } catch (Exception ex) {
            rec.put('Invoice_Date__c', Date.today());
          }
        } else {
          rec.put('Invoice_Date__c', Date.today());
        }
      }

      if (rec.get('Amount__c') == null) {
        Object totalAmt = readPath(raw, 'TotalAmt');
        if (totalAmt != null) {
          try {
            rec.put('Amount__c', Decimal.valueOf(String.valueOf(totalAmt)));
          } catch (Exception ex) {}
        }
      }
    }
  }

  private static void prepareInboundOrderParents(
    OperationDefinition definition,
    List<Map<String, Object>> rawRows,
    List<SObject> records
  ) {
    Id defaultPbId = resolveDefaultPricebookId();

    Set<String> extIds = new Set<String>();
    String extFieldName = definition.salesforceExternalIdField;
    if (String.isNotBlank(extFieldName)) {
      for (SObject rec : records) {
        Object val = rec.get(extFieldName);
        if (val != null) {
          extIds.add(String.valueOf(val));
        }
      }
    }
    Map<String, Order> existingOrders = new Map<String, Order>();
    if (!extIds.isEmpty()) {
      for (Order ord : [
        SELECT Id, AccountId, Pricebook2Id, Status, QuickbookID__c
        FROM Order
        WHERE QuickbookID__c IN :extIds
      ]) {
        if (String.isNotBlank(ord.QuickbookID__c)) {
          existingOrders.put(ord.QuickbookID__c, ord);
        }
      }
    }

    Set<String> customerRefValues = new Set<String>();
    Set<String> customerRefNames = new Set<String>();
    for (Integer i = 0; i < records.size(); i++) {
      SObject rec = records[i];
      if (rec.get('AccountId') == null) {
        Map<String, Object> raw = rawRows[i];
        Object custVal = readPath(raw, 'CustomerRef.value');
        if (custVal != null) {
          customerRefValues.add(String.valueOf(custVal));
        }
        Object custName = readPath(raw, 'CustomerRef.name');
        if (custName != null) {
          customerRefNames.add(String.valueOf(custName));
        }
      }
    }

    Map<String, Id> accByQboId = new Map<String, Id>();
    Map<String, Id> accByName = new Map<String, Id>();
    if (!customerRefValues.isEmpty() || !customerRefNames.isEmpty()) {
      for (Account acc : [
        SELECT Id, QuickbookID__c, Name
        FROM Account
        WHERE QuickbookID__c IN :customerRefValues OR Name IN :customerRefNames
      ]) {
        if (String.isNotBlank(acc.QuickbookID__c)) {
          accByQboId.put(acc.QuickbookID__c, acc.Id);
        }
        if (String.isNotBlank(acc.Name)) {
          accByName.put(acc.Name.toLowerCase(), acc.Id);
        }
      }
    }

    for (Integer i = 0; i < records.size(); i++) {
      SObject rec = records[i];
      Map<String, Object> raw = rawRows[i];

      String qboId = String.isNotBlank(extFieldName) && rec.get(extFieldName) != null
        ? String.valueOf(rec.get(extFieldName))
        : null;
      Order existing = qboId != null ? existingOrders.get(qboId) : null;

      if (existing != null && existing.Pricebook2Id != null) {
        rec.put('Pricebook2Id', existing.Pricebook2Id);
      } else if (rec.get('Pricebook2Id') == null && defaultPbId != null) {
        rec.put('Pricebook2Id', defaultPbId);
      }

      if (rec.get('AccountId') == null) {
        if (existing != null && existing.AccountId != null) {
          rec.put('AccountId', existing.AccountId);
        } else {
          Object custVal = readPath(raw, 'CustomerRef.value');
          Object custName = readPath(raw, 'CustomerRef.name');
          if (custVal != null && accByQboId.containsKey(String.valueOf(custVal))) {
            rec.put('AccountId', accByQboId.get(String.valueOf(custVal)));
          } else if (custName != null && accByName.containsKey(String.valueOf(custName).toLowerCase())) {
            rec.put('AccountId', accByName.get(String.valueOf(custName).toLowerCase()));
          }
        }
      }

      if (rec.get('Status') == null) {
        rec.put('Status', existing != null && existing.Status != null ? existing.Status : 'Draft');
      }

      if (rec.get('EffectiveDate') == null) {
        Object txnDate = readPath(raw, 'TxnDate');
        if (txnDate != null) {
          try {
            rec.put('EffectiveDate', Date.valueOf(String.valueOf(txnDate)));
          } catch (Exception ex) {
            rec.put('EffectiveDate', Date.today());
          }
        } else {
          rec.put('EffectiveDate', Date.today());
        }
      }
    }
  }

  private static void persistInboundChildCollections(
    OperationDefinition definition,
    List<Map<String, Object>> rawRows,
    List<SObject> parentRecords,
    ConnectorExecutionResult result
  ) {
    List<ChildCollectionGroup> childGroups = resolveChildCollectionGroups(definition, 'Inbound');
    if (childGroups.isEmpty() || parentRecords.isEmpty()) {
      return;
    }

    for (ChildCollectionGroup groupItem : childGroups) {
      Schema.SObjectType childType = resolveObjectType(groupItem.childObject);
      if (childType == null) {
        continue;
      }
      Map<String, Schema.SObjectField> childFields = childType.getDescribe().fields.getMap();
      String resolvedParentField = resolveFieldName(childFields, groupItem.parentField);

      Schema.SObjectField childExternalField;
      for (MappingRule mapping : groupItem.mappings) {
        if (mapping.isExternalId == true && String.isNotBlank(mapping.salesforceField)) {
          childExternalField = childFields.get(resolveFieldName(childFields, mapping.salesforceField));
          break;
        }
      }

      List<SObject> childRecords = new List<SObject>();
      List<Map<String, Object>> childRaws = new List<Map<String, Object>>();
      List<SObject> parentRecsForChild = new List<SObject>();

      for (Integer i = 0; i < parentRecords.size(); i++) {
        SObject parentRec = parentRecords[i];
        if (parentRec.Id == null) {
          continue;
        }
        Map<String, Object> parentRaw = rawRows[i];
        Object rawCollection = readPath(parentRaw, groupItem.collectionPath);
        if (!(rawCollection instanceof List<Object>)) {
          continue;
        }
        for (Object itemObj : (List<Object>) rawCollection) {
          if (!(itemObj instanceof Map<String, Object>)) {
            continue;
          }
          Map<String, Object> childRaw = (Map<String, Object>) itemObj;

          if (equivalentObject(groupItem.childObject, 'OrderItem') || equivalentObject(groupItem.childObject, 'Invoice_Line__c')) {
            String detailType = (String) childRaw.get('DetailType');
            if (detailType == 'SubTotalLineDetail') {
              continue;
            }
            if (readPath(childRaw, 'SalesItemLineDetail.ItemRef.value') == null && detailType != 'SalesItemLineDetail') {
              continue;
            }
          }

          SObject childTarget = childType.newSObject();
          childTarget.put(resolvedParentField, parentRec.Id);

          for (MappingRule mapping : groupItem.mappings) {
            String fName = resolveFieldName(childFields, mapping.salesforceField);
            Object val = readPath(childRaw, mapping.externalPath);
            val = transform(val, mapping.transform);
            if (val == null && String.isNotBlank(mapping.defaultValue)) {
              val = transform(mapping.defaultValue, mapping.transform);
            }
            if (val != null) {
              putCoerced(childTarget, fName, val, childFields);
            }
          }
          childRecords.add(childTarget);
          childRaws.add(childRaw);
          parentRecsForChild.add(parentRec);
        }
      }

      if (childRecords.isEmpty()) {
        continue;
      }

      if (equivalentObject(groupItem.childObject, 'OrderItem')) {
        prepareInboundOrderItems(childRecords, childRaws, parentRecsForChild);
      } else if (equivalentObject(groupItem.childObject, 'Invoice_Line__c')) {
        prepareInboundInvoiceLines(childRecords, childRaws, parentRecsForChild);
      }

      if (childExternalField != null) {
        String extName = childExternalField.getDescribe().getName();
        Set<String> extVals = new Set<String>();
        for (SObject cr : childRecords) {
          if (cr.Id == null && cr.get(extName) != null) {
            extVals.add(String.valueOf(cr.get(extName)));
          }
        }
        if (!extVals.isEmpty()) {
          String childObjName = childType.getDescribe().getName();
          String soql = 'SELECT Id, ' + extName + ' FROM ' + childObjName + ' WHERE ' + extName + ' IN :extVals';
          Map<String, Id> existingByExt = new Map<String, Id>();
          for (SObject existRec : Database.query(soql)) {
            existingByExt.put(String.valueOf(existRec.get(extName)), existRec.Id);
          }
          for (SObject cr : childRecords) {
            if (cr.Id == null && cr.get(extName) != null) {
              String v = String.valueOf(cr.get(extName));
              if (existingByExt.containsKey(v)) {
                cr.Id = existingByExt.get(v);
              }
            }
          }
        }
      }

      List<SObject> toInsert = new List<SObject>();
      List<SObject> toUpdate = new List<SObject>();
      for (SObject cr : childRecords) {
        if (cr.Id != null) {
          toUpdate.add(cr);
        } else {
          toInsert.add(cr);
        }
      }

      if (!toInsert.isEmpty()) {
        SObjectAccessDecision createDecision = Security.stripInaccessible(
          AccessType.CREATABLE,
          toInsert
        );
        Database.SaveResult[] srs = Database.insert(createDecision.getRecords(), false);
        addSaveResults(result, srs);
      }

      if (!toUpdate.isEmpty()) {
        SObjectAccessDecision updateDecision = Security.stripInaccessible(
          AccessType.UPDATABLE,
          toUpdate
        );
        Database.SaveResult[] urs = Database.update(updateDecision.getRecords(), false);
        addSaveResults(result, urs);
      }
    }
  }

  private static void prepareInboundOrderItems(
    List<SObject> childRecords,
    List<Map<String, Object>> childRaws,
    List<SObject> parentRecords
  ) {
    if (childRecords.isEmpty()) {
      return;
    }

    Id stdPbId = getStandardPricebookId();

    // 1. Quantities and UnitPrices
    for (Integer i = 0; i < childRecords.size(); i++) {
      SObject item = childRecords[i];
      Map<String, Object> childRaw = childRaws[i];
      Decimal qty = (Decimal) item.get('Quantity');
      if (qty == null || qty <= 0) {
        item.put('Quantity', 1);
        qty = 1;
      }
      if (item.get('UnitPrice') == null) {
        Object rawAmt = readPath(childRaw, 'Amount');
        if (rawAmt != null) {
          Decimal amount = Decimal.valueOf(String.valueOf(rawAmt));
          item.put('UnitPrice', qty > 0 ? (amount / qty) : amount);
        } else {
          item.put('UnitPrice', 0);
        }
      }
    }

    // 2. Resolve Product2
    Set<String> qboProdIds = new Set<String>();
    Set<String> prodNames = new Set<String>();
    for (Map<String, Object> raw : childRaws) {
      Object pid = readPath(raw, 'SalesItemLineDetail.ItemRef.value');
      if (pid != null) {
        qboProdIds.add(String.valueOf(pid));
      }
      Object pName = readPath(raw, 'SalesItemLineDetail.ItemRef.name');
      if (pName != null) {
        prodNames.add(String.valueOf(pName));
      }
    }

    Map<String, Product2> prodByQboId = new Map<String, Product2>();
    Map<String, Product2> prodByName = new Map<String, Product2>();
    if (!qboProdIds.isEmpty() || !prodNames.isEmpty()) {
      for (Product2 p : [
        SELECT Id, Name, QuickbookID__c, IsActive
        FROM Product2
        WHERE QuickbookID__c IN :qboProdIds OR Name IN :prodNames
      ]) {
        if (String.isNotBlank(p.QuickbookID__c)) {
          prodByQboId.put(p.QuickbookID__c, p);
        }
        if (String.isNotBlank(p.Name)) {
          prodByName.put(p.Name.toLowerCase(), p);
        }
      }
    }

    List<Product2> prodsToInsert = new List<Product2>();
    for (Map<String, Object> raw : childRaws) {
      Object pid = readPath(raw, 'SalesItemLineDetail.ItemRef.value');
      Object pName = readPath(raw, 'SalesItemLineDetail.ItemRef.name');
      String sPid = pid != null ? String.valueOf(pid) : null;
      String sName = pName != null ? String.valueOf(pName) : null;
      Boolean found = (sPid != null && prodByQboId.containsKey(sPid)) ||
                      (sName != null && prodByName.containsKey(sName.toLowerCase()));
      if (!found) {
        String finalName = String.isNotBlank(sName) ? sName : (sPid != null ? 'QBO Item ' + sPid : 'QBO Product');
        Product2 np = new Product2(
          Name = finalName,
          QuickbookID__c = sPid,
          IsActive = true
        );
        prodsToInsert.add(np);
        if (sPid != null) prodByQboId.put(sPid, np);
        if (sName != null) prodByName.put(sName.toLowerCase(), np);
      }
    }
    if (!prodsToInsert.isEmpty()) {
      insert prodsToInsert;
      for (Product2 np : prodsToInsert) {
        if (String.isNotBlank(np.QuickbookID__c)) prodByQboId.put(np.QuickbookID__c, np);
        if (String.isNotBlank(np.Name)) prodByName.put(np.Name.toLowerCase(), np);
      }
    }

    // 3. Resolve PricebookEntries
    Set<Id> productIds = new Set<Id>();
    List<Product2> matchedProducts = new List<Product2>();
    for (Map<String, Object> raw : childRaws) {
      Object pid = readPath(raw, 'SalesItemLineDetail.ItemRef.value');
      Object pName = readPath(raw, 'SalesItemLineDetail.ItemRef.name');
      Product2 matched;
      if (pid != null && prodByQboId.containsKey(String.valueOf(pid))) {
        matched = prodByQboId.get(String.valueOf(pid));
      } else if (pName != null && prodByName.containsKey(String.valueOf(pName).toLowerCase())) {
        matched = prodByName.get(String.valueOf(pName).toLowerCase());
      }
      matchedProducts.add(matched);
      if (matched != null && matched.Id != null) {
        productIds.add(matched.Id);
      }
    }

    Set<Id> orderPbIds = new Set<Id>();
    if (stdPbId != null) {
      orderPbIds.add(stdPbId);
    }
    for (SObject parentRec : parentRecords) {
      Id pbId = (Id) parentRec.get('Pricebook2Id');
      if (pbId != null) {
        orderPbIds.add(pbId);
      }
    }

    Map<String, PricebookEntry> pbeByKey = new Map<String, PricebookEntry>();
    if (!productIds.isEmpty() && !orderPbIds.isEmpty()) {
      for (PricebookEntry pbe : [
        SELECT Id, Pricebook2Id, Product2Id, UnitPrice, IsActive
        FROM PricebookEntry
        WHERE Pricebook2Id IN :orderPbIds AND Product2Id IN :productIds
      ]) {
        String key = String.valueOf(pbe.Pricebook2Id) + '::' + String.valueOf(pbe.Product2Id);
        pbeByKey.put(key, pbe);
      }
    }

    Map<Id, PricebookEntry> stdPbesToInsertByProd = new Map<Id, PricebookEntry>();
    for (Product2 p : matchedProducts) {
      if (p == null || p.Id == null || stdPbId == null) continue;
      String stdKey = String.valueOf(stdPbId) + '::' + String.valueOf(p.Id);
      if (!pbeByKey.containsKey(stdKey) && !stdPbesToInsertByProd.containsKey(p.Id)) {
        PricebookEntry spe = new PricebookEntry(
          Pricebook2Id = stdPbId,
          Product2Id = p.Id,
          UnitPrice = 0,
          IsActive = true
        );
        stdPbesToInsertByProd.put(p.Id, spe);
      }
    }
    if (!stdPbesToInsertByProd.isEmpty()) {
      insert stdPbesToInsertByProd.values();
      for (PricebookEntry spe : stdPbesToInsertByProd.values()) {
        pbeByKey.put(String.valueOf(spe.Pricebook2Id) + '::' + String.valueOf(spe.Product2Id), spe);
      }
    }

    Map<String, PricebookEntry> customPbesToInsertByKey = new Map<String, PricebookEntry>();
    for (Integer i = 0; i < childRecords.size(); i++) {
      Product2 p = matchedProducts[i];
      SObject parentRec = parentRecords[i];
      Id pbId = (Id) parentRec.get('Pricebook2Id');
      if (pbId == null) pbId = stdPbId;
      if (p == null || p.Id == null || pbId == null || pbId == stdPbId) continue;
      String cKey = String.valueOf(pbId) + '::' + String.valueOf(p.Id);
      if (!pbeByKey.containsKey(cKey) && !customPbesToInsertByKey.containsKey(cKey)) {
        PricebookEntry cpe = new PricebookEntry(
          Pricebook2Id = pbId,
          Product2Id = p.Id,
          UnitPrice = 0,
          IsActive = true
        );
        customPbesToInsertByKey.put(cKey, cpe);
      }
    }
    if (!customPbesToInsertByKey.isEmpty()) {
      insert customPbesToInsertByKey.values();
      for (PricebookEntry cpe : customPbesToInsertByKey.values()) {
        pbeByKey.put(String.valueOf(cpe.Pricebook2Id) + '::' + String.valueOf(cpe.Product2Id), cpe);
      }
    }

    for (Integer i = 0; i < childRecords.size(); i++) {
      SObject item = childRecords[i];
      Product2 p = matchedProducts[i];
      SObject parentRec = parentRecords[i];
      Id pbId = (Id) parentRec.get('Pricebook2Id');
      if (pbId == null) pbId = stdPbId;
      if (p != null && p.Id != null && pbId != null) {
        String key = String.valueOf(pbId) + '::' + String.valueOf(p.Id);
        if (pbeByKey.containsKey(key)) {
          item.put('PricebookEntryId', pbeByKey.get(key).Id);
        }
      }
    }

    // 4. External ID cross-order uniqueness guard
    Set<String> lineExtIds = new Set<String>();
    for (SObject item : childRecords) {
      Object extVal = item.get('External_Id__c');
      if (extVal != null) {
        lineExtIds.add(String.valueOf(extVal));
      }
    }
    if (!lineExtIds.isEmpty()) {
      Map<String, OrderItem> existingByExtId = new Map<String, OrderItem>();
      for (OrderItem existingItem : [
        SELECT Id, OrderId, External_Id__c
        FROM OrderItem
        WHERE External_Id__c IN :lineExtIds
      ]) {
        if (String.isNotBlank(existingItem.External_Id__c)) {
          existingByExtId.put(existingItem.External_Id__c, existingItem);
        }
      }
      for (SObject item : childRecords) {
        Object extVal = item.get('External_Id__c');
        if (extVal == null) continue;
        String sExt = String.valueOf(extVal);
        Id currentOrderId = (Id) item.get('OrderId');
        if (existingByExtId.containsKey(sExt)) {
          OrderItem existingItem = existingByExtId.get(sExt);
          if (existingItem.OrderId == currentOrderId) {
            item.Id = existingItem.Id;
          } else {
            item.put('External_Id__c', String.valueOf(currentOrderId) + '_' + sExt);
          }
        }
      }
    }
  }

  private static void prepareInboundInvoiceLines(
    List<SObject> childRecords,
    List<Map<String, Object>> childRaws,
    List<SObject> parentRecords
  ) {
    if (childRecords.isEmpty()) {
      return;
    }

    // 1. Quantities and UnitPrices
    for (Integer i = 0; i < childRecords.size(); i++) {
      SObject item = childRecords[i];
      Map<String, Object> childRaw = childRaws[i];
      Decimal qty = (Decimal) item.get('Quantity__c');
      if (qty == null || qty <= 0) {
        item.put('Quantity__c', 1);
        qty = 1;
      }
      if (item.get('Unit_Price__c') == null) {
        Object rawPrice = readPath(childRaw, 'SalesItemLineDetail.UnitPrice');
        if (rawPrice != null) {
          item.put('Unit_Price__c', Decimal.valueOf(String.valueOf(rawPrice)));
        } else {
          Object rawAmt = readPath(childRaw, 'Amount');
          if (rawAmt != null) {
            Decimal amount = Decimal.valueOf(String.valueOf(rawAmt));
            item.put('Unit_Price__c', qty > 0 ? (amount / qty) : amount);
          } else {
            item.put('Unit_Price__c', 0);
          }
        }
      }
    }

    // 2. Resolve Product__c
    Set<String> qboProdIds = new Set<String>();
    Set<String> prodNames = new Set<String>();
    for (Map<String, Object> raw : childRaws) {
      Object pid = readPath(raw, 'SalesItemLineDetail.ItemRef.value');
      if (pid != null) {
        qboProdIds.add(String.valueOf(pid));
      }
      Object pName = readPath(raw, 'SalesItemLineDetail.ItemRef.name');
      if (pName != null) {
        prodNames.add(String.valueOf(pName));
      }
    }

    Map<String, Product2> prodByQboId = new Map<String, Product2>();
    Map<String, Product2> prodByName = new Map<String, Product2>();
    if (!qboProdIds.isEmpty() || !prodNames.isEmpty()) {
      for (Product2 p : [
        SELECT Id, Name, QuickbookID__c, IsActive
        FROM Product2
        WHERE QuickbookID__c IN :qboProdIds OR Name IN :prodNames
      ]) {
        if (String.isNotBlank(p.QuickbookID__c)) {
          prodByQboId.put(p.QuickbookID__c, p);
        }
        if (String.isNotBlank(p.Name)) {
          prodByName.put(p.Name.toLowerCase(), p);
        }
      }
    }

    for (Integer i = 0; i < childRecords.size(); i++) {
      SObject item = childRecords[i];
      Map<String, Object> raw = childRaws[i];
      Object pid = readPath(raw, 'SalesItemLineDetail.ItemRef.value');
      Object pName = readPath(raw, 'SalesItemLineDetail.ItemRef.name');
      Product2 matched = null;
      if (pid != null && prodByQboId.containsKey(String.valueOf(pid))) {
        matched = prodByQboId.get(String.valueOf(pid));
      } else if (pName != null && prodByName.containsKey(String.valueOf(pName).toLowerCase())) {
        matched = prodByName.get(String.valueOf(pName).toLowerCase());
      }
      if (matched != null) {
        item.put('Product__c', matched.Id);
      }
    }

    // 3. External ID cross-invoice uniqueness guard
    Set<String> lineExtIds = new Set<String>();
    for (SObject item : childRecords) {
      Object extVal = item.get('External_Id__c');
      if (extVal != null) {
        lineExtIds.add(String.valueOf(extVal));
      }
    }
    if (!lineExtIds.isEmpty()) {
      Map<String, Invoice_Line__c> existingByExtId = new Map<String, Invoice_Line__c>();
      for (Invoice_Line__c existingItem : [
        SELECT Id, Invoice__c, External_Id__c
        FROM Invoice_Line__c
        WHERE External_Id__c IN :lineExtIds
      ]) {
        if (String.isNotBlank(existingItem.External_Id__c)) {
          existingByExtId.put(existingItem.External_Id__c, existingItem);
        }
      }
      for (SObject item : childRecords) {
        Object extVal = item.get('External_Id__c');
        if (extVal == null) continue;
        String sExt = String.valueOf(extVal);
        Id currentInvoiceId = (Id) item.get('Invoice__c');
        if (existingByExtId.containsKey(sExt)) {
          Invoice_Line__c existingItem = existingByExtId.get(sExt);
          if (existingItem.Invoice__c == currentInvoiceId) {
            item.Id = existingItem.Id;
          } else {
            item.put('External_Id__c', String.valueOf(currentInvoiceId) + '_' + sExt);
          }
        }
      }
    }
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
    Schema.SObjectType objectType = records[0].getSObjectType();
    Map<String, Schema.SObjectField> fields = objectType.getDescribe().fields.getMap();
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
        if (value == null && parsed instanceof Map<String, Object>) {
          Map<String, Object> rootMap = (Map<String, Object>) parsed;
          for (String rk : rootMap.keySet()) {
            if (rootMap.get(rk) instanceof Map<String, Object>) {
              value = readPath(rootMap.get(rk), mapping.externalPath);
              if (value != null) break;
            }
          }
        }
        value = transform(value, mapping.transform);
        if (value != null || normalize(mapping.nullBehavior) == 'include') {
          putCoerced(updateRecord, mapping.salesforceField, value, fields);
        }
      }
      if (
        String.isNotBlank(definition.responseIdPath) &&
        String.isNotBlank(definition.salesforceExternalIdField) &&
        parsed != null
      ) {
        Object externalId = readPath(parsed, definition.responseIdPath);
        if (externalId != null) {
          putCoerced(
            updateRecord,
            definition.salesforceExternalIdField,
            String.valueOf(externalId),
            fields
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
    List<SObject> childUpdates = new List<SObject>();
    List<ChildCollectionGroup> childGroups = resolveChildCollectionGroups(definition);
    if (!childGroups.isEmpty()) {
      Set<Id> parentIds = new Set<Id>();
      for (SObject rec : records) {
        if (rec.Id != null) parentIds.add(rec.Id);
      }
      Map<String, Map<Id, List<SObject>>> childData = queryChildCollections(childGroups, parentIds);
      for (ChildCollectionGroup groupItem : childGroups) {
        String idField = null;
        for (MappingRule rule : groupItem.mappings) {
          if (String.isNotBlank(rule.externalPath) && (rule.externalPath.equalsIgnoreCase('Id') || rule.externalPath.equalsIgnoreCase('Line.Id'))) {
            idField = rule.salesforceField;
            break;
          }
        }
        if (String.isNotBlank(idField)) {
          Map<Id, List<SObject>> byParent = childData.get(groupItem.collectionPath);
          for (Integer i = 0; i < records.size(); i++) {
            SObject parentRec = records[i];
            List<SObject> children = (byParent != null && parentRec.Id != null) ? byParent.get(parentRec.Id) : null;
            if (children == null || children.isEmpty()) continue;
            String responseBody = (responseBodies != null && responseBodies.size() > i) ? responseBodies[i] : null;
            Object parsed = String.isBlank(responseBody) ? null : parseJson(responseBody);
            if (parsed == null) continue;
            Object rawLines = readPath(parsed, groupItem.collectionPath);
            if (rawLines == null && parsed instanceof Map<String, Object>) {
              Map<String, Object> rootMap = (Map<String, Object>) parsed;
              for (String rootKey : rootMap.keySet()) {
                Object childObj = rootMap.get(rootKey);
                if (childObj instanceof Map<String, Object>) {
                  rawLines = readPath(childObj, groupItem.collectionPath);
                  if (rawLines != null) break;
                }
              }
            }
            List<Object> lineItems = (rawLines instanceof List<Object>) ? (List<Object>) rawLines : (rawLines != null ? new List<Object>{ rawLines } : new List<Object>());
            Integer lineIdx = 0;
            for (Object lineObj : lineItems) {
              if (lineIdx >= children.size()) break;
              if (lineObj instanceof Map<String, Object>) {
                Map<String, Object> lineMap = (Map<String, Object>) lineObj;
                String detailType = (String) lineMap.get('DetailType');
                if (String.isNotBlank(detailType) && detailType.equalsIgnoreCase('SubTotalLineDetail')) {
                  continue;
                }
                Object lineIdVal = lineMap.get('Id');
                if (lineIdVal != null) {
                  SObject childUpdate = children[lineIdx].getSObjectType().newSObject(children[lineIdx].Id);
                  childUpdate.put(idField, String.valueOf(lineIdVal));
                  childUpdates.add(childUpdate);
                  lineIdx++;
                }
              }
            }
          }
        }
      }
    }
    if (!childUpdates.isEmpty()) {
      SObjectAccessDecision childDecision = Security.stripInaccessible(AccessType.UPDATABLE, childUpdates);
      Database.update(childDecision.getRecords(), false);
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
    if (String.isNotBlank(mapping.salesforceField)) {
      if (!mapping.salesforceField.contains('.')) {
        resolveFieldName(fields, mapping.salesforceField);
      }
    }
    validatePath(mapping.externalPath, 'mapping external path', true);
    Boolean isConstant = String.isNotBlank(mapping.transform) && mapping.transform.toLowerCase().startsWith('constant:');
    if (
      !SUPPORTED_TRANSFORMS.contains(normalize(mapping.transform)) &&
      !isConstant
    ) {
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

  public static Object transform(Object value, String transformName) {
    if (value == null) {
      return null;
    }
    if (String.isNotBlank(transformName) && transformName.toLowerCase().startsWith('constant:')) {
      return transformName.substring(9);
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

  public static void putCoerced(
    SObject target,
    String fieldName,
    Object value,
    Map<String, Schema.SObjectField> fields
  ) {
    if (value == null) {
      target.put(fieldName, null);
      return;
    }
    Schema.SObjectField field = fields != null
      ? fields.get(fieldName.toLowerCase())
      : null;
    if (field == null) {
      target.put(fieldName, value);
      return;
    }
    Schema.DescribeFieldResult dfr = field.getDescribe();
    if (target.Id != null && !dfr.isUpdateable()) {
      return;
    }
    if (target.Id == null && !dfr.isCreateable()) {
      return;
    }
    Schema.DisplayType dt = dfr.getType();
    if (dt == Schema.DisplayType.DATE) {
      if (value instanceof Date) {
        target.put(fieldName, value);
      } else if (value instanceof Datetime) {
        target.put(fieldName, ((Datetime) value).dateGmt());
      } else if (value instanceof String) {
        String strVal = (String) value;
        if (strVal.contains('T')) {
          strVal = strVal.substringBefore('T');
        }
        target.put(fieldName, Date.valueOf(strVal));
      } else {
        target.put(fieldName, value);
      }
    } else if (dt == Schema.DisplayType.DATETIME) {
      if (value instanceof Datetime) {
        target.put(fieldName, value);
      } else if (value instanceof Date) {
        target.put(fieldName, Datetime.newInstance((Date) value, Time.newInstance(0, 0, 0, 0)));
      } else if (value instanceof String) {
        String strVal = (String) value;
        if (!strVal.contains('T') && strVal.length() == 10) {
          target.put(fieldName, Datetime.newInstance(Date.valueOf(strVal), Time.newInstance(0, 0, 0, 0)));
        } else {
          target.put(fieldName, (Datetime) JSON.deserialize('"' + strVal + '"', Datetime.class));
        }
      } else {
        target.put(fieldName, value);
      }
    } else if (
      dt == Schema.DisplayType.DOUBLE ||
      dt == Schema.DisplayType.CURRENCY ||
      dt == Schema.DisplayType.PERCENT
    ) {
      if (value instanceof Decimal) {
        target.put(fieldName, value);
      } else if (value instanceof Integer) {
        target.put(fieldName, Decimal.valueOf((Integer) value));
      } else if (value instanceof Double) {
        target.put(fieldName, Decimal.valueOf((Double) value));
      } else if (value instanceof String) {
        target.put(fieldName, Decimal.valueOf((String) value));
      } else {
        target.put(fieldName, value);
      }
    } else if (dt == Schema.DisplayType.INTEGER) {
      if (value instanceof Integer) {
        target.put(fieldName, value);
      } else if (value instanceof Decimal) {
        target.put(fieldName, ((Decimal) value).intValue());
      } else if (value instanceof String) {
        target.put(fieldName, Integer.valueOf((String) value));
      } else {
        target.put(fieldName, value);
      }
    } else if (dt == Schema.DisplayType.BOOLEAN) {
      if (value instanceof Boolean) {
        target.put(fieldName, value);
      } else if (value instanceof String) {
        target.put(fieldName, Boolean.valueOf((String) value));
      } else {
        target.put(fieldName, value);
      }
    } else if (
      dt == Schema.DisplayType.STRING ||
      dt == Schema.DisplayType.TEXTAREA ||
      dt == Schema.DisplayType.PICKLIST
    ) {
      target.put(fieldName, String.valueOf(value));
    } else if (dt == Schema.DisplayType.REFERENCE) {
      if (value instanceof Id) {
        target.put(fieldName, value);
      } else if (value instanceof String) {
        String strVal = (String) value;
        if (Pattern.matches('^[a-zA-Z0-9]{15}(?:[a-zA-Z0-9]{3})?$', strVal)) {
          try {
            target.put(fieldName, (Id) strVal);
          } catch (Exception ex) {}
        }
      }
    } else {
      target.put(fieldName, value);
    }
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

  public static Schema.DescribeFieldResult resolveReadableFieldPath(
    Schema.SObjectType objectType,
    String fieldPath
  ) {
    if (objectType == null || String.isBlank(fieldPath)) {
      throw new GenericIntegrationRuntimeException('Invalid field path or object type.');
    }
    List<String> parts = fieldPath.split('\\.');
    Schema.SObjectType currentType = objectType;
    Schema.DescribeFieldResult finalDescribe = null;

    for (Integer i = 0; i < parts.size(); i++) {
      String part = parts[i].trim();
      Map<String, Schema.SObjectField> fieldMap = currentType.getDescribe().fields.getMap();
      Schema.SObjectField field = null;

      if (fieldMap.containsKey(part)) {
        field = fieldMap.get(part);
      } else {
        String candidateName = part;
        if (candidateName.endsWith('__r')) {
          candidateName = candidateName.substring(0, candidateName.length() - 3) + '__c';
        } else if (!candidateName.endsWith('Id')) {
          candidateName = candidateName + 'Id';
        }
        if (fieldMap.containsKey(candidateName)) {
          field = fieldMap.get(candidateName);
        } else {
          for (String fn : fieldMap.keySet()) {
            if (fn.equalsIgnoreCase(part) || fn.equalsIgnoreCase(candidateName)) {
              field = fieldMap.get(fn);
              break;
            }
          }
        }
      }

      if (field == null) {
        throw new GenericIntegrationRuntimeException(
          'Field or relationship ' + part + ' is unavailable on ' + currentType.getDescribe().getName()
        );
      }

      Schema.DescribeFieldResult dfr = field.getDescribe();
      if (!dfr.isAccessible()) {
        throw new GenericIntegrationRuntimeException(
          'Field ' + part + ' is not accessible on ' + currentType.getDescribe().getName()
        );
      }

      if (i == parts.size() - 1) {
        finalDescribe = dfr;
      } else {
        List<Schema.SObjectType> refTypes = dfr.getReferenceTo();
        if (refTypes.isEmpty()) {
          throw new GenericIntegrationRuntimeException(
            'Field ' + part + ' on ' + currentType.getDescribe().getName() + ' is not a relationship field.'
          );
        }
        currentType = refTypes[0];
      }
    }
    return finalDescribe;
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
    result.resourceContractJson = source.resourceContractJson;
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

  public static String normalize(String value) {
    return String.isBlank(value) ? '' : value.toLowerCase().replaceAll('[^a-z0-9]', '');
  }

  public class GenericIntegrationRuntimeException extends Exception {}
}