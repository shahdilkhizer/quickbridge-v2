// Analysis only. Sharing and field access are retained; no DML, transport, or metadata writes.
public with sharing class QuickbridgeAssistantService {
  public class Request {
    public String connectorKey; public String operationKey; public String operationDirection;
    public List<QuickbridgeMappingController.MappingInput> rows;
  }
  public class Analysis {
    @AuraEnabled public String workspaceKey;
    @AuraEnabled public String connectorKey;
    @AuraEnabled public String status;
    @AuraEnabled public Integer healthScore;
    @AuraEnabled public Integer requiredFieldsTotal = 0;
    @AuraEnabled public Integer requiredFieldsMapped = 0;
    @AuraEnabled public Boolean limitedSchema = false;
    @AuraEnabled public List<Insight> missingRequiredFields = new List<Insight>();
    @AuraEnabled public List<Insight> risks = new List<Insight>();
    @AuraEnabled public List<Suggestion> suggestions = new List<Suggestion>();
    @AuraEnabled public String fixPrompt;
  }
  public class Insight {
    @AuraEnabled public String key;
    @AuraEnabled public String severity;
    @AuraEnabled public String message;
    @AuraEnabled public String salesforceObject;
    @AuraEnabled public String externalField;
  }
  public class Suggestion implements Comparable {
    @AuraEnabled public String key;
    @AuraEnabled public String workspaceKey;
    @AuraEnabled public String salesforceObject;
    @AuraEnabled public Boolean isLine;
    @AuraEnabled public String collectionPath;
    @AuraEnabled public String direction;
    @AuraEnabled public String salesforceField;
    @AuraEnabled public String salesforceFieldLabel;
    @AuraEnabled public String externalPath;
    @AuraEnabled public String externalFieldLabel;
    @AuraEnabled public Decimal confidence;
    @AuraEnabled public String confidenceLabel;
    @AuraEnabled public String reason;
    @AuraEnabled public Boolean canApply;
    public Integer compareTo(Object other) {
      Suggestion right = (Suggestion) other;
      return confidence == right.confidence ? key.compareTo(right.key) : confidence > right.confidence ? -1 : 1;
    }
  }
  private class GroupContext {
    String objectName; String collectionPath; Boolean child;
    Map<String, QuickbridgeAssistantSchema.Field> fields;
    List<QuickbridgeMappingController.MappingInput> rows = new List<QuickbridgeMappingController.MappingInput>();
  }
  private static Map<String,String> identityFields;
  private static Boolean hasTypeRisk;
  private static Boolean hasDuplicateExternal;
  private static Boolean hasDuplicateSalesforce;
  private static Boolean missingOptional;

  public static Analysis review(String requestJson) {
    QuickbridgeAdminSecurity.requireView();
    if (String.isBlank(requestJson) || requestJson.length() > 150000) fail('Mapping analysis request is invalid.');
    Request request;
    try { request = (Request) JSON.deserializeStrict(requestJson, Request.class); }
    catch (Exception error) { fail('Mapping analysis request is invalid.'); }
    if (request == null || String.isBlank(request.connectorKey) || String.isBlank(request.operationKey) ||
        String.isBlank(request.operationDirection)) fail('Select a connector, operation, and direction.');
    request.connectorKey = request.connectorKey.trim().toLowerCase();
    List<Integration_Operation__mdt> definitions = [
      SELECT Connector_Key__c, Operation_Key__c, Direction__c, Salesforce_Object__c,
        External_Entity__c, Salesforce_External_Id_Field__c
      FROM Integration_Operation__mdt WHERE Connector_Key__c = :request.connectorKey
        AND Operation_Key__c = :request.operationKey AND Direction__c = :request.operationDirection
        AND Active__c = true LIMIT 2
    ];
    if (definitions.size() != 1) fail('The selected mapping operation is unavailable or ambiguous.');
    Integration_Operation__mdt operation = definitions[0];
    Analysis result = new Analysis();
    result.connectorKey = request.connectorKey;
    result.workspaceKey = operation.Operation_Key__c + '|' + operation.Direction__c;
    identityFields = new Map<String,String>();
    identityFields.put(operation.Salesforce_Object__c.toLowerCase(), operation.Salesforce_External_Id_Field__c);
    hasTypeRisk = false; hasDuplicateExternal = false; hasDuplicateSalesforce = false; missingOptional = false;
    Map<String, GroupContext> groups = new Map<String, GroupContext>();
    GroupContext parent = groupFor(groups, operation.Salesforce_Object__c, null, false, operation);
    List<GenericIntegrationRuntime.MappingRule> effective = GenericIntegrationRuntime.recordSaveMappings(operation, true);
    for (GenericIntegrationRuntime.MappingRule rule : effective) {
      if (!applies(rule.direction, operation.Direction__c)) continue;
      Boolean child = String.isNotBlank(rule.collectionPath) && !same(rule.salesforceObject, operation.Salesforce_Object__c);
      GroupContext contextGroup = child ? groupFor(groups, rule.salesforceObject, rule.collectionPath, true, operation) : parent;
      if (rule.isExternalId == true) identityFields.put(contextGroup.objectName.toLowerCase(), rule.salesforceField);
      ensureKnownField(contextGroup, rule.externalPath, rule.required);
      if (request.rows == null) {
        QuickbridgeMappingController.MappingInput row = new QuickbridgeMappingController.MappingInput();
        row.salesforceField = rule.salesforceField; row.externalPath = rule.externalPath;
        row.salesforceObject = contextGroup.objectName; row.isLine = child;
        row.direction = rule.direction; row.active = true; contextGroup.rows.add(row);
      }
    }
    // Required metadata rules must survive an override replacing the default mapping row.
    for (Integration_Operation_Mapping__mdt rule : [
      SELECT Salesforce_Object__c, External_Path__c, Collection_Path__c, Direction__c
      FROM Integration_Operation_Mapping__mdt WHERE Connector_Key__c = :request.connectorKey
        AND Operation_Key__c = :request.operationKey AND Active__c = true AND Required__c = true
    ]) {
      if (!applies(rule.Direction__c, operation.Direction__c)) continue;
      String key = groupKey(rule.Salesforce_Object__c, rule.Collection_Path__c);
      if (groups.containsKey(key)) ensureKnownField(groups.get(key), rule.External_Path__c, true);
    }
    if (request.rows != null) {
      if (request.rows.size() > 200) fail('Analyze no more than 200 mapping rows.');
      for (QuickbridgeMappingController.MappingInput row : request.rows) {
        if (row == null) fail('Mapping rows must not be null.');
        if (!applies(row.direction, operation.Direction__c)) continue;
        String objectName = row.isLine == true ? row.salesforceObject : parent.objectName;
        GroupContext selected;
        for (GroupContext candidate : groups.values()) {
          if (same(candidate.objectName, objectName) && candidate.child == (row.isLine == true)) {
            if (selected != null) fail('The child relationship is ambiguous.');
            selected = candidate;
          }
        }
        if (selected == null) fail('The mapping row is outside the selected operation.');
        selected.rows.add(row);
      }
    }
    List<String> groupKeys = new List<String>(groups.keySet()); groupKeys.sort();
    for (String key : groupKeys) analyzeGroup(groups.get(key), operation, result);
    result.suggestions.sort();
    while (result.suggestions.size() > 12) result.suggestions.remove(result.suggestions.size() - 1);
    Integer scoreValue = 100 - (result.missingRequiredFields.isEmpty() ? 0 : 25)
      - (hasTypeRisk ? 15 : 0) - (hasDuplicateExternal ? 10 : 0)
      - (hasDuplicateSalesforce ? 10 : 0) - (missingOptional ? 5 : 0);
    result.healthScore = result.limitedSchema ? null : Math.max(0, scoreValue);
    result.status = result.limitedSchema ? 'Limited schema' : statusFor(result.healthScore);
    List<String> prompt = new List<String>{'Review Quickbridge mapping fixes.',
      'Connector: ' + result.connectorKey, 'Operation: ' + result.workspaceKey,
      'Salesforce object: ' + operation.Salesforce_Object__c, 'Provider object: ' + operation.External_Entity__c,
      'Analysis: ' + result.status, 'Do not change record-save synchronization, credentials, or unrelated operations.'};
    for (Insight item : result.missingRequiredFields) prompt.add('Missing: ' + item.message);
    for (Insight item : result.risks) prompt.add(item.severity + ': ' + item.message);
    for (Suggestion item : result.suggestions) if (item.canApply) prompt.add('Review: ' + item.salesforceObject + '.' + item.salesforceField + ' -> ' + item.externalPath + ' (' + item.confidenceLabel + ')');
    result.fixPrompt = String.join(prompt, '\n');
    return result;
  }

  private static GroupContext groupFor(Map<String,GroupContext> groups, String objectName,
      String collection, Boolean child, Integration_Operation__mdt operation) {
    String key = groupKey(objectName, collection);
    if (!groups.containsKey(key)) {
      GroupContext value = new GroupContext();
      value.objectName = objectName; value.collectionPath = collection; value.child = child;
      value.fields = new Map<String,QuickbridgeAssistantSchema.Field>();
      for (QuickbridgeAssistantSchema.Field field : QuickbridgeAssistantSchema.fields(
          operation.Connector_Key__c, operation.External_Entity__c, child).values()) {
        if (child && String.isNotBlank(collection) && field.value.startsWith(collection + '.')) {
          field.value = field.value.substring(collection.length() + 1);
        }
        value.fields.put(field.value.toLowerCase(), field);
      }
      groups.put(key, value);
    }
    return groups.get(key);
  }
  private static void ensureKnownField(GroupContext contextGroup, String path, Boolean required) {
    if (String.isBlank(path)) return;
    String key = path.toLowerCase();
    if (!contextGroup.fields.containsKey(key)) {
      QuickbridgeAssistantSchema.Field field = new QuickbridgeAssistantSchema.Field();
      field.label = path; field.value = path; field.type = null; field.required = required == true;
      field.inboundAllowed = true; field.outboundAllowed = true; contextGroup.fields.put(key, field);
    } else if (required == true) contextGroup.fields.get(key).required = true;
  }
  private static void analyzeGroup(GroupContext contextGroup, Integration_Operation__mdt operation, Analysis result) {
    Schema.SObjectType objectType = ConnectorExecutionRequest.resolveSObjectType(contextGroup.objectName);
    if (objectType == null || !objectType.getDescribe().isAccessible()) fail('A mapping object is inaccessible.');
    Map<String,Schema.SObjectField> described = objectType.getDescribe().fields.getMap();
    Map<String,FieldInfo> sfFields = new Map<String,FieldInfo>();
    for (Schema.SObjectField token : described.values()) {
      Schema.DescribeFieldResult field = token.getDescribe();
      if (field.isAccessible() && field.getType() != Schema.DisplayType.Address && field.getType() != Schema.DisplayType.Location) {
        sfFields.put(field.getName().toLowerCase(), new FieldInfo(field.getLabel(), field.getName(), String.valueOf(field.getType()), false));
      }
    }
    Set<String> mapped = new Set<String>(); Set<String> seenSf = new Set<String>();
    Set<String> occupiedSf = new Set<String>(); Set<String> occupiedExternal = new Set<String>();
    for (QuickbridgeMappingController.MappingInput row : contextGroup.rows) {
      if (String.isNotBlank(row.salesforceField)) occupiedSf.add(row.salesforceField.toLowerCase());
      if (String.isNotBlank(row.externalPath)) occupiedExternal.add(row.externalPath.toLowerCase());
      if (row.active == false) continue;
      if (String.isBlank(row.salesforceField) || String.isBlank(row.externalPath)) continue;
      String sfKey = row.salesforceField.toLowerCase(), extKey = row.externalPath.toLowerCase();
      if (!sfFields.containsKey(sfKey)) {
        addRisk(result, contextGroup, 'Warning', 'A mapped Salesforce field is unavailable for analysis.', null); result.limitedSchema = true; continue;
      }
      if (mapped.contains(extKey)) {
        hasDuplicateExternal = true; addRisk(result, contextGroup, 'High', 'Duplicate provider field: ' + row.externalPath, row.externalPath);
      }
      if (!seenSf.add(sfKey)) {
        hasDuplicateSalesforce = true; addRisk(result, contextGroup, 'Warning', 'Repeated Salesforce field: ' + row.salesforceField, row.externalPath);
      }
      mapped.add(extKey);
      QuickbridgeAssistantSchema.Field external = contextGroup.fields.get(extKey);
      if (external == null || String.isBlank(external.type)) {
        result.limitedSchema = true;
        addRisk(result, contextGroup, 'Warning', 'Provider type is unverified: ' + row.externalPath, row.externalPath); continue;
      }
      if (!isTypeCompatible(sfFields.get(sfKey).type, external.type)) {
        hasTypeRisk = true; addRisk(result, contextGroup, 'High', 'Incompatible field types: ' + row.salesforceField + ' -> ' + row.externalPath, row.externalPath);
      }
      if (!writable(described.get(sfKey).getDescribe(), external, operation.Direction__c)) {
        addRisk(result, contextGroup, 'Warning', 'Review write restrictions: ' + row.salesforceField + ' -> ' + row.externalPath, row.externalPath);
      }
    }
    if (contextGroup.fields.isEmpty()) result.limitedSchema = true;
    List<String> externalKeys = new List<String>(contextGroup.fields.keySet()); externalKeys.sort();
    List<String> sfKeys = new List<String>(sfFields.keySet()); sfKeys.sort();
    for (String key : externalKeys) {
      QuickbridgeAssistantSchema.Field external = contextGroup.fields.get(key);
      Boolean knownType = String.isNotBlank(external.type);
      if (!knownType) result.limitedSchema = true;
      if (external.required == true) {
        result.requiredFieldsTotal++;
        if (mapped.contains(key)) result.requiredFieldsMapped++;
        else {
          Insight missing = insight(contextGroup, 'Required', contextGroup.objectName + ': ' + external.value + ' is not mapped.', external.value);
          result.missingRequiredFields.add(missing);
        }
      } else if (!mapped.contains(key)) {
        Set<String> optionalTokens = tokens(external.value + ' ' + external.label);
        if (optionalTokens.contains('email') || optionalTokens.contains('phone') || optionalTokens.contains('amount') || optionalTokens.contains('status')) missingOptional = true;
      }
      if (mapped.contains(key)) continue;
      Suggestion best;
      FieldInfo extField = new FieldInfo(external.label, external.value, external.type, external.required);
      for (String sfKey : sfKeys) {
        FieldInfo sfField = sfFields.get(sfKey);
        if (sfKey == 'id' || IntegrationOutcomeService.SYSTEM_FIELDS.contains(sfKey)) continue;
        if (knownType && !isTypeCompatible(sfField.type, external.type)) continue;
        if (!knownType) extField.type = sfField.type;
        Decimal confidence = score(operation.Connector_Key__c, contextGroup.objectName, operation.External_Entity__c, sfField, extField);
        confidence = Math.min(99, confidence + (external.required == true ? 5 : 0));
        if (!knownType) confidence = Math.min(79, confidence);
        if (confidence < 55) continue;
        Suggestion candidate = new Suggestion();
        candidate.workspaceKey = result.workspaceKey; candidate.salesforceObject = contextGroup.objectName;
        candidate.isLine = contextGroup.child; candidate.collectionPath = contextGroup.collectionPath; candidate.direction = operation.Direction__c;
        candidate.salesforceField = sfField.value; candidate.salesforceFieldLabel = sfField.label;
        candidate.externalPath = external.value; candidate.externalFieldLabel = cleanExternalLabel(external.label);
        candidate.key = groupKey(contextGroup.objectName, contextGroup.collectionPath) + ':' + sfField.value + ':' + external.value;
        candidate.confidence = confidence.setScale(0); candidate.confidenceLabel = confidence >= 80 ? 'High' : 'Medium';
        candidate.canApply = writable(described.get(sfKey).getDescribe(), external, operation.Direction__c) &&
          !occupiedSf.contains(sfKey) && !occupiedExternal.contains(key);
        candidate.reason = knownType ? reasonFor(sfField, extField, confidence) : 'Name-based match; provider type is unverified. Review before applying.';
        if (!candidate.canApply) candidate.reason += ' Not applicable: the field is already present in the draft or has write restrictions.';
        if (best == null || (candidate.canApply && !best.canApply) || (candidate.canApply == best.canApply && candidate.confidence > best.confidence)) best = candidate;
      }
      if (best != null) result.suggestions.add(best);
    }
  }
  private static Boolean writable(Schema.DescribeFieldResult sf, QuickbridgeAssistantSchema.Field external, String direction) {
    if (sf.isCalculated() && direction != 'Outbound') return false;
    if ((direction == 'Inbound' || direction == 'Both' || direction == 'Bidirectional') &&
        (!sf.isCreateable() || !sf.isUpdateable() || sf.isCalculated() || external.inboundAllowed == false)) return false;
    return !((direction == 'Outbound' || direction == 'Both' || direction == 'Bidirectional') && external.outboundAllowed == false);
  }
  private static Insight insight(GroupContext contextGroup, String severity, String message, String path) {
    Insight value = new Insight(); value.key = groupKey(contextGroup.objectName, contextGroup.collectionPath) + ':' + severity + ':' + message;
    value.severity = severity; value.message = message; value.externalField = path; value.salesforceObject = contextGroup.objectName; return value;
  }
  private static void addRisk(Analysis result, GroupContext contextGroup, String severity, String message, String path) {
    Insight item = insight(contextGroup, severity, message, path);
    for (Insight existing : result.risks) if (existing.key == item.key) return;
    result.risks.add(item);
  }
  private static String groupKey(String objectName, String collection) { return safe(objectName).toLowerCase() + '|' + safe(collection).toLowerCase(); }
  private static Boolean same(String left, String right) { return safe(left).equalsIgnoreCase(safe(right)); }
  private static Boolean applies(String direction, String operationDirection) {
    return direction == 'Both' || direction == 'Bidirectional' || direction == operationDirection ||
      operationDirection == 'Both' || operationDirection == 'Bidirectional';
  }
  private static Boolean isConnectorExternalIdField(String connectorKey, String objectName, String externalObject, String sfField, String externalField) {
    return compact(externalField) == 'id' && same(identityFields.get(objectName.toLowerCase()), sfField);
  }
  private static void fail(String message) {
    AuraHandledException error = new AuraHandledException(message); error.setMessage(message); throw error;
  }

  private class FieldInfo {
    String label;
    String value;
    String type;
    Boolean required;
    // Cached, computed once per field to avoid recomputing tokens/normalized form
    // for every (external x salesforce) field pair during suggestion scoring.
    Set<String> tokenSet;
    String normalized;
    String valueNormalized;

    FieldInfo(String label, String value, String type, Boolean required) {
      this.label = label;
      this.value = value;
      this.type = normalizeType(type);
      this.required = required == true;
    }

    Set<String> getTokens() {
      if (tokenSet == null) {
        tokenSet = tokens(value + ' ' + label);
      }
      return tokenSet;
    }

    // Normalized form derived from the same tokens (joined, no separators) so it
    // reuses the cached token computation instead of running the regex again.
    String getNormalized() {
      if (normalized == null) {
        normalized = String.join(new List<String>(getTokens()), '');
      }
      return normalized;
    }

    // Normalized form of the field value only (no label), matching the original
    // normalizeForCompare(value) comparison. Cached per field.
    String getValueNormalized() {
      if (valueNormalized == null) {
        valueNormalized = normalizeForCompare(value);
      }
      return valueNormalized;
    }
  }

  private static Decimal score(
    String connectorKey,
    String salesforceObject,
    String externalObject,
    FieldInfo sfField,
    FieldInfo externalField
  ) {
    String sfNorm = sfField.getNormalized();
    String extNorm = externalField.getNormalized();
    Set<String> sfTokens = sfField.getTokens();
    Set<String> extTokens = externalField.getTokens();
    Decimal scoreValue = 0;
    if (
      sfNorm == extNorm ||
      sfField.getValueNormalized() == externalField.getValueNormalized()
    ) {
      scoreValue = 92;
    } else if (!sfTokens.isEmpty() && sfTokens.equals(extTokens)) {
      scoreValue = 84;
    } else {
      Integer overlap = 0;
      for (String token : sfTokens) {
        if (extTokens.contains(token)) {
          overlap++;
        }
      }
      if (overlap > 0) {
        scoreValue = 58 + (overlap * 8);
      }
      if (hasSynonymOverlap(sfTokens, extTokens)) {
        scoreValue = Math.max(scoreValue, 72);
      }
    }
    if (isTypeCompatible(sfField.type, externalField.type)) {
      scoreValue += 8;
    }
    if (
      isConnectorExternalIdField(
        connectorKey,
        salesforceObject,
        externalObject,
        sfField.value,
        externalField.value
      )
    ) {
      scoreValue += 30;
    }
    if (sfField.value == 'Id' && normalizeForCompare(externalField.value) == 'id') {
      scoreValue -= 35;
    }
    return Math.min(99, scoreValue);
  }

  private static String reasonFor(
    FieldInfo sfField,
    FieldInfo externalField,
    Decimal confidence
  ) {
    if (confidence >= HIGH_CONFIDENCE) {
      return 'High-confidence match from field name, label, and compatible types.';
    }
    return 'Suggested from normalized tokens, synonyms, and compatible types.';
  }

  private static String statusFor(Integer score) {
    if (score >= 90) {
      return 'Healthy';
    }
    if (score >= 70) {
      return 'Good';
    }
    if (score >= 50) {
      return 'Needs Attention';
    }
    return 'High Risk';
  }

  private static String cleanExternalLabel(String labelValue) {
    String value = safe(labelValue);
    Integer indexValue = value.indexOf(' - ');
    return indexValue >= 0 ? value.substring(indexValue + 3) : value;
  }

  private static String normalizeForCompare(String value) {
    return String.join(new List<String>(tokens(value)), '');
  }

  private static Set<String> tokens(String value) {
    Set<String> result = new Set<String>();
    if (String.isBlank(value)) {
      return result;
    }
    String expanded = value.replaceAll('([a-z])([A-Z])', '$1 $2')
      .replaceAll('[^A-Za-z0-9]+', ' ')
      .toLowerCase();
    for (String part : expanded.split('\\s+')) {
      if (
        String.isNotBlank(part) &&
        part != 'qb' &&
        part != 'sf' &&
        part != 'fedex' &&
        part != 'ups' &&
        part != 'dhl' &&
        part != 'shopify' &&
        part != 'netsuite' &&
        part != 'meta'
      ) {
        result.add(part);
      }
    }
    return expandSynonyms(result);
  }

  private static Set<String> expandSynonyms(Set<String> source) {
    Set<String> result = new Set<String>();
    result.addAll(source);
    Map<String, Set<String>> index = synonymIndex();
    for (String token : source) {
      Set<String> groupValues = index.get(token);
      if (groupValues != null) {
        result.addAll(groupValues);
      }
    }
    return result;
  }

  private static Map<String, Set<String>> synonymIndex() {
    if (synonymIndexCache == null) {
      synonymIndexCache = new Map<String, Set<String>>();
      for (Set<String> groupValues : synonymGroups()) {
        for (String token : groupValues) {
          synonymIndexCache.put(token, groupValues);
        }
      }
    }
    return synonymIndexCache;
  }

  private static Boolean hasSynonymOverlap(
    Set<String> leftValues,
    Set<String> rightValues
  ) {
    for (String token : leftValues) {
      if (rightValues.contains(token)) {
        return true;
      }
    }
    return false;
  }

  private static List<Set<String>> synonymGroups() {
    if (synonymGroupsCache != null) {
      return synonymGroupsCache;
    }
    synonymGroupsCache = new List<Set<String>>{
      new Set<String>{
        'postal',
        'zipcode',
        'zip',
        'code',
        'shippingpostalcode'
      },
      new Set<String>{ 'country', 'countrycode', 'shippingcountry' },
      new Set<String>{ 'state', 'province', 'region', 'shippingstate' },
      new Set<String>{
        'sku',
        'stockkeepingunit',
        'productcode',
        'product',
        'id'
      },
      new Set<String>{ 'email', 'customeremail', 'billtoemail', 'personemail' },
      new Set<String>{ 'phone', 'mobile', 'customerphone' },
      new Set<String>{ 'amount', 'total', 'grandtotal', 'balance', 'totalamt' },
      new Set<String>{ 'name', 'displayname', 'fullname', 'title' },
      new Set<String>{ 'city', 'town', 'shippingcity' },
      new Set<String>{ 'street', 'address', 'addressline1', 'shippingstreet' },
      new Set<String>{ 'weight', 'packageweight' },
      new Set<String>{ 'currency', 'currencycode' },
      new Set<String>{ 'quantity', 'qty' },
      new Set<String>{ 'tax', 'taxamount' },
      new Set<String>{ 'discount', 'discountamount' },
      new Set<String>{ 'status', 'state' },
      new Set<String>{ 'date', 'time', 'txn' }
    };
    return synonymGroupsCache;
  }

  private static String normalizeType(String typeValue) {
    String value = String.isBlank(typeValue)
      ? 'STRING'
      : typeValue.trim().toUpperCase();
    if (
      value == 'TEXT' ||
      value == 'PICKLIST' ||
      value == 'EMAIL' ||
      value == 'PHONE' ||
      value == 'URL' ||
      value == 'REFERENCE' ||
      value == 'ID'
    ) {
      return 'STRING';
    }
    if (
      value == 'CURRENCY' ||
      value == 'DOUBLE' ||
      value == 'DECIMAL' ||
      value == 'PERCENT' ||
      value == 'INTEGER' ||
      value == 'LONG' ||
      value == 'NUMBER'
    ) {
      return 'NUMBER';
    }
    if (value == 'DATETIME') {
      return 'DATETIME';
    }
    if (value == 'DATE') {
      return 'DATE';
    }
    if (value == 'BOOLEAN') {
      return 'BOOLEAN';
    }
    return 'STRING';
  }

  private static Boolean isTypeCompatible(String sfType, String externalType) {
    String sfValue = normalizeType(sfType);
    String externalValue = normalizeType(externalType);
    if (sfValue == externalValue) {
      return true;
    }
    if (sfValue == 'DATETIME' && externalValue == 'STRING') {
      return true;
    }
    if (sfValue == 'DATE' && externalValue == 'DATETIME') {
      return true;
    }
    return false;
  }

  private static String compact(String value) {
    return String.isBlank(value) ? '' : value.toLowerCase().replaceAll('[^a-z0-9]', '');
  }

  private static String safe(String value) {
    return value == null ? '' : value;
  }

  private static Map<String,Set<String>> synonymIndexCache;
  private static List<Set<String>> synonymGroupsCache;
  private static final Decimal HIGH_CONFIDENCE = 80;
}