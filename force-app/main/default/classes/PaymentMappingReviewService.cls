// Read-only review of hosted-payment mapping drafts. No metadata or record DML.
public with sharing class PaymentMappingReviewService {
  private static final Integer MAX_REQUEST_LENGTH = 150000;

  public static QuickbridgeAssistantService.Analysis review(String requestJson) {
    if (String.isBlank(requestJson) || requestJson.length() > MAX_REQUEST_LENGTH) {
      fail('Payment mapping analysis request is invalid.');
    }
    PaymentInvoiceMappingController.GatewayMappingConfig config;
    try {
      config = (PaymentInvoiceMappingController.GatewayMappingConfig)
        JSON.deserializeStrict(
          requestJson,
          PaymentInvoiceMappingController.GatewayMappingConfig.class
        );
    } catch (Exception error) {
      fail('Payment mapping analysis request is invalid.');
    }
    if (config == null || String.isBlank(config.gateway)) {
      fail('Select a payment gateway to review its mappings.');
    }

    PaymentGatewaySchema.Contract contract = PaymentGatewaySchema.forGateway(
      config.gateway
    );
    QuickbridgeAssistantService.Analysis result =
      new QuickbridgeAssistantService.Analysis();
    result.connectorKey = contract.gateway;
    result.workspaceKey = 'PaymentInvoice';

    reviewSetup(
      result,
      'Source',
      config.sourceObject,
      config.sourceCustomerLookupField,
      'Account or Contact Lookup'
    );
    reviewSetup(
      result,
      'Source',
      config.sourceObject,
      config.sourceEmailField,
      'Customer Email'
    );
    reviewSection(
      result,
      'Source',
      config.sourceObject,
      contract.requestFields,
      config.sourceMappings,
      true
    );
    reviewSetup(
      result,
      'Invoice',
      config.invoiceObject,
      config.invoiceSourceLookupField,
      'Lookup to Source Object'
    );
    reviewSection(
      result,
      'Invoice',
      config.invoiceObject,
      contract.invoiceResultFields,
      config.invoiceMappings,
      false
    );
    reviewSetup(
      result,
      'Transaction',
      config.transactionObject,
      config.transactionSourceLookupField,
      'Lookup to Source Object'
    );
    reviewSection(
      result,
      'Transaction',
      config.transactionObject,
      contract.transactionFields,
      config.transactionMappings,
      false
    );

    Integer baseScore = result.requiredFieldsTotal == 0
      ? 0
      : Math.round(
          ((Decimal) result.requiredFieldsMapped * 100) /
          result.requiredFieldsTotal
        );
    result.healthScore = Math.max(
      0,
      baseScore - Math.min(20, result.risks.size() * 5)
    );
    result.status = result.healthScore >= 90
      ? 'Good'
      : (result.healthScore >= 70 ? 'Needs Review' : 'Action Required');
    result.suggestions.sort();
    while (result.suggestions.size() > 12) {
      result.suggestions.remove(result.suggestions.size() - 1);
    }
    result.fixPrompt = buildFixPrompt(result);
    return result;
  }

  private static void reviewSetup(
    QuickbridgeAssistantService.Analysis result,
    String section,
    String objectName,
    String selectedValue,
    String label
  ) {
    result.requiredFieldsTotal++;
    if (String.isNotBlank(selectedValue)) {
      result.requiredFieldsMapped++;
      return;
    }
    result.missingRequiredFields.add(
      insight(section, objectName, label, label + ' is not configured.')
    );
  }

  private static void reviewSection(
    QuickbridgeAssistantService.Analysis result,
    String section,
    String objectName,
    List<PaymentGatewaySchema.FieldDefinition> definitions,
    List<PaymentInvoiceMappingController.MappingRow> rows,
    Boolean sourceSection
  ) {
    List<PaymentInvoiceMappingController.MappingRow> safeRows = rows == null
      ? new List<PaymentInvoiceMappingController.MappingRow>()
      : rows;
    Map<String, Schema.SObjectField> fields = fieldsFor(objectName);
    Set<String> seenSalesforce = new Set<String>();
    Set<String> seenSemantic = new Set<String>();

    for (PaymentInvoiceMappingController.MappingRow row : safeRows) {
      if (row == null) continue;
      String salesforceField = sourceSection ? row.sourceField : row.targetField;
      String semanticField = sourceSection ? row.targetField : row.sourceField;
      if (String.isNotBlank(salesforceField)) {
        String key = salesforceField.toLowerCase();
        if (!seenSalesforce.add(key)) {
          addRisk(
            result,
            section,
            objectName,
            'Repeated Salesforce field: ' + salesforceField,
            semanticField
          );
        }
        if (!fields.containsKey(key)) {
          addRisk(
            result,
            section,
            objectName,
            'Mapped Salesforce field is unavailable: ' + salesforceField,
            semanticField
          );
        }
      }
      if (String.isNotBlank(semanticField) &&
          !seenSemantic.add(semanticField.toLowerCase())) {
        addRisk(
          result,
          section,
          objectName,
          'Duplicate payment field: ' + semanticField,
          semanticField
        );
      }
    }

    for (PaymentGatewaySchema.FieldDefinition definition : definitions) {
      if (definition.required != true) continue;
      result.requiredFieldsTotal++;
      PaymentInvoiceMappingController.MappingRow mapped = findRow(
        safeRows,
        definition.value,
        sourceSection
      );
      String salesforceField = mapped == null
        ? null
        : (sourceSection ? mapped.sourceField : mapped.targetField);
      if (String.isNotBlank(salesforceField) &&
          fields.containsKey(salesforceField.toLowerCase())) {
        result.requiredFieldsMapped++;
        if (!compatible(
          fields.get(salesforceField.toLowerCase()).getDescribe().getType(),
          definition.type
        )) {
          addRisk(
            result,
            section,
            objectName,
            'Incompatible field types: ' + salesforceField +
              ' -> ' + definition.value,
            definition.value
          );
        }
        continue;
      }

      result.missingRequiredFields.add(
        insight(
          section,
          objectName,
          definition.label,
          section + ': ' + definition.label + ' is not mapped.'
        )
      );
      QuickbridgeAssistantService.Suggestion suggestion = suggest(
        section,
        objectName,
        definition,
        fields,
        sourceSection,
        seenSalesforce
      );
      if (suggestion != null) result.suggestions.add(suggestion);
    }
  }

  private static PaymentInvoiceMappingController.MappingRow findRow(
    List<PaymentInvoiceMappingController.MappingRow> rows,
    String semanticField,
    Boolean sourceSection
  ) {
    for (PaymentInvoiceMappingController.MappingRow row : rows) {
      if (row == null) continue;
      String value = sourceSection ? row.targetField : row.sourceField;
      if (String.valueOf(value).equalsIgnoreCase(semanticField)) return row;
    }
    return null;
  }

  private static QuickbridgeAssistantService.Suggestion suggest(
    String section,
    String objectName,
    PaymentGatewaySchema.FieldDefinition definition,
    Map<String, Schema.SObjectField> fields,
    Boolean sourceSection,
    Set<String> occupiedFields
  ) {
    String preferred = sourceSection
      ? preferredSourceField(definition.value, fields)
      : resolveField(definition.defaultTargetField, fields);
    if (String.isBlank(preferred) || occupiedFields.contains(preferred.toLowerCase())) {
      return null;
    }
    Schema.DescribeFieldResult described = fields.get(preferred.toLowerCase()).getDescribe();
    if (!compatible(described.getType(), definition.type)) return null;

    QuickbridgeAssistantService.Suggestion value =
      new QuickbridgeAssistantService.Suggestion();
    value.workspaceKey = 'PaymentInvoice|' + section;
    value.salesforceObject = objectName;
    value.isLine = false;
    value.direction = sourceSection ? 'Outbound' : 'Inbound';
    value.salesforceField = described.getName();
    value.salesforceFieldLabel = described.getLabel();
    value.externalPath = definition.value;
    value.externalFieldLabel = definition.label;
    value.confidence = 95;
    value.confidenceLabel = 'High';
    value.canApply = true;
    value.reason = 'Schema-compatible packaged field for this payment value.';
    value.key = value.workspaceKey + ':' + value.salesforceField + ':' +
      value.externalPath;
    return value;
  }

  private static String preferredSourceField(
    String semanticField,
    Map<String, Schema.SObjectField> fields
  ) {
    Map<String, List<String>> candidates = new Map<String, List<String>>{
      'amount' => new List<String>{ 'TotalAmount', 'Amount', 'GrandTotal' },
      'referencenumber' => new List<String>{
        'OrderNumber', 'Reference_Number__c', 'Name'
      },
      'currency' => new List<String>{ 'CurrencyIsoCode', 'Currency__c' },
      'customeremail' => new List<String>{ 'Email', 'Email__c' },
      'customername' => new List<String>{ 'Name' },
      'description' => new List<String>{ 'Description' },
      'duedate' => new List<String>{ 'Due_Date__c', 'DueDate' }
    };
    List<String> preferredCandidates = candidates.get(normalized(semanticField));
    if (preferredCandidates == null) return null;
    for (String candidate : preferredCandidates) {
      String resolved = resolveField(candidate, fields);
      if (String.isNotBlank(resolved)) return resolved;
    }
    return null;
  }

  private static String resolveField(
    String fieldName,
    Map<String, Schema.SObjectField> fields
  ) {
    if (String.isBlank(fieldName)) return null;
    if (fields.containsKey(fieldName.toLowerCase())) {
      return fields.get(fieldName.toLowerCase()).getDescribe().getName();
    }
    String suffix = '__' + fieldName.toLowerCase();
    for (String key : fields.keySet()) {
      if (key.endsWith(suffix)) return fields.get(key).getDescribe().getName();
    }
    return null;
  }

  private static Map<String, Schema.SObjectField> fieldsFor(String objectName) {
    if (String.isBlank(objectName)) return new Map<String, Schema.SObjectField>();
    Schema.SObjectType objectType = Schema.getGlobalDescribe().get(objectName);
    if (objectType == null || !objectType.getDescribe().isAccessible()) {
      return new Map<String, Schema.SObjectField>();
    }
    return objectType.getDescribe().fields.getMap();
  }

  private static Boolean compatible(Schema.DisplayType salesforceType, String paymentType) {
    String sf = String.valueOf(salesforceType).toUpperCase();
    String external = String.valueOf(paymentType).toUpperCase();
    if (external == 'CURRENCY' || external == 'DECIMAL' || external == 'INTEGER') {
      return new Set<String>{
        'CURRENCY', 'DOUBLE', 'INTEGER', 'LONG', 'PERCENT'
      }.contains(sf);
    }
    if (external == 'DATE') return sf == 'DATE' || sf == 'DATETIME';
    if (external == 'DATETIME') return sf == 'DATETIME';
    if (external == 'BOOLEAN') return sf == 'BOOLEAN';
    if (external == 'URL') return sf == 'URL' || sf == 'STRING';
    if (external == 'EMAIL') return sf == 'EMAIL' || sf == 'STRING';
    return new Set<String>{
      'STRING', 'TEXTAREA', 'LONGTEXTAREA', 'URL', 'EMAIL', 'PHONE',
      'PICKLIST', 'ENCRYPTEDSTRING', 'ID', 'REFERENCE'
    }.contains(sf);
  }

  private static QuickbridgeAssistantService.Insight insight(
    String section,
    String objectName,
    String externalField,
    String message
  ) {
    QuickbridgeAssistantService.Insight value =
      new QuickbridgeAssistantService.Insight();
    value.key = section + ':' + externalField + ':' + message;
    value.severity = 'Required';
    value.message = message;
    value.salesforceObject = objectName;
    value.externalField = externalField;
    return value;
  }

  private static void addRisk(
    QuickbridgeAssistantService.Analysis result,
    String section,
    String objectName,
    String message,
    String externalField
  ) {
    QuickbridgeAssistantService.Insight value = insight(
      section,
      objectName,
      externalField,
      message
    );
    value.severity = 'Warning';
    for (QuickbridgeAssistantService.Insight existing : result.risks) {
      if (existing.key == value.key) return;
    }
    result.risks.add(value);
  }

  private static String buildFixPrompt(
    QuickbridgeAssistantService.Analysis result
  ) {
    List<String> lines = new List<String>{
      'Review Quickbridge hosted-payment mappings.',
      'Connector: ' + result.connectorKey,
      'Context: PaymentInvoice',
      'Analysis: ' + result.status,
      'Do not change credentials, secrets, webhooks, or unrelated mappings.'
    };
    for (QuickbridgeAssistantService.Insight item : result.missingRequiredFields) {
      lines.add('Missing: ' + item.message);
    }
    for (QuickbridgeAssistantService.Suggestion item : result.suggestions) {
      lines.add(
        'Review: ' + item.salesforceObject + '.' + item.salesforceField +
        ' -> ' + item.externalPath + ' (' + item.confidenceLabel + ')'
      );
    }
    return String.join(lines, '\n');
  }

  private static String normalized(String value) {
    return String.valueOf(value).toLowerCase().replaceAll('[^a-z0-9]', '');
  }

  private static void fail(String message) {
    AuraHandledException error = new AuraHandledException(message);
    error.setMessage(message);
    throw error;
  }
}