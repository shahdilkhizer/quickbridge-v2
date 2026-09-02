public inherited sharing class ConnectorCapabilityRouter {
  @TestVisible
  private static Map<String, String> testAdapterByCapability =
    new Map<String, String>();
  private static Map<String, String> adapterByCapability;

  public static ConnectorHealthProbe healthProbe(String connectorKey) {
    Object adapter = instantiate(connectorKey, 'health.probe');
    if (!(adapter instanceof ConnectorHealthProbe)) {
      throw new ConnectorCapabilityException(
        'Configured health adapter does not implement ConnectorHealthProbe.'
      );
    }
    return (ConnectorHealthProbe) adapter;
  }

  public static IntegrationWorkHandler workHandler(
    String connectorKey,
    String operation
  ) {
    Object adapter = instantiate(connectorKey, 'work.' + requireToken(operation));
    if (!(adapter instanceof IntegrationWorkHandler)) {
      throw new ConnectorCapabilityException(
        'Configured work adapter does not implement IntegrationWorkHandler.'
      );
    }
    return (IntegrationWorkHandler) adapter;
  }

  public static ScheduledOperationAdapter scheduledAdapter(String connectorKey) {
    Object adapter = instantiate(connectorKey, 'scheduler.operation');
    if (!(adapter instanceof ScheduledOperationAdapter)) {
      throw new ConnectorCapabilityException(
        'Configured schedule adapter does not implement ScheduledOperationAdapter.'
      );
    }
    return (ScheduledOperationAdapter) adapter;
  }

  public static WebhookEventHandler webhookHandler(String connectorKey) {
    Object adapter = instantiate(connectorKey, 'webhook.event');
    if (!(adapter instanceof WebhookEventHandler)) {
      throw new ConnectorCapabilityException(
        'Configured webhook adapter does not implement WebhookEventHandler.'
      );
    }
    return (WebhookEventHandler) adapter;
  }

  public static CarrierAdapter carrierAdapter(String connectorKey) {
    Object adapter = instantiate(connectorKey, 'carrier.operation');
    if (!(adapter instanceof CarrierAdapter)) {
      throw new ConnectorCapabilityException(
        'Configured carrier adapter does not implement CarrierAdapter.'
      );
    }
    return (CarrierAdapter) adapter;
  }

  public static PaymentProviderAdapter paymentAdapter(String connectorKey) {
    Object adapter = instantiate(connectorKey, 'payment.checkout');
    if (!(adapter instanceof PaymentProviderAdapter)) {
      throw new ConnectorCapabilityException(
        'Configured payment adapter does not implement PaymentProviderAdapter.'
      );
    }
    return (PaymentProviderAdapter) adapter;
  }

  public static Boolean hasCapability(String connectorKey, String capabilityKey) {
    return String.isNotBlank(
      adapterClassName(requireToken(connectorKey), requireCapability(capabilityKey))
    );
  }

  private static Object instantiate(String connectorKey, String capabilityKey) {
    String safeConnector = requireToken(connectorKey);
    String safeCapability = requireCapability(capabilityKey);
    String className = adapterClassName(safeConnector, safeCapability);
    if (String.isBlank(className)) {
      throw new ConnectorCapabilityException(
        'No enabled adapter is configured for ' + safeConnector + '.' + safeCapability + '.'
      );
    }
    if (!ConnectorAdapterAllowlist.isAllowed(className)) {
      throw new ConnectorCapabilityException('Configured adapter is not allowlisted.');
    }
    Type adapterType = Type.forName(className);
    if (adapterType == null) {
      throw new ConnectorCapabilityException('Configured adapter class is unavailable.');
    }
    return adapterType.newInstance();
  }

  private static String adapterClassName(String connectorKey, String capabilityKey) {
    String cacheKey = normalize(connectorKey) + ':' + normalize(capabilityKey);
    if (Test.isRunningTest() && testAdapterByCapability.containsKey(cacheKey)) {
      return testAdapterByCapability.get(cacheKey);
    }
    if (adapterByCapability == null) {
      adapterByCapability = new Map<String, String>();
      Set<String> enabledConnectors = new Set<String>();
      for (Integration_Connector__mdt connector : [
        SELECT Connector_Key__c
        FROM Integration_Connector__mdt
        WHERE Enabled__c = true
      ]) {
        enabledConnectors.add(normalize(connector.Connector_Key__c));
      }
      for (Integration_Connector_Capability__mdt capability : [
        SELECT Connector_Key__c, Capability_Key__c, Adapter_Class__c
        FROM Integration_Connector_Capability__mdt
        WHERE Enabled__c = true
      ]) {
        String connectorValue = normalize(capability.Connector_Key__c);
        if (
          enabledConnectors.contains(connectorValue) &&
          String.isNotBlank(capability.Adapter_Class__c)
        ) {
          adapterByCapability.put(
            connectorValue + ':' + normalize(capability.Capability_Key__c),
            capability.Adapter_Class__c.trim()
          );
        }
      }
    }
    return adapterByCapability.get(cacheKey);
  }

  @TestVisible
  private static void registerTestAdapter(
    String connectorKey,
    String capabilityKey,
    String className
  ) {
    testAdapterByCapability.put(
      normalize(requireToken(connectorKey)) + ':' + normalize(requireCapability(capabilityKey)),
      className
    );
  }

  @TestVisible
  private static void clearTestAdapters() {
    testAdapterByCapability.clear();
    adapterByCapability = null;
  }

  private static String requireToken(String value) {
    if (
      String.isBlank(value) ||
      !Pattern.matches('^[A-Za-z][A-Za-z0-9_-]{0,79}$', value.trim())
    ) {
      throw new ConnectorCapabilityException('Connector or operation key is invalid.');
    }
    return value.trim();
  }

  private static String requireCapability(String value) {
    if (
      String.isBlank(value) ||
      !Pattern.matches('^[A-Za-z][A-Za-z0-9_.-]{0,99}$', value.trim())
    ) {
      throw new ConnectorCapabilityException('Capability key is invalid.');
    }
    return value.trim();
  }

  private static String normalize(String value) {
    return String.isBlank(value)
      ? ''
      : value.trim().toLowerCase().replaceAll('[^a-z0-9]', '');
  }

  public class ConnectorCapabilityException extends Exception {}
}