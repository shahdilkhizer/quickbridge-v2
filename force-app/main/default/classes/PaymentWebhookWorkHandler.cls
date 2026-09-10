public without sharing class PaymentWebhookWorkHandler
  implements IntegrationWorkHandler {
  public ConnectorExecutionResult handle(Integration_Work_Item__c workItem) {
    if (workItem == null || String.isBlank(workItem.Integration__c) ||
        String.isBlank(workItem.Payload__c)) {
      return ConnectorExecutionResult.failed(
        'Payment webhook work is incomplete.',
        false,
        null
      );
    }
    String gateway = normalizeGateway(workItem.Integration__c);
    try {
      Map<String, Object> normalized = normalizePayload(
        gateway,
        workItem.Payload__c
      );
      persistTransaction(gateway, normalized);
      updateInvoice(gateway, normalized);
      ConnectorExecutionResult result = ConnectorExecutionResult.success();
      result.processedCount = 1;
      result.successfulCount = 1;
      return result;
    } catch (Exception error) {
      return ConnectorExecutionResult.failed(
        ConnectorExecutionResult.sanitizeError(error.getMessage()),
        isRetryable(error),
        null
      );
    }
  }

  @TestVisible
  private static Map<String, Object> normalizePayload(
    String gateway,
    String body
  ) {
    Map<String, Object> root;
    try { root = (Map<String, Object>) JSON.deserializeUntyped(body); }
    catch (Exception error) { throw new PaymentWebhookException('Webhook payload is invalid.'); }
    Map<String, Object> resource = root;
    if (gateway == 'stripe') resource = mapAt(root, 'data.object');
    else if (gateway == 'paypal') resource = mapAt(root, 'resource');
    else if (root.get('payload') instanceof Map<String, Object>) {
      resource = (Map<String, Object>) root.get('payload');
    }
    String eventId = stringAt(root, gateway == 'authorizenet' ? 'webhookId' : 'id');
    if (String.isBlank(eventId)) eventId = stringAt(root, 'notificationId');
    if (String.isBlank(eventId)) throw new PaymentWebhookException('Webhook event id is missing.');
    String eventType = stringAt(
      root,
      gateway == 'stripe' ? 'type' : (gateway == 'paypal' ? 'event_type' : 'eventType')
    );
    String sourceId = firstValue(new List<String>{
      stringAt(resource, 'metadata.sourceRecordId'),
      stringAt(resource, 'detail.reference'),
      stringAt(resource, 'custom_id'),
      stringAt(resource, 'refId')
    });
    String providerReference = firstValue(new List<String>{
      stringAt(resource, 'id'),
      stringAt(resource, 'invoice.id'),
      stringAt(resource, 'transId')
    });
    Decimal amount = firstDecimal(new List<Object>{
      valueAt(resource, 'amount_paid'),
      valueAt(resource, 'amount_received'),
      valueAt(resource, 'amount.value'),
      valueAt(resource, 'amount')
    });
    if (gateway == 'stripe' && amount != null) amount = amount / 100;
    String currencyCode = firstValue(new List<String>{
      stringAt(resource, 'currency'),
      stringAt(resource, 'amount.currency_code')
    });
    String providerStatus = firstValue(new List<String>{
      stringAt(resource, 'status'),
      stringAt(resource, 'state')
    });
    String invoiceStatus = normalizeInvoiceStatus(eventType, providerStatus);
    return new Map<String, Object>{
      'providerEventKey' => gateway + ':' + eventId,
      'gatewayEventId' => eventId,
      'gatewayEventType' => eventType,
      'gatewayEventDate' => System.now(),
      'gatewayAmount' => amount,
      'gatewayCurrency' => currencyCode,
      'gatewayReferenceNumber' => providerReference,
      'gatewayTransactionId' => firstValue(new List<String>{
        stringAt(resource, 'payment_intent'),
        stringAt(resource, 'transaction_info.transaction_id'),
        stringAt(resource, 'transId'),
        providerReference
      }),
      'paymentType' => paymentTypeLabel(gateway),
      'sourceRecordId' => sourceId,
      'providerReference' => providerReference,
      'status' => invoiceStatus,
      'stripeLiveMode' => valueAt(root, 'livemode'),
      'stripeStatus' => providerStatus,
      'paypalResourceStatus' => providerStatus,
      'authNetWebhookId' => eventId
    };
  }

  private static void persistTransaction(
    String gateway,
    Map<String, Object> normalized
  ) {
    PaymentInvoiceMappingController.GatewayMappingConfig config =
      PaymentInvoiceMappingController.getGatewayMappingConfig(gateway);
    Schema.SObjectType targetType =
      Schema.getGlobalDescribe().get(config.transactionObject);
    if (targetType == null) throw new PaymentWebhookException('Mapped transaction object is unavailable.');
    SObject transactionRecord = targetType.newSObject();
    Map<String, Schema.SObjectField> fields =
      targetType.getDescribe().fields.getMap();
    String externalIdField;
    for (PaymentInvoiceMappingController.MappingRow row : config.transactionMappings) {
      if (!fields.containsKey(row.targetField) || !normalized.containsKey(row.sourceField)) continue;
      transactionRecord.put(row.targetField, normalized.get(row.sourceField));
      if (row.sourceField == 'providerEventKey') externalIdField = row.targetField;
    }
    String sourceId = String.valueOf(normalized.get('sourceRecordId'));
    if (String.isNotBlank(sourceId) && sourceId != 'null') {
      try {
        Id typedId = Id.valueOf(sourceId);
        if (String.valueOf(typedId.getSObjectType()) == config.sourceObject) {
          transactionRecord.put(config.transactionSourceLookupField, typedId);
        }
      } catch (Exception ignored) {
        throw new PaymentWebhookException('Webhook source reference is invalid.');
      }
    }
    if (String.isBlank(externalIdField)) {
      throw new PaymentWebhookException('Provider event key mapping is required.');
    }
    Database.UpsertResult saved = Database.upsert(
      transactionRecord,
      fields.get(externalIdField),
      false
    );
    if (!saved.isSuccess()) {
      throw new PaymentWebhookException('Payment transaction could not be persisted.');
    }
  }

  private static void updateInvoice(
    String gateway,
    Map<String, Object> normalized
  ) {
    String providerReference = String.valueOf(normalized.get('providerReference'));
    String status = String.valueOf(normalized.get('status'));
    if (String.isBlank(providerReference) || providerReference == 'null' ||
        String.isBlank(status) || status == 'null') return;
    PaymentInvoiceMappingController.GatewayMappingConfig config =
      PaymentInvoiceMappingController.getGatewayMappingConfig(gateway);
    String referenceField;
    String statusField;
    for (PaymentInvoiceMappingController.MappingRow row : config.invoiceMappings) {
      if (row.sourceField == 'providerReference') referenceField = row.targetField;
      if (row.sourceField == 'status') statusField = row.targetField;
    }
    Schema.SObjectType invoiceType = Schema.getGlobalDescribe().get(config.invoiceObject);
    if (invoiceType == null || String.isBlank(referenceField) || String.isBlank(statusField)) return;
    Map<String, Schema.SObjectField> fields = invoiceType.getDescribe().fields.getMap();
    if (!fields.containsKey(referenceField) || !fields.containsKey(statusField)) return;
    List<SObject> invoices = Database.query(
      'SELECT Id,' + statusField + ' FROM ' + config.invoiceObject +
      ' WHERE ' + referenceField + ' = :providerReference LIMIT 1'
    );
    if (invoices.isEmpty()) return;
    invoices[0].put(statusField, status);
    Database.update(invoices[0], false);
  }

  private static Map<String, Object> mapAt(Map<String, Object> root, String path) {
    Object value = valueAt(root, path);
    return value instanceof Map<String, Object>
      ? (Map<String, Object>) value
      : new Map<String, Object>();
  }
  private static Object valueAt(Map<String, Object> root, String path) {
    Object current = root;
    for (String segment : path.split('\\.')) {
      if (!(current instanceof Map<String, Object>)) return null;
      current = ((Map<String, Object>) current).get(segment);
    }
    return current;
  }
  private static String stringAt(Map<String, Object> root, String path) {
    Object value = valueAt(root, path);
    return value == null ? null : String.valueOf(value);
  }
  private static String firstValue(List<String> values) {
    for (String value : values) if (String.isNotBlank(value)) return value;
    return null;
  }
  private static Decimal firstDecimal(List<Object> values) {
    for (Object value : values) {
      if (value == null) continue;
      try { return Decimal.valueOf(String.valueOf(value)); }
      catch (Exception ignored) {}
    }
    return null;
  }
  private static Boolean isRetryable(Exception error) {
    String message = String.valueOf(error.getMessage()).toLowerCase();
    return message.contains('timeout') || message.contains('lock') ||
      message.contains('temporar');
  }

  private static String paymentTypeLabel(String gateway) {
    if (gateway == 'authorizenet') return 'Authorize.Net';
    if (gateway == 'paypal') return 'PayPal';
    return 'Stripe';
  }

  private static String normalizeInvoiceStatus(
    String eventType,
    String providerStatus
  ) {
    String value = (
      String.valueOf(eventType) + ' ' + String.valueOf(providerStatus)
    ).toLowerCase();
    if (value.contains('refund') || value.contains('void') ||
        value.contains('cancel') || value.contains('declin') ||
        value.contains('denied') || value.contains('failed')) {
      return 'Cancelled';
    }
    if (value.contains('paid') || value.contains('captur') ||
        value.contains('settled') || value.contains('completed') ||
        value.contains('authcapture')) {
      return 'Paid';
    }
    if (value.contains('open') || value.contains('sent') ||
        value.contains('pending') || value.contains('authorized')) {
      return 'Open';
    }
    return null;
  }
  private static String normalizeGateway(String value) {
    String result = value == null
      ? '' : value.trim().toLowerCase().replaceAll('[^a-z0-9]', '');
    if (!new Set<String>{ 'stripe', 'paypal', 'authorizenet' }.contains(result)) {
      throw new PaymentWebhookException('Unsupported payment webhook provider.');
    }
    return result;
  }
  public class PaymentWebhookException extends Exception {}
}