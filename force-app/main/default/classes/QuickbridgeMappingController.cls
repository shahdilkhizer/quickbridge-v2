public with sharing class QuickbridgeMappingController {
  private static final Set<String> SUPPORTED_DIRECTIONS = new Set<String>{
    'Inbound',
    'Outbound',
    'Both'
  };
  private static final Pattern SAFE_TOKEN = Pattern.compile('^[A-Za-z][A-Za-z0-9_]{0,119}$');
  private static final Pattern SAFE_EXTERNAL_PATH = Pattern.compile(
    '^[A-Za-z_$][A-Za-z0-9_$-]*(?:\\[[0-9]*\\])?(?:\\.[A-Za-z_$][A-Za-z0-9_$-]*(?:\\[[0-9]*\\])?)*$'
  );

  @TestVisible private static Boolean bypassSecurityForTests = false;
  @TestVisible private static Metadata.DeployContainer lastSaveContainer;

  public class MappingWorkspace {
    @AuraEnabled public String connectorKey;
    @AuraEnabled public String connectorLabel;
    @AuraEnabled public List<OperationWorkspace> operations = new List<OperationWorkspace>();
  }

  public class OperationWorkspace {
    @AuraEnabled public String workspaceKey;
    @AuraEnabled public Boolean runOnRecordSave;
    @AuraEnabled public Boolean supportsRunOnRecordSave;
    @AuraEnabled public String operationKey;
    @AuraEnabled public String label;
    @AuraEnabled public String direction;
    @AuraEnabled public String salesforceObject;
    @AuraEnabled public String salesforceObjectLabel;
    @AuraEnabled public String externalObject;
    @AuraEnabled public List<SelectOption> salesforceFields = new List<SelectOption>();
    @AuraEnabled public List<SelectOption> externalFields = new List<SelectOption>();
    @AuraEnabled public List<MappingRow> mappings = new List<MappingRow>();
    @AuraEnabled public Boolean hasLineItems = false;
    @AuraEnabled public String childObjectLabel;
    @AuraEnabled public String collectionPath;
    @AuraEnabled public List<SelectOption> lineFields = new List<SelectOption>();
  }

  public class SelectOption implements Comparable {
    @AuraEnabled public String label;
    @AuraEnabled public String value;

    public SelectOption(String labelValue, String apiValue) {
      label = labelValue;
      value = apiValue;
    }

    public Integer compareTo(Object other) {
      SelectOption right = (SelectOption) other;
      return label.toLowerCase().compareTo(right.label.toLowerCase());
    }
  }

  public class MappingRow {
    @AuraEnabled public String developerName;
    @AuraEnabled public String salesforceField;
    @AuraEnabled public String externalPath;
    @AuraEnabled public String direction;
    @AuraEnabled public Boolean active;
    @AuraEnabled public Boolean required;
    @AuraEnabled public String source;
    @AuraEnabled public Boolean isLine = false;
    @AuraEnabled public String salesforceObject;
    @AuraEnabled public String collectionPath;
  }

  public class MappingInput {
    public String salesforceField;
    public String externalPath;
    public String direction;
    public Boolean active;
    public Boolean isLine;
    public String salesforceObject;
  }

  public class SaveRequest {
    public String connectorKey;
    public String operationKey;
    public String operationDirection;
    public String salesforceObject;
    public String externalObject;
    public List<MappingInput> rows;
    public Boolean runOnRecordSave;
  }

  public class SaveResponse {
    @AuraEnabled public String deploymentId;
    @AuraEnabled public String status;
    @AuraEnabled public Integer submittedCount;
  }

  public class DeploymentStatus {
    @AuraEnabled public String deploymentId;
    @AuraEnabled public String status;
    @AuraEnabled public String message;
  }

  @AuraEnabled(cacheable=true)
  public static MappingWorkspace getMappingWorkspace(String connectorKey) {
    assertReadAccess();
    Integration_Connector__mdt connector = requireConnector(connectorKey);
    String normalizedConnector = normalize(connector.Connector_Key__c);
    List<Integration_Operation__mdt> operationDefinitions = [
      SELECT DeveloperName, MasterLabel, Connector_Key__c, Operation_Key__c,
        Direction__c, Salesforce_Object__c, External_Entity__c, Active__c, Run_On_Record_Save__c
      FROM Integration_Operation__mdt
      WHERE Connector_Key__c = :normalizedConnector AND Active__c = true
      ORDER BY MasterLabel, Direction__c
    ];

    Set<String> operationKeys = new Set<String>();
    Set<String> connectorAliases = aliasesFor(normalizedConnector);
    for (Integration_Operation__mdt operation : operationDefinitions) {
      operationKeys.add(operation.Operation_Key__c);
    }
    List<Integration_Operation_Mapping__mdt> defaults = operationKeys.isEmpty()
      ? new List<Integration_Operation_Mapping__mdt>()
      : [
        SELECT Operation_Key__c, Direction__c, Salesforce_Object__c,
          Salesforce_Field__c, External_Path__c, Required__c, Sort_Order__c, Collection_Path__c
        FROM Integration_Operation_Mapping__mdt
        WHERE Connector_Key__c = :normalizedConnector
          AND Operation_Key__c IN :operationKeys
          AND Active__c = true
        ORDER BY Sort_Order__c, Salesforce_Field__c
      ];
    List<Field_Mapping__mdt> overrides = [
      SELECT DeveloperName, Integration__c, Action__c, SF_Object__c,
        SF_Field__c, External_Field__c, Sync_Direction__c, Is_Active__c
      FROM Field_Mapping__mdt
      WHERE Integration__c IN :connectorAliases
      ORDER BY SF_Object__c, SF_Field__c
    ];

    Map<String, List<Integration_Operation_Mapping__mdt>> defaultsByOperation =
      new Map<String, List<Integration_Operation_Mapping__mdt>>();
    for (Integration_Operation_Mapping__mdt row : defaults) {
      if (!defaultsByOperation.containsKey(row.Operation_Key__c)) {
        defaultsByOperation.put(
          row.Operation_Key__c,
          new List<Integration_Operation_Mapping__mdt>()
        );
      }
      defaultsByOperation.get(row.Operation_Key__c).add(row);
    }

    MappingWorkspace workspace = new MappingWorkspace();
    workspace.connectorKey = normalizedConnector;
    workspace.connectorLabel = connector.Provider_Label__c;
    for (Integration_Operation__mdt operation : operationDefinitions) {
      OperationWorkspace item = new OperationWorkspace();
      item.operationKey = operation.Operation_Key__c;
      item.label = operation.MasterLabel;
      item.direction = normalizeDirection(operation.Direction__c);
      item.workspaceKey = item.operationKey + '|' + item.direction;
      item.supportsRunOnRecordSave = IntegrationEventApi.supportsRecordSave(normalizedConnector, item.direction);
      item.runOnRecordSave = item.supportsRunOnRecordSave && operation.Run_On_Record_Save__c == true;
      item.salesforceObject = stripNamespace(operation.Salesforce_Object__c);
      item.externalObject = operation.External_Entity__c;
      populateSalesforceFields(
        item,
        defaultsByOperation.get(operation.Operation_Key__c)
      );
      populateMappings(
        item,
        defaultsByOperation.get(operation.Operation_Key__c),
        overrides
      );
      workspace.operations.add(item);
    }
    return workspace;
  }

  @AuraEnabled
  public static SaveResponse saveMappings(String requestJson) {
    assertAdminAccess();
    SaveRequest request = parseRequest(requestJson);
    if (request.runOnRecordSave != null && String.isBlank(request.operationDirection)) {
      throw handled('Select an operation direction before changing record-save synchronization.');
    }
    Integration_Operation__mdt operation = requireOperation(
      request.connectorKey,
      request.operationKey,
      request.operationDirection
    );
    validateOperationIdentity(request, operation);
    if (request.runOnRecordSave != null) {
      QuickbridgeAdminSecurity.requireManage();
      if (!IntegrationEventApi.supportsRecordSave(operation.Connector_Key__c, operation.Direction__c)) {
        throw handled('Run sync on record save requires a supported outbound operation.');
      }
    }
    Schema.SObjectType objectType = requireObject(request.salesforceObject);
    Map<String, Map<String, Schema.SObjectField>> fieldsByObject = new Map<String, Map<String, Schema.SObjectField>>();
    Map<String, Schema.SObjectField> parentFields = objectType.getDescribe().fields.getMap();
    fieldsByObject.put(stripNamespace(request.salesforceObject).toLowerCase(), parentFields);

    Map<String, Schema.SObjectField> fields = new Map<String, Schema.SObjectField>(parentFields);
    Map<String, String> fieldToObjectMap = new Map<String, String>();
    for (String fieldName : parentFields.keySet()) {
      fieldToObjectMap.put(fieldName.toLowerCase(), stripNamespace(request.salesforceObject));
    }
    List<Integration_Operation_Mapping__mdt> opDefaults = [
      SELECT Salesforce_Object__c
      FROM Integration_Operation_Mapping__mdt
      WHERE
        Connector_Key__c = :operation.Connector_Key__c
        AND Operation_Key__c = :operation.Operation_Key__c
        AND Active__c = true
    ];
    for (Integration_Operation_Mapping__mdt defRow : opDefaults) {
      if (
        String.isNotBlank(defRow.Salesforce_Object__c) &&
        !same(defRow.Salesforce_Object__c, request.salesforceObject)
      ) {
        Schema.SObjectType childType = ConnectorExecutionRequest.resolveSObjectType(
          defRow.Salesforce_Object__c
        );
        if (childType != null && childType.getDescribe().isAccessible()) {
          Map<String, Schema.SObjectField> childFields = childType.getDescribe().fields.getMap();
          fieldsByObject.put(stripNamespace(defRow.Salesforce_Object__c).toLowerCase(), childFields);
          for (String childFieldName : childFields.keySet()) {
            if (!fields.containsKey(childFieldName)) {
              fields.put(childFieldName, childFields.get(childFieldName));
            }
            if (!fieldToObjectMap.containsKey(childFieldName.toLowerCase())) {
              fieldToObjectMap.put(childFieldName.toLowerCase(), stripNamespace(defRow.Salesforce_Object__c));
            }
          }
        }
      }
    }
    if (request.rows == null) request.rows = new List<MappingInput>();
    if (request.rows.size() > 200 || (request.rows.isEmpty() && request.runOnRecordSave == null)) {
      throw handled('Submit between 1 and 200 mapping rows or a record-save setting.');
    }

    Metadata.DeployContainer container = new Metadata.DeployContainer();
    Set<String> identities = new Set<String>();
    Integer submitted = 0;
    for (MappingInput row : request.rows) {
      if (String.isNotBlank(request.operationDirection)) {
        row.direction = request.operationDirection;
      }
      String targetObj = (row.isLine == true && String.isNotBlank(row.salesforceObject))
        ? row.salesforceObject
        : request.salesforceObject;
      Map<String, Schema.SObjectField> targetFields = fieldsByObject.get(stripNamespace(targetObj).toLowerCase());
      if (targetFields == null) {
        targetFields = fields;
      }
      validateRow(row, targetFields, targetObj, request.operationDirection);
      String identity = mappingIdentity(request, row);
      if (!identities.add(identity)) {
        throw handled('Duplicate mapping rows are not allowed.');
      }
      container.addMetadata(toMetadata(request, row, identity, fieldToObjectMap));
      submitted++;
    }

    if (request.runOnRecordSave != null) {
      Metadata.CustomMetadata setting = new Metadata.CustomMetadata();
      setting.fullName = 'Integration_Operation__mdt.' + operation.DeveloperName;
      setting.label = operation.MasterLabel;
      // A partial metadata update preserves endpoint, direction, and all other operation values.
      addValue(setting, 'Run_On_Record_Save__c', request.runOnRecordSave);
      container.addMetadata(setting);
      submitted++;
    }
    SaveResponse response = new SaveResponse();
    response.submittedCount = submitted;
    if (Test.isRunningTest()) {
      lastSaveContainer = container;
      response.deploymentId = 'TEST-MAPPING-DEPLOYMENT';
      response.status = 'Succeeded';
      return response;
    }
    Id deploymentId = Metadata.Operations.enqueueDeployment(
      container,
      new MappingDeployCallback()
    );
    response.deploymentId = String.valueOf(deploymentId);
    response.status = 'Queued';
    cacheDeploymentStatus(response.deploymentId, 'Queued');
    return response;
  }

  @AuraEnabled
  public static SaveResponse clearMappings(
    String connectorKey,
    String operationKey,
    String salesforceObject,
    String externalObject,
    String direction
  ) {
    assertAdminAccess();
    Integration_Operation__mdt operation = requireOperation(
      connectorKey,
      operationKey,
      direction
    );
    if (
      !same(operation.Salesforce_Object__c, salesforceObject) ||
      !same(operation.External_Entity__c, externalObject)
    ) {
      throw handled('The mapping selection does not match the configured operation.');
    }
    Set<String> aliases = aliasesFor(normalize(connectorKey));
    List<Field_Mapping__mdt> existing = [
      SELECT DeveloperName, Action__c, SF_Object__c
      FROM Field_Mapping__mdt
      WHERE Integration__c IN :aliases AND Is_Active__c = true
    ];
    Metadata.DeployContainer container = new Metadata.DeployContainer();
    Integer submitted = 0;
    for (Field_Mapping__mdt row : existing) {
      if (!same(row.SF_Object__c, salesforceObject)) continue;
      if (
        String.isNotBlank(row.Action__c) &&
        !same(row.Action__c, operationKey) &&
        !same(row.Action__c, externalObject)
      ) continue;
      Metadata.CustomMetadata record = new Metadata.CustomMetadata();
      record.fullName = 'Field_Mapping__mdt.' + row.DeveloperName;
      record.label = row.DeveloperName.left(40);
      addValue(record, 'Is_Active__c', false);
      container.addMetadata(record);
      submitted++;
    }
    SaveResponse response = new SaveResponse();
    response.submittedCount = submitted;
    if (submitted == 0) {
      response.status = 'Succeeded';
      return response;
    }
    if (Test.isRunningTest()) {
      response.deploymentId = 'TEST-MAPPING-CLEAR';
      response.status = 'Succeeded';
      return response;
    }
    Id deploymentId = Metadata.Operations.enqueueDeployment(
      container,
      new MappingDeployCallback()
    );
    response.deploymentId = String.valueOf(deploymentId);
    response.status = 'Queued';
    cacheDeploymentStatus(response.deploymentId, 'Queued');
    return response;
  }

  @AuraEnabled(cacheable=false)
  public static DeploymentStatus getDeploymentStatus(String deploymentId) {
    assertReadAccess();
    DeploymentStatus response = new DeploymentStatus();
    response.deploymentId = deploymentId;
    if (String.isBlank(deploymentId)) {
      response.status = 'Succeeded';
      response.message = 'No metadata changes were required.';
      return response;
    }
    Object cached = getCachedDeploymentStatus(deploymentId);
    response.status = cached == null ? 'Unknown' : String.valueOf(cached);
    if (response.status != 'Succeeded' && response.status != 'Failed') {
      // Cache is optional and can expire; the callback also records a durable outcome.
      List<Quickbridge_Admin_Audit__c> outcomes = [
        SELECT Status__c FROM Quickbridge_Admin_Audit__c
        WHERE Action__c = 'MAPPING_DEPLOYMENT' AND Related_Record_Id__c = :deploymentId
        WITH SECURITY_ENFORCED ORDER BY CreatedDate DESC LIMIT 1
      ];
      if (!outcomes.isEmpty()) response.status = outcomes[0].Status__c;
    }
    response.message = response.status == 'Failed'
      ? 'The mapping metadata deployment failed. Review the sanitized error log.'
      : 'Mapping metadata deployment is ' + response.status.toLowerCase() + '.';
    return response;
  }

  public class MappingDeployCallback implements Metadata.DeployCallback {
    public void handleResult(
      Metadata.DeployResult result,
      Metadata.DeployCallbackContext context
    ) {
      String deploymentId = result == null ? null : String.valueOf(result.id);
      String status = result != null && result.status == Metadata.DeployStatus.Succeeded
        ? 'Succeeded'
        : 'Failed';
      if (String.isNotBlank(deploymentId)) {
        cacheDeploymentStatus(deploymentId, status);
        QuickbridgeAdminSecurity.audit('MAPPING_DEPLOYMENT', null, status, null, result.id);
      }
      if (status == 'Failed') {
        logDeploymentFailure(deploymentId, result);
      }
    }
  }

  private static void cacheDeploymentStatus(String deploymentId, String status) {
    if (String.isBlank(deploymentId)) return;
    try {
      Cache.Org.put(cacheKey(deploymentId), status, 3600);
    } catch (Exception ignored) {
      // Platform Cache is optional. Metadata deployment remains authoritative.
    }
  }

  private static Object getCachedDeploymentStatus(String deploymentId) {
    try {
      return Cache.Org.get(cacheKey(deploymentId));
    } catch (Exception ignored) {
      return null;
    }
  }

  private static void populateSalesforceFields(
    OperationWorkspace item,
    List<Integration_Operation_Mapping__mdt> defaults
  ) {
    Schema.SObjectType objectType = requireObject(item.salesforceObject);
    Schema.DescribeSObjectResult describeResult = objectType.getDescribe();
    if (!describeResult.isAccessible()) {
      throw handled('The selected Salesforce object is not accessible.');
    }
    item.salesforceObjectLabel = describeResult.getLabel();
    Boolean allowCalculated = (item.direction == 'Outbound');
    for (Schema.SObjectField fieldToken : describeResult.fields.getMap().values()) {
      Schema.DescribeFieldResult field = fieldToken.getDescribe();
      if (
        field.isAccessible() &&
        (allowCalculated || !field.isCalculated()) &&
        field.getType() != Schema.DisplayType.Address &&
        field.getType() != Schema.DisplayType.Location
      ) {
        item.salesforceFields.add(
          new SelectOption(field.getLabel() + ' (' + field.getName() + ')', field.getName())
        );
      }
    }
    item.salesforceFields.sort();

    Set<String> childObjects = new Set<String>();
    if (defaults != null) {
      for (Integration_Operation_Mapping__mdt defRow : defaults) {
        if (
          String.isNotBlank(defRow.Salesforce_Object__c) &&
          !same(defRow.Salesforce_Object__c, item.salesforceObject)
        ) {
          childObjects.add(stripNamespace(defRow.Salesforce_Object__c));
          if (String.isNotBlank(defRow.Collection_Path__c) && String.isBlank(item.collectionPath)) {
            item.collectionPath = defRow.Collection_Path__c;
          }
        }
      }
    }
    for (String childObjectName : childObjects) {
      Schema.SObjectType childType = ConnectorExecutionRequest.resolveSObjectType(childObjectName);
      if (childType != null && childType.getDescribe().isAccessible()) {
        Schema.DescribeSObjectResult childDescribe = childType.getDescribe();
        item.hasLineItems = true;
        if (String.isBlank(item.childObjectLabel)) {
          item.childObjectLabel = childDescribe.getLabel();
        }
        for (Schema.SObjectField fieldToken : childDescribe.fields.getMap().values()) {
          Schema.DescribeFieldResult field = fieldToken.getDescribe();
          if (
            field.isAccessible() &&
            (allowCalculated || !field.isCalculated()) &&
            field.getType() != Schema.DisplayType.Address &&
            field.getType() != Schema.DisplayType.Location
          ) {
            item.lineFields.add(
              new SelectOption(field.getLabel() + ' (' + field.getName() + ')', field.getName())
            );
          }
        }
      }
    }
    item.lineFields.sort();
  }

  private static void populateMappings(
    OperationWorkspace item,
    List<Integration_Operation_Mapping__mdt> defaults,
    List<Field_Mapping__mdt> overrides
  ) {
    Map<String, MappingRow> byKey = new Map<String, MappingRow>();
    Set<String> externalPaths = new Set<String>();
    Set<String> childObjects = new Set<String>();
    if (defaults != null) {
      for (Integration_Operation_Mapping__mdt row : defaults) {
        Boolean isChild = !same(row.Salesforce_Object__c, item.salesforceObject);
        if (isChild) {
          if (String.isBlank(row.Collection_Path__c)) {
            continue;
          }
          childObjects.add(normalize(stripNamespace(row.Salesforce_Object__c)));
        }
        MappingRow mapping = new MappingRow();
        mapping.salesforceField = stripNamespace(row.Salesforce_Field__c);
        mapping.externalPath = row.External_Path__c;
        mapping.direction = normalizeDirection(row.Direction__c);
        if (
          mapping.direction != 'Both' &&
          mapping.direction != item.direction
        ) continue;
        if (item.direction == 'Outbound' || item.direction == 'Inbound') {
          mapping.direction = item.direction;
        }
        mapping.active = true;
        mapping.required = row.Required__c == true;
        mapping.source = 'Default';
        if (isChild) {
          mapping.isLine = true;
          mapping.salesforceObject = stripNamespace(row.Salesforce_Object__c);
          mapping.collectionPath = row.Collection_Path__c;
          item.hasLineItems = true;
        } else {
          mapping.isLine = false;
          mapping.salesforceObject = stripNamespace(item.salesforceObject);
        }
        byKey.put(rowKey(mapping.salesforceObject, mapping.salesforceField, item.direction), mapping);
        if (String.isNotBlank(mapping.externalPath)) externalPaths.add(mapping.externalPath);
      }
    }
    for (Field_Mapping__mdt row : overrides) {
      Boolean isChild = !same(row.SF_Object__c, item.salesforceObject);
      if (
        isChild &&
        !childObjects.contains(normalize(stripNamespace(row.SF_Object__c)))
      ) {
        continue;
      }
      if (
        String.isNotBlank(row.Action__c) &&
        !same(row.Action__c, item.operationKey) &&
        !same(row.Action__c, item.externalObject)
      ) continue;
      MappingRow mapping = new MappingRow();
      mapping.developerName = row.DeveloperName;
      mapping.salesforceField = stripNamespace(row.SF_Field__c);
      mapping.externalPath = row.External_Field__c;
      mapping.direction = normalizeDirection(row.Sync_Direction__c);
      if (
        mapping.direction != 'Both' &&
        mapping.direction != item.direction
      ) continue;
      if (item.direction == 'Outbound' || item.direction == 'Inbound') {
        mapping.direction = item.direction;
      }
      mapping.active = row.Is_Active__c == true;
      mapping.required = false;
      mapping.source = 'Override';
      if (isChild) {
        mapping.isLine = true;
        mapping.salesforceObject = stripNamespace(row.SF_Object__c);
        mapping.collectionPath = item.collectionPath;
        item.hasLineItems = true;
      } else {
        mapping.isLine = false;
        mapping.salesforceObject = stripNamespace(item.salesforceObject);
      }
      if (mapping.active) {
        byKey.put(rowKey(mapping.salesforceObject, mapping.salesforceField, item.direction), mapping);
      }
      if (String.isNotBlank(mapping.externalPath)) externalPaths.add(mapping.externalPath);
    }
    item.mappings.addAll(byKey.values());
    for (String externalPath : externalPaths) {
      item.externalFields.add(new SelectOption(externalPath, externalPath));
    }
    item.externalFields.sort();
  }

  private static SaveRequest parseRequest(String requestJson) {
    if (String.isBlank(requestJson) || requestJson.length() > 100000) {
      throw handled('Mapping request is missing or too large.');
    }
    try {
      SaveRequest request = (SaveRequest) JSON.deserialize(
        requestJson,
        SaveRequest.class
      );
      if (request == null) throw new MappingException();
      request.connectorKey = normalize(request.connectorKey);
      return request;
    } catch (Exception ignored) {
      throw handled('Mapping request is invalid.');
    }
  }

  private static void validateOperationIdentity(
    SaveRequest request,
    Integration_Operation__mdt operation
  ) {
    if (
      !same(operation.Salesforce_Object__c, request.salesforceObject) ||
      !same(operation.External_Entity__c, request.externalObject)
    ) {
      throw handled('The mapping selection does not match the configured operation.');
    }
  }

  private static void validateRow(
    MappingInput row,
    Map<String, Schema.SObjectField> fields,
    String objectName,
    String operationDirection
  ) {
    if (row == null || !SUPPORTED_DIRECTIONS.contains(normalizeDirection(row.direction))) {
      throw handled('Mapping direction is invalid.');
    }
    String fieldName = stripNamespace(row.salesforceField);
    if (!SAFE_TOKEN.matcher(fieldName).matches() || !fields.containsKey(fieldName)) {
      throw handled('A selected Salesforce field is invalid.');
    }
    Schema.DescribeFieldResult field = fields.get(fieldName).getDescribe();
    if (!field.isAccessible()) {
      throw handled('The selected Salesforce field is not accessible: ' + objectName + '.' + fieldName);
    }
    String direction = normalizeDirection(row.direction);
    String opDirection = normalizeDirection(operationDirection);
    Boolean isOutbound = (direction == 'Outbound' || opDirection == 'Outbound');
    if (!isOutbound && !field.isCreateable() && !field.isUpdateable()) {
      throw handled('The selected Salesforce field is not editable: ' + objectName + '.' + fieldName);
    }
    if (
      String.isBlank(row.externalPath) ||
      row.externalPath.length() > 255 ||
      !SAFE_EXTERNAL_PATH.matcher(row.externalPath).matches()
    ) {
      throw handled('External field paths may contain only validated path segments and numeric indexes.');
    }
  }

  private static Metadata.CustomMetadata toMetadata(
    SaveRequest request,
    MappingInput row,
    String identity,
    Map<String, String> fieldToObjectMap
  ) {
    Metadata.CustomMetadata record = new Metadata.CustomMetadata();
    record.fullName = 'Field_Mapping__mdt.QB_' + digest(identity);
    record.label = (
      request.connectorKey + ' ' + request.operationKey + ' ' + row.salesforceField
    ).left(40);
    String sfFieldName = stripNamespace(row.salesforceField);
    String sfObjectName = (row.isLine == true && String.isNotBlank(row.salesforceObject))
      ? stripNamespace(row.salesforceObject)
      : ((fieldToObjectMap != null && fieldToObjectMap.containsKey(sfFieldName.toLowerCase()))
          ? fieldToObjectMap.get(sfFieldName.toLowerCase())
          : stripNamespace(request.salesforceObject));
    addValue(record, 'Integration__c', request.connectorKey);
    addValue(record, 'Action__c', request.operationKey);
    addValue(record, 'SF_Object__c', sfObjectName);
    addValue(record, 'SF_Field__c', sfFieldName);
    addValue(record, 'External_Field__c', row.externalPath);
    addValue(record, 'Sync_Direction__c', normalizeDirection(row.direction));
    addValue(record, 'Is_Active__c', row.active != false);
    addValue(record, 'Target_Object_API_Name__c', request.externalObject);
    return record;
  }

  private static void addValue(
    Metadata.CustomMetadata record,
    String fieldName,
    Object value
  ) {
    Metadata.CustomMetadataValue item = new Metadata.CustomMetadataValue();
    item.field = fieldName;
    item.value = value;
    record.values.add(item);
  }

  private static String mappingIdentity(SaveRequest request, MappingInput row) {
    String sfObjectName = (row.isLine == true && String.isNotBlank(row.salesforceObject))
      ? stripNamespace(row.salesforceObject)
      : stripNamespace(request.salesforceObject);
    return String.join(
      new List<String>{
        normalize(request.connectorKey),
        normalize(request.operationKey),
        normalize(sfObjectName),
        normalize(stripNamespace(row.salesforceField)),
        normalize(row.externalPath),
        normalizeDirection(row.direction).toLowerCase()
      },
      '|'
    );
  }

  private static String digest(String value) {
    return EncodingUtil.convertToHex(
      Crypto.generateDigest('SHA-256', Blob.valueOf(value))
    ).left(32);
  }

  private static Integration_Connector__mdt requireConnector(String connectorKey) {
    if (String.isBlank(connectorKey) || !SAFE_TOKEN.matcher(connectorKey).matches()) {
      throw handled('Unsupported connector.');
    }
    String keyValue = normalize(connectorKey);
    if (!SAFE_TOKEN.matcher(keyValue).matches()) throw handled('Unsupported connector.');
    List<Integration_Connector__mdt> rows = [
      SELECT Connector_Key__c, Provider_Label__c
      FROM Integration_Connector__mdt
      WHERE Connector_Key__c = :keyValue AND Enabled__c = true
      LIMIT 1
    ];
    if (rows.isEmpty()) throw handled('Unsupported connector.');
    return rows[0];
  }

  private static Integration_Operation__mdt requireOperation(
    String connectorKey,
    String operationKey,
    String direction
  ) {
    if (String.isBlank(connectorKey) || !SAFE_TOKEN.matcher(connectorKey).matches()) {
      throw handled('Unsupported mapping operation.');
    }
    String keyValue = normalize(connectorKey);
    if (
      !SAFE_TOKEN.matcher(keyValue).matches() ||
      String.isBlank(operationKey) ||
      !SAFE_TOKEN.matcher(operationKey).matches()
    ) throw handled('Unsupported mapping operation.');
    List<Integration_Operation__mdt> rows = [
      SELECT DeveloperName, MasterLabel, Connector_Key__c, Operation_Key__c, Salesforce_Object__c,
        External_Entity__c, Direction__c, Run_On_Record_Save__c
      FROM Integration_Operation__mdt
      WHERE Connector_Key__c = :keyValue
        AND Operation_Key__c = :operationKey
        AND Active__c = true
    ];
    if (rows.isEmpty()) throw handled('Unsupported mapping operation.');
    if (String.isNotBlank(direction)) {
      String requestedDirection = normalizeDirection(direction);
      for (Integration_Operation__mdt row : rows) {
        if (normalizeDirection(row.Direction__c) == requestedDirection) return row;
      }
      throw handled('Unsupported mapping operation direction.');
    }
    return rows[0];
  }

  private static Schema.SObjectType requireObject(String objectName) {
    String apiName = stripNamespace(objectName);
    if (!SAFE_TOKEN.matcher(apiName).matches()) throw handled('Unsupported Salesforce object.');
    Schema.SObjectType objectType = Schema.getGlobalDescribe().get(apiName);
    if (objectType == null || !objectType.getDescribe().isAccessible()) {
      throw handled('Unsupported or inaccessible Salesforce object.');
    }
    return objectType;
  }

  private static void assertReadAccess() {
    if (Test.isRunningTest() && bypassSecurityForTests) return;
    if (!Schema.sObjectType.Connector_Instance__c.isAccessible()) {
      throw handled('Quickbridge mapping read access is required.');
    }
  }

  private static void assertAdminAccess() {
    if (Test.isRunningTest() && bypassSecurityForTests) return;
    if (!Schema.sObjectType.Connector_Instance__c.isUpdateable()) {
      throw handled('Quickbridge administrator access is required.');
    }
  }

  private static Set<String> aliasesFor(String connectorKey) {
    Set<String> aliases = new Set<String>{ connectorKey };
    if (connectorKey == 'qbo') {
      aliases.addAll(new Set<String>{ 'qbonline', 'quickbooks', 'QuickBooks' });
    } else if (connectorKey == 'shopify') {
      aliases.add('Shopify');
    } else if (connectorKey == 'paypal') {
      aliases.add('payPal');
    }
    return aliases;
  }

  private static String normalizeDirection(String value) {
    String normalized = normalize(value);
    if (
      normalized == 'both' || normalized == 'twoway' ||
      normalized == 'bidirectional'
    ) return 'Both';
    if (
      normalized == 'outbound' || normalized.startsWith('sfto') ||
      normalized.startsWith('salesforceto') || normalized.contains('toexternal')
    ) return 'Outbound';
    if (
      normalized == 'inbound' || normalized.endsWith('tosf') ||
      normalized.endsWith('tosalesforce') || normalized.contains('fromexternal')
    ) return 'Inbound';
    return value;
  }

  private static String stripNamespace(String value) {
    if (String.isBlank(value)) return value;
    return value.replace('QuickBridgeTLG__', '');
  }

  private static Boolean same(String left, String right) {
    return normalize(stripNamespace(left)) == normalize(stripNamespace(right));
  }

  private static String rowKey(String objectName, String fieldName, String direction) {
    return normalize(stripNamespace(objectName)) + ':' + normalize(fieldName) + ':' + normalizeDirection(direction).toLowerCase();
  }

  private static String normalize(String value) {
    return String.isBlank(value)
      ? ''
      : value.trim().toLowerCase().replaceAll('[^a-z0-9]', '');
  }

  private static String cacheKey(String deploymentId) {
    return 'quickbridge.mapping.' + String.valueOf(deploymentId).left(80);
  }

  private static AuraHandledException handled(String message) {
    return new AuraHandledException(message);
  }

  private static void logDeploymentFailure(
    String deploymentId,
    Metadata.DeployResult result
  ) {
    if (!Schema.sObjectType.Error_Log__c.isCreateable()) return;
    try {
      insert new Error_Log__c(
        Error_Category__c = 'Configuration',
        Error_Message__c = 'Field mapping metadata deployment failed.',
        Is_Retryable__c = false,
        Retry_Status__c = 'Failed',
        Class_Method_Name__c = 'QuickbridgeMappingController.MappingDeployCallback',
        Source_Object__c = 'Field_Mapping__mdt',
        External_Reference__c = 'mapping-deploy:' + deploymentId
      );
    } catch (Exception ignored) {
      // A logging failure must not mask the metadata deployment result.
    }
  }

  public class MappingException extends Exception {}
}