public with sharing class HostedPaymentService {
  public static HostedPaymentResult create(String connectorKey, Id sourceRecordId) {
    String gateway = normalizeGateway(connectorKey);
    PaymentInvoiceMappingController.GatewayMappingConfig config =
      PaymentInvoiceMappingController.getGatewayMappingConfig(gateway);
    if (sourceRecordId == null || config.sourceObject !=
        String.valueOf(sourceRecordId.getSObjectType())) {
      throw handled('The source record does not match the payment mapping.');
    }
    if (config.sourceMappings == null || config.sourceMappings.isEmpty()) {
      throw handled('Complete and save the payment mappings first.');
    }
    Schema.SObjectType sourceType = sourceRecordId.getSObjectType();
    if (!sourceType.getDescribe().isAccessible()) {
      throw handled('The source record is unavailable.');
    }
    Set<String> sourceFields = new Set<String>();
    for (PaymentInvoiceMappingController.MappingRow row : config.sourceMappings) {
      if (String.isNotBlank(row.sourceField)) sourceFields.add(row.sourceField);
    }
    if (String.isNotBlank(config.sourceEmailField)) {
      sourceFields.add(config.sourceEmailField);
    }
    List<String> selectFields = new List<String>{ 'Id' };
    selectFields.addAll(sourceFields);
    String sourceQuery =
      'SELECT ' + String.join(selectFields, ',') + ' FROM ' +
      config.sourceObject + ' WHERE Id = :sourceRecordId WITH USER_MODE LIMIT 1';
    if (gateway == 'stripe') sourceQuery += ' FOR UPDATE';
    SObject sourceRecord = Database.query(sourceQuery);
    if (gateway == 'stripe') {
      HostedPaymentResult existingPayment = existingStripePayment(
        config,
        sourceRecordId,
        gateway
      );
      if (existingPayment != null) return existingPayment;
    }
    Map<String, Object> mapped = new Map<String, Object>();
    for (PaymentInvoiceMappingController.MappingRow row : config.sourceMappings) {
      mapped.put(row.targetField, valueAt(sourceRecord, row.sourceField));
    }
    if (!mapped.containsKey('customerEmail') ||
        mapped.get('customerEmail') == null) {
      mapped.put('customerEmail', valueAt(sourceRecord, config.sourceEmailField));
    }

    HostedPaymentRequest request = toRequest(gateway, sourceRecordId, mapped);
    HostedPaymentResult result =
      ConnectorCapabilityRouter.hostedPaymentAdapter(gateway)
        .createHostedPayment(request);
    if (result == null || result.successful != true) return result;
    result.invoiceRecordId = persistInvoice(config, sourceRecordId, request, result);
    return result;
  }

  private static HostedPaymentRequest toRequest(
    String gateway,
    Id sourceRecordId,
    Map<String, Object> values
  ) {
    HostedPaymentRequest request = new HostedPaymentRequest();
    request.connectorKey = gateway;
    request.sourceRecordId = sourceRecordId;
    request.amount = decimalValue(values.get('amount'));
    request.currencyCode = stringValue(values.get('currency'));
    if (String.isBlank(request.currencyCode)) request.currencyCode = 'USD';
    request.currencyCode = request.currencyCode.left(3).toUpperCase();
    request.referenceNumber = stringValue(values.get('referenceNumber'));
    if (String.isBlank(request.referenceNumber)) {
      request.referenceNumber = String.valueOf(sourceRecordId);
    }
    request.customerEmail = stringValue(values.get('customerEmail'));
    request.customerName = stringValue(values.get('customerName'));
    request.description = stringValue(values.get('description'));
    request.dueDate = dateValue(values.get('dueDate'));
    request.idempotencyKey = gateway + ':' + String.valueOf(sourceRecordId) +
      ':' + request.referenceNumber;
    if (request.amount == null || request.amount <= 0 ||
        String.isBlank(request.customerEmail)) {
      throw handled('Mapped amount and customer email values are required.');
    }
    return request;
  }

  private class ExistingInvoiceFields {
    String sourceLookupField;
    String paymentProviderField;
    String statusField;
    String providerReferenceField;
    String hostedUrlField;
  }

  private static HostedPaymentResult existingStripePayment(
    PaymentInvoiceMappingController.GatewayMappingConfig config,
    Id sourceRecordId,
    String gateway
  ) {
    ExistingInvoiceFields fields = existingInvoiceFields(config);
    SObject paidInvoice = findExistingInvoice(
      config,
      fields,
      sourceRecordId,
      gateway,
      true
    );
    if (paidInvoice != null) {
      throw handled(
        'A Stripe invoice for this record is already paid. A new payment cannot be created.'
      );
    }

    SObject existingInvoice = findExistingInvoice(
      config,
      fields,
      sourceRecordId,
      gateway,
      false
    );
    if (existingInvoice == null) return null;

    String status = stringValue(existingInvoice.get(fields.statusField));
    String hostedUrl = stringValue(existingInvoice.get(fields.hostedUrlField));
    if ('Open'.equalsIgnoreCase(status) && String.isNotBlank(hostedUrl)) {
      HostedPaymentResult result = new HostedPaymentResult();
      result.successful = true;
      result.reusedExisting = true;
      result.invoiceRecordId = (Id) existingInvoice.get('Id');
      result.providerReference = stringValue(
        existingInvoice.get(fields.providerReferenceField)
      );
      result.status = status;
      result.hostedUrl = hostedUrl;
      result.launchMode = 'REDIRECT';
      return result;
    }

    if ('Open'.equalsIgnoreCase(status)) {
      throw handled(
        'An existing Stripe invoice is open but has no hosted payment URL. A new payment cannot be created.'
      );
    }
    throw handled(
      'An existing Stripe invoice is ' +
      (String.isBlank(status) ? 'unavailable' : status) +
      '. Resolve that invoice before creating a new payment.'
    );
  }

  private static SObject findExistingInvoice(
    PaymentInvoiceMappingController.GatewayMappingConfig config,
    ExistingInvoiceFields fields,
    Id sourceRecordId,
    String gateway,
    Boolean paidOnly
  ) {
    String query =
      'SELECT Id,' + fields.statusField + ',' + fields.providerReferenceField +
      ',' + fields.hostedUrlField + ' FROM ' + config.invoiceObject +
      ' WHERE ' + fields.sourceLookupField + ' = :sourceRecordId AND ' +
      fields.paymentProviderField + ' = :gateway';
    if (paidOnly) query += ' AND ' + fields.statusField + ' = \'Paid\'';
    query += ' WITH USER_MODE ORDER BY CreatedDate DESC LIMIT 1';
    List<SObject> invoices = Database.query(query);
    return invoices.isEmpty() ? null : invoices[0];
  }

  private static ExistingInvoiceFields existingInvoiceFields(
    PaymentInvoiceMappingController.GatewayMappingConfig config
  ) {
    if (config == null || String.isBlank(config.invoiceObject)) {
      throw handled('The mapped invoice object is unavailable.');
    }
    Schema.SObjectType invoiceType = Schema.getGlobalDescribe().get(config.invoiceObject);
    if (invoiceType == null || !invoiceType.getDescribe().isAccessible()) {
      throw handled('The mapped invoice object is unavailable.');
    }
    Map<String, String> mappedFields = new Map<String, String>();
    for (PaymentInvoiceMappingController.MappingRow row : config.invoiceMappings) {
      if (row != null && String.isNotBlank(row.sourceField) &&
          String.isNotBlank(row.targetField)) {
        mappedFields.put(row.sourceField, row.targetField);
      }
    }
    Map<String, Schema.SObjectField> fields = invoiceType.getDescribe().fields.getMap();
    ExistingInvoiceFields result = new ExistingInvoiceFields();
    result.sourceLookupField = requireInvoiceField(
      fields,
      config.invoiceSourceLookupField
    );
    result.paymentProviderField = requireInvoiceField(
      fields,
      mappedFields.get('paymentProvider')
    );
    result.statusField = requireInvoiceField(fields, mappedFields.get('status'));
    result.providerReferenceField = requireInvoiceField(
      fields,
      mappedFields.get('providerReference')
    );
    result.hostedUrlField = requireInvoiceField(
      fields,
      mappedFields.get('hostedPaymentUrl')
    );
    return result;
  }

  private static String requireInvoiceField(
    Map<String, Schema.SObjectField> fields,
    String configuredName
  ) {
    if (fields != null && String.isNotBlank(configuredName)) {
      for (String fieldName : fields.keySet()) {
        if (fieldName.equalsIgnoreCase(configuredName)) {
          Schema.DescribeFieldResult describeResult = fields.get(fieldName).getDescribe();
          if (describeResult.isAccessible()) return describeResult.getName();
        }
      }
    }
    throw handled('The payment invoice mappings are incomplete.');
  }

  private static Id persistInvoice(
    PaymentInvoiceMappingController.GatewayMappingConfig config,
    Id sourceRecordId,
    HostedPaymentRequest request,
    HostedPaymentResult result
  ) {
    Schema.SObjectType targetType = Schema.getGlobalDescribe().get(config.invoiceObject);
    if (targetType == null || !targetType.getDescribe().isCreateable()) {
      throw handled('The mapped invoice object is not createable.');
    }
    Map<String, Object> normalized = new Map<String, Object>{
      'amount' => request.amount,
      'currency' => request.currencyCode,
      'referenceNumber' => request.referenceNumber,
      'status' => normalizeInvoiceStatus(result.status),
      'invoiceDate' => Date.today(),
      'paymentProvider' => request.connectorKey,
      'providerReference' => result.providerReference,
      'hostedPaymentUrl' => result.hostedUrl,
      'sessionExpiration' => result.expiresAt,
      'customerEmail' => request.customerEmail
    };
    SObject invoice = targetType.newSObject();
    invoice.put(config.invoiceSourceLookupField, sourceRecordId);
    for (PaymentInvoiceMappingController.MappingRow row : config.invoiceMappings) {
      if (String.isNotBlank(row.targetField) && normalized.containsKey(row.sourceField)) {
        invoice.put(row.targetField, normalized.get(row.sourceField));
      }
    }
    SObjectAccessDecision access = Security.stripInaccessible(
      AccessType.CREATABLE,
      new List<SObject>{ invoice }
    );
    SObject safeInvoice = access.getRecords()[0];
    Database.SaveResult saved = Database.insert(safeInvoice, false);
    if (!saved.isSuccess()) {
      throw handled('The hosted payment was created, but the Salesforce invoice could not be saved.');
    }
    return saved.getId();
  }

  private static Object valueAt(SObject recordValue, String path) {
    if (recordValue == null || String.isBlank(path)) return null;
    List<String> segments = path.split('\\.');
    SObject current = recordValue;
    for (Integer i = 0; i < segments.size() - 1; i++) {
      current = current == null ? null : current.getSObject(segments[i]);
    }
    return current == null ? null : current.get(segments[segments.size() - 1]);
  }

  private static Decimal decimalValue(Object value) {
    if (value == null) return null;
    try { return Decimal.valueOf(String.valueOf(value)); }
    catch (Exception error) { throw handled('The mapped amount is invalid.'); }
  }
  private static String stringValue(Object value) {
    return value == null ? null : String.valueOf(value);
  }
  private static Date dateValue(Object value) {
    if (value == null) return null;
    if (value instanceof Date) return (Date) value;
    try { return Date.valueOf(String.valueOf(value)); }
    catch (Exception error) { throw handled('The mapped due date is invalid.'); }
  }
  @TestVisible
  private static String normalizeInvoiceStatus(String providerStatus) {
    String value = String.valueOf(providerStatus).toLowerCase();
    if (value.contains('refund') || value.contains('void') ||
        value.contains('cancel') || value.contains('declin') ||
        value.contains('denied') || value.contains('failed')) {
      return 'Cancelled';
    }
    if (value.contains('paid') || value.contains('captur') ||
        value.contains('settled') || value.contains('completed')) {
      return 'Paid';
    }
    return 'Open';
  }
  private static String normalizeGateway(String value) {
    String result = String.isBlank(value)
      ? '' : value.trim().toLowerCase().replaceAll('[^a-z0-9]', '');
    if (!new Set<String>{ 'stripe', 'paypal', 'authorizenet' }.contains(result)) {
      throw handled('Unsupported payment provider.');
    }
    return result;
  }
  private static AuraHandledException handled(String message) {
    AuraHandledException error = new AuraHandledException(message);
    error.setMessage(message);
    return error;
  }
}