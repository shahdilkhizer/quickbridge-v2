public inherited sharing class PaymentGatewaySchema {
  public class FieldDefinition {
    @AuraEnabled public String label;
    @AuraEnabled public String value;
    @AuraEnabled public String type;
    @AuraEnabled public Boolean required;
    @AuraEnabled public String defaultTargetField;

    public FieldDefinition(
      String labelValue,
      String valueValue,
      String typeValue,
      Boolean requiredValue,
      String defaultTargetFieldValue
    ) {
      label = labelValue;
      value = valueValue;
      type = typeValue;
      required = requiredValue;
      defaultTargetField = defaultTargetFieldValue;
    }
  }

  public class Contract {
    @AuraEnabled public String gateway;
    @AuraEnabled public String label;
    @AuraEnabled public List<FieldDefinition> requestFields = new List<FieldDefinition>();
    @AuraEnabled public List<FieldDefinition> invoiceResultFields = new List<FieldDefinition>();
    @AuraEnabled public List<FieldDefinition> transactionFields = new List<FieldDefinition>();
  }

  public static Contract forGateway(String gateway) {
    String keyValue = normalize(gateway);
    Contract result = new Contract();
    result.gateway = keyValue;
    result.label = keyValue == 'authorizenet'
      ? 'Authorize.Net'
      : (keyValue == 'paypal' ? 'PayPal' : 'Stripe');

    result.requestFields.add(field('Amount', 'amount', 'Currency', true, null));
    result.requestFields.add(field('Currency', 'currency', 'String', false, null));
    result.requestFields.add(field('Reference Number', 'referenceNumber', 'String', true, null));
    result.requestFields.add(field('Customer Email', 'customerEmail', 'Email', false, null));
    result.requestFields.add(field('Customer Name', 'customerName', 'String', false, null));
    result.requestFields.add(field('Description', 'description', 'String', false, null));
    result.requestFields.add(field('Due Date', 'dueDate', 'Date', false, null));

    result.invoiceResultFields.add(field('Amount', 'amount', 'Currency', true, 'Amount__c'));
    result.invoiceResultFields.add(field('Currency', 'currency', 'String', true, 'Currency__c'));
    result.invoiceResultFields.add(field('Reference Number', 'referenceNumber', 'String', true, 'Reference_number__c'));
    result.invoiceResultFields.add(field('Status', 'status', 'String', true, 'Status__c'));
    result.invoiceResultFields.add(field('Invoice Date', 'invoiceDate', 'Date', true, 'Invoice_Date__c'));
    result.invoiceResultFields.add(field('Payment Provider', 'paymentProvider', 'String', true, 'Payment_Provider__c'));
    result.invoiceResultFields.add(field('Provider Reference', 'providerReference', 'String', true, 'Provider_Reference__c'));
    result.invoiceResultFields.add(field('Hosted Payment URL', 'hostedPaymentUrl', 'Url', true, 'Hosted_Payment_URL__c'));
    result.invoiceResultFields.add(field('Session Expiration', 'sessionExpiration', 'Datetime', false, 'Hosted_Session_Expires_At__c'));
    result.invoiceResultFields.add(field('Customer Email', 'customerEmail', 'Email', false, null));

    addCommonTransactionFields(result.transactionFields);
    if (keyValue == 'stripe') {
      result.transactionFields.add(field('Stripe Live Mode', 'stripeLiveMode', 'Boolean', false, 'Stripe_Live_Mode__c'));
      result.transactionFields.add(field('Stripe Status', 'stripeStatus', 'String', false, null));
      result.transactionFields.add(field('Stripe Customer Id', 'stripeCustomerId', 'String', false, null));
      result.transactionFields.add(field('Stripe Invoice PDF URL', 'stripeInvoicePdfUrl', 'Url', false, null));
    } else if (keyValue == 'paypal') {
      result.transactionFields.add(field('PayPal Invoice Id', 'paypalInvoiceId', 'String', false, null));
      result.transactionFields.add(field('PayPal Payer Id', 'paypalPayerId', 'String', false, null));
      result.transactionFields.add(field('PayPal Payer Email', 'paypalPayerEmail', 'Email', false, null));
      result.transactionFields.add(field('PayPal Resource Status', 'paypalResourceStatus', 'String', false, null));
    } else {
      result.transactionFields.add(field('Authorize.Net Webhook Id', 'authNetWebhookId', 'String', false, null));
      result.transactionFields.add(field('Authorize.Net Response Code', 'authNetResponseCode', 'Integer', false, null));
      result.transactionFields.add(field('Authorize.Net Auth Code', 'authNetAuthCode', 'String', false, null));
      result.transactionFields.add(field('Authorize.Net AVS Response', 'authNetAvsResponse', 'String', false, null));
    }
    return result;
  }

  private static void addCommonTransactionFields(List<FieldDefinition> fields) {
    fields.add(field('Provider Event Key', 'providerEventKey', 'String', true, 'Provider_Event_Key__c'));
    fields.add(field('Gateway Event Id', 'gatewayEventId', 'String', true, 'Gateway_Event_Id__c'));
    fields.add(field('Gateway Event Type', 'gatewayEventType', 'String', true, 'Gateway_Event_Type__c'));
    fields.add(field('Gateway Event Date', 'gatewayEventDate', 'Datetime', false, 'Gateway_Event_Date__c'));
    fields.add(field('Gateway Amount', 'gatewayAmount', 'Currency', true, 'Gateway_Amount__c'));
    fields.add(field('Gateway Currency', 'gatewayCurrency', 'String', true, null));
    fields.add(field('Gateway Reference Number', 'gatewayReferenceNumber', 'String', true, 'Gateway_Reference_Number__c'));
    fields.add(field('Gateway Transaction Id', 'gatewayTransactionId', 'String', true, 'Gateway_Transaction_Id__c'));
    fields.add(field('Payment Type', 'paymentType', 'String', true, 'Payment_Type__c'));
  }

  private static FieldDefinition field(
    String labelValue,
    String valueValue,
    String typeValue,
    Boolean requiredValue,
    String defaultTargetFieldValue
  ) {
    return new FieldDefinition(
      labelValue,
      valueValue,
      typeValue,
      requiredValue,
      defaultTargetFieldValue
    );
  }

  private static String normalize(String gateway) {
    String result = String.isBlank(gateway)
      ? ''
      : gateway.trim().toLowerCase().replaceAll('[^a-z0-9]', '');
    if (!new Set<String>{ 'stripe', 'paypal', 'authorizenet' }.contains(result)) {
      throw new AuraHandledException('Unsupported payment gateway.');
    }
    return result;
  }
}