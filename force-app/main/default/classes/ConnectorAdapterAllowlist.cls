public inherited sharing class ConnectorAdapterAllowlist {
  private static final Set<String> ALLOWED_CLASSES = new Set<String>{
    'QuickBooksHealthProbe',
    'ShopifyHealthProbe',
    'InboundIntegrationHandler',
    'OutboundIntegrationHandler',
    'NetSuiteHealthProbe',
    'NetSuiteIntegrationWorker',
    'NetSuiteScheduledOperationAdapter',
    'MetaHealthProbe',
    'MetaIntegrationWorker',
    'MetaScheduledOperationAdapter',
    'MetaWebhookEventHandler',
    'KlaviyoHealthProbe',
    'KlaviyoIntegrationWorker',
    'KlaviyoScheduledOperationAdapter',
    'FedExHealthProbe',
    'FedExCarrierAdapter',
    'UPSHealthProbe',
    'UPSCarrierAdapter',
    'DHLHealthProbe',
    'DHLCarrierAdapter',
    'StripeHealthProbe',
    'StripePaymentAdapter',
    'StripeHostedPaymentAdapter',
    'StripeWebhookEventHandler',
    'PayPalHealthProbe',
    'PayPalPaymentAdapter',
    'PayPalHostedPaymentAdapter',
    'PayPalWebhookEventHandler',
    'AuthorizeNetHealthProbe',
    'AuthorizeNetPaymentAdapter',
    'AuthorizeNetHostedPaymentAdapter',
    'AuthorizeNetWebhookEventHandler',
    'PaymentWebhookWorkHandler',
    'MetadataConnectorHealthProbe',
    'MetadataConnectorWorkAdapter',
    'MetadataConnectorScheduleAdapter',
    'MetadataConnectorWebhookAdapter',
    'MetadataConnectorCarrierAdapter',
    'MetadataConnectorPaymentAdapter',
    'MetadataConnectorHostedPaymentAdapter'
  };

  public static Boolean isAllowed(String className) {
    return String.isNotBlank(className) && ALLOWED_CLASSES.contains(className.trim());
  }

  @TestVisible
  private static Set<String> allowedClasses() {
    return new Set<String>(ALLOWED_CLASSES);
  }
}