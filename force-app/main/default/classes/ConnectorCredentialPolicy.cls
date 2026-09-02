public inherited sharing class ConnectorCredentialPolicy {
  private static final Map<String, String> BASE_NAMES = new Map<String, String>{
    'qbo' => 'QuickBooks',
    'shopify' => 'Shopify',
    'netsuite' => 'NetSuite',
    'meta' => 'Meta',
    'klaviyo' => 'Klaviyo',
    'fedex' => 'FedEx',
    'ups' => 'UPS',
    'dhl' => 'DHL',
    'stripe' => 'Stripe',
    'paypal' => 'PayPal',
    'authorizenet' => 'AuthorizeNet'
  };

  public static String expectedNamedCredential(String connectorKey) {
    String baseName = BASE_NAMES.get(normalize(connectorKey));
    return baseName == null ? null : baseName + '_NC';
  }

  public static String expectedExternalCredential(String connectorKey) {
    String baseName = BASE_NAMES.get(normalize(connectorKey));
    return baseName == null ? null : baseName + '_EC';
  }

  public static String expectedPrincipal(String connectorKey) {
    String baseName = BASE_NAMES.get(normalize(connectorKey));
    return baseName == null ? null : baseName + '_Principal';
  }

  public static Set<String> supportedConnectorKeys() {
    return new Set<String>(BASE_NAMES.keySet());
  }

  private static String normalize(String value) {
    return String.isBlank(value) ? '' : value.trim().toLowerCase();
  }
}