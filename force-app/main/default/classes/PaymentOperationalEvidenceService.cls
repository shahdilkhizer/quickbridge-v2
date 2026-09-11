/** Read-only evidence derived from validated hosted-payment mappings. */
public with sharing class PaymentOperationalEvidenceService {
  @TestVisible
  private static PaymentInvoiceMappingController.GatewayMappingConfig testConfigOverride;

  public class Evidence {
    public Boolean hostedPaymentObserved = false;
    public Boolean webhookObserved = false;
    public Boolean exactlyOneTransactionObserved = false;
    public Boolean paidInvoiceObserved = false;
    public Datetime hostedPaymentObservedAt;
    public Datetime webhookObservedAt;
    public String message;
  }

  public static Evidence inspect(String gateway) {
    Evidence result = new Evidence();
    try {
      PaymentInvoiceMappingController.GatewayMappingConfig config = Test.isRunningTest() &&
        testConfigOverride != null
        ? testConfigOverride
        : PaymentInvoiceMappingController.getGatewayMappingConfig(gateway);
      Map<String, String> invoiceFields = fieldsBySource(
        config.invoiceMappings
      );
      Map<String, String> transactionFields = fieldsBySource(
        config.transactionMappings
      );
      if (
        String.isBlank(config.invoiceObject) ||
        String.isBlank(config.invoiceSourceLookupField) ||
        String.isBlank(invoiceFields.get('paymentprovider')) ||
        String.isBlank(invoiceFields.get('hostedpaymenturl')) ||
        String.isBlank(invoiceFields.get('status'))
      ) {
        result.message = 'Complete invoice mappings to collect live payment evidence.';
        return result;
      }

      String providerField = safeField(
        config.invoiceObject,
        invoiceFields.get('paymentprovider')
      );
      String hostedUrlField = safeField(
        config.invoiceObject,
        invoiceFields.get('hostedpaymenturl')
      );
      String statusField = safeField(
        config.invoiceObject,
        invoiceFields.get('status')
      );
      String invoiceSourceField = safeField(
        config.invoiceObject,
        config.invoiceSourceLookupField
      );
      String gatewayValue = gateway;
      String invoiceQuery =
        'SELECT Id, CreatedDate, ' +
        providerField +
        ', ' +
        hostedUrlField +
        ', ' +
        statusField +
        ', ' +
        invoiceSourceField +
        ' FROM ' +
        safeObject(config.invoiceObject) +
        ' WHERE ' +
        providerField +
        ' = :gatewayValue WITH USER_MODE' +
        ' ORDER BY CreatedDate DESC LIMIT 1';
      List<SObject> invoices = Database.query(invoiceQuery);
      if (invoices.isEmpty()) {
        result.message = 'No hosted-payment launch has been observed.';
        return result;
      }

      SObject invoice = invoices[0];
      Object hostedUrl = invoice.get(hostedUrlField);
      result.hostedPaymentObserved =
        hostedUrl != null && String.isNotBlank(String.valueOf(hostedUrl));
      result.hostedPaymentObservedAt = result.hostedPaymentObserved
        ? (Datetime) invoice.get('CreatedDate')
        : null;
      result.paidInvoiceObserved = 'paid'
        .equalsIgnoreCase(String.valueOf(invoice.get(statusField)));

      if (
        String.isBlank(config.transactionObject) ||
        String.isBlank(config.transactionSourceLookupField) ||
        String.isBlank(transactionFields.get('providereventkey'))
      ) {
        result.message = 'Complete transaction mappings to collect webhook evidence.';
        return result;
      }
      String transactionSourceField = safeField(
        config.transactionObject,
        config.transactionSourceLookupField
      );
      String eventKeyField = safeField(
        config.transactionObject,
        transactionFields.get('providereventkey')
      );
      Object sourceId = invoice.get(invoiceSourceField);
      if (sourceId == null) {
        result.message = 'The latest hosted invoice has no source-record reference.';
        return result;
      }
      String transactionQuery =
        'SELECT Id, CreatedDate, ' +
        eventKeyField +
        ' FROM ' +
        safeObject(config.transactionObject) +
        ' WHERE ' +
        transactionSourceField +
        ' = :sourceId' +
        ' AND ' +
        eventKeyField +
        ' != null WITH USER_MODE' +
        ' ORDER BY CreatedDate DESC LIMIT 2';
      List<SObject> transactions = Database.query(transactionQuery);
      result.webhookObserved = !transactions.isEmpty();
      result.webhookObservedAt = result.webhookObserved
        ? (Datetime) transactions[0].get('CreatedDate')
        : null;
      result.exactlyOneTransactionObserved = transactions.size() == 1;
      if (!result.webhookObserved)
        result.message = 'No processed payment webhook has been observed.';
      else if (!result.exactlyOneTransactionObserved)
        result.message = 'Multiple payment transactions were found for the latest source record.';
      else if (!result.paidInvoiceObserved)
        result.message = 'A webhook was observed, but the latest invoice is not Paid.';
      else
        result.message = 'Hosted launch, webhook, transaction, and paid-invoice evidence were observed.';
    } catch (Exception error) {
      result.message = IntegrationErrorLogService.sanitizeForUser(
        error.getMessage()
      );
    }
    return result;
  }

  private static Map<String, String> fieldsBySource(
    List<PaymentInvoiceMappingController.MappingRow> rows
  ) {
    Map<String, String> result = new Map<String, String>();
    for (
      PaymentInvoiceMappingController.MappingRow row : rows == null
        ? new List<PaymentInvoiceMappingController.MappingRow>()
        : rows
    ) {
      if (
        String.isNotBlank(row.sourceField) && String.isNotBlank(row.targetField)
      ) {
        result.put(row.sourceField.toLowerCase(), row.targetField);
      }
    }
    return result;
  }

  private static String safeObject(String apiName) {
    Schema.SObjectType objectType = Schema.getGlobalDescribe().get(apiName);
    if (objectType == null || !objectType.getDescribe().isAccessible()) {
      throw new EvidenceException(
        'Mapped payment evidence object is unavailable.'
      );
    }
    return objectType.getDescribe().getName();
  }

  private static String safeField(String objectApiName, String fieldApiName) {
    Schema.SObjectType objectType = Schema.getGlobalDescribe()
      .get(objectApiName);
    if (objectType == null || String.isBlank(fieldApiName)) {
      throw new EvidenceException(
        'Mapped payment evidence field is unavailable.'
      );
    }
    Map<String, Schema.SObjectField> fields = objectType.getDescribe()
      .fields.getMap();
    if (
      !fields.containsKey(fieldApiName) ||
      !fields.get(fieldApiName).getDescribe().isAccessible()
    ) {
      throw new EvidenceException(
        'Mapped payment evidence field is unavailable.'
      );
    }
    return fields.get(fieldApiName).getDescribe().getName();
  }

  public class EvidenceException extends Exception {
  }
}