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
    SObject sourceRecord = Database.query(
      'SELECT ' + String.join(selectFields, ',') + ' FROM ' +
      config.sourceObject + ' WHERE Id = :sourceRecordId WITH USER_MODE LIMIT 1'
    );
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