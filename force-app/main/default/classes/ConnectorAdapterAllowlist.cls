public inherited sharing class ConnectorAdapterAllowlist {
  private static final Set<String> ALLOWED_CLASSES = new Set<String>{
    'QuickBooksHealthProbe',
    'ShopifyHealthProbe',
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
    'StripeWebhookEventHandler',
    'PayPalHealthProbe',
    'PayPalPaymentAdapter',
    'PayPalWebhookEventHandler',
    'AuthorizeNetHealthProbe',
    'AuthorizeNetPaymentAdapter',
    'AuthorizeNetWebhookEventHandler'
  };

  public static Boolean isAllowed(String className) {
    return String.isNotBlank(className) && ALLOWED_CLASSES.contains(className.trim());
  }

  @TestVisible
  private static Set<String> allowedClasses() {
    return new Set<String>(ALLOWED_CLASSES);
  }
}