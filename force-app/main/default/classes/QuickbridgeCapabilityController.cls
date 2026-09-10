public with sharing class QuickbridgeCapabilityController {
  public class ProviderOption {
    @AuraEnabled public String key;
    @AuraEnabled public String label;
  }

  @AuraEnabled(cacheable=true)
  public static List<ProviderOption> availableProviders(String capabilityKey) {
    String safeCapability = requireCapability(capabilityKey);
    Map<String, String> labelByKey = new Map<String, String>();
    for (Integration_Connector__mdt connector : [
      SELECT Connector_Key__c, Provider_Label__c
      FROM Integration_Connector__mdt
      WHERE Enabled__c = true
    ]) {
      labelByKey.put(connector.Connector_Key__c.toLowerCase(), connector.Provider_Label__c);
    }
    Set<String> enabledKeys = new Set<String>();
    for (Integration_Connector_Capability__mdt capability : [
      SELECT Connector_Key__c
      FROM Integration_Connector_Capability__mdt
      WHERE Enabled__c = true AND Capability_Key__c = :safeCapability
    ]) {
      enabledKeys.add(capability.Connector_Key__c.toLowerCase());
    }
    List<ProviderOption> result = new List<ProviderOption>();
    for (Connector_Instance__c instanceRecord : [
      SELECT Connector_Key__c, Active__c, Health_Status__c
      FROM Connector_Instance__c
      WHERE Connector_Key__c IN :enabledKeys
    ]) {
      if (instanceRecord.Active__c != true || instanceRecord.Health_Status__c != 'Ready') continue;
      ProviderOption option = new ProviderOption();
      option.key = instanceRecord.Connector_Key__c.toLowerCase();
      option.label = labelByKey.get(option.key);
      result.add(option);
    }
    return result;
  }

  @AuraEnabled(cacheable=true)
  public static Map<String, String> paymentSettings(String connectorKey) {
    String keyValue = requireReadyConnector(connectorKey, 'payment.checkout');
    Map<String, Set<String>> allowedByConnector = new Map<String, Set<String>>{
      'stripe' => new Set<String>{ 'publishableKey' },
      'paypal' => new Set<String>{ 'clientId' },
      'authorizenet' => new Set<String>{ 'apiLoginId', 'clientKey' }
    };
    Set<String> allowed = allowedByConnector.get(keyValue);
    if (allowed == null) throw new AuraHandledException('Unsupported payment provider.');
    Map<String, String> result = new Map<String, String>();
    for (Connector_Config_Value__c valueRecord : [
      SELECT Field_Key__c, Value__c
      FROM Connector_Config_Value__c
      WHERE Connector_Key__c = :keyValue
        AND Field_Key__c IN :allowed
        AND Is_Secret_Reference__c = false
    ]) {
      result.put(valueRecord.Field_Key__c, valueRecord.Value__c);
    }
    return result;
  }

  @AuraEnabled
  public static PaymentCapabilityResult submitPayment(
    String connectorKey,
    Id sourceRecordId,
    Decimal amount,
    String currencyCode,
    String providerToken,
    String idempotencyKey,
    String attributesJson,
    String action
  ) {
    String keyValue = requireReadyConnector(connectorKey, 'payment.checkout');
    assertRecordAccess(sourceRecordId);
    PaymentCapabilityRequest request = new PaymentCapabilityRequest();
    request.connectorKey = keyValue;
    request.sourceRecordId = sourceRecordId;
    request.amount = amount;
    request.currencyCode = String.isBlank(currencyCode) ? 'USD' : currencyCode.left(3).toUpperCase();
    request.providerToken = providerToken;
    request.idempotencyKey = idempotencyKey;
    request.operation = String.isBlank(action) ? 'execute' : action.toLowerCase();
    request.attributes = safeAttributes(attributesJson);
    PaymentProviderAdapter adapter = ConnectorCapabilityRouter.paymentAdapter(keyValue);
    PaymentCapabilityResult result;
    if (request.operation == 'initialize') result = adapter.initializePayment(request);
    else if (request.operation == 'recover') result = adapter.recoverPayment(request);
    else if (request.operation == 'refund') result = adapter.refundPayment(request);
    else result = adapter.executePayment(request);
    persistPaymentOutcome(sourceRecordId, keyValue, request.operation, result);
    return result;
  }

  @AuraEnabled
  public static HostedPaymentResult createHostedPayment(
    String connectorKey,
    Id sourceRecordId
  ) {
    String keyValue = requireReadyConnector(connectorKey, 'payment.hosted');
    assertRecordAccess(sourceRecordId);
    HostedPaymentResult result = HostedPaymentService.create(
      keyValue,
      sourceRecordId
    );
    if (result == null || result.successful != true) {
      logFailure(
        sourceRecordId,
        keyValue,
        'hosted',
        result == null ? 'The payment provider returned no result.' : result.errorSummary,
        result == null ? null : result.httpStatusCode,
        result != null && result.retryable,
        'QuickbridgeCapabilityController.createHostedPayment'
      );
    }
    return result;
  }

  @AuraEnabled
  public static ConnectorExecutionResult executeCarrierOperation(
    String connectorKey,
    String operation,
    Id sourceRecordId,
    String payloadJson
  ) {
    String keyValue = requireReadyConnector(connectorKey, 'carrier.operation');
    assertRecordAccess(sourceRecordId);
    Map<String, Object> payload = safeAttributes(payloadJson);
    payload.put('sourceRecordId', String.valueOf(sourceRecordId));
    CarrierAdapter adapter = ConnectorCapabilityRouter.carrierAdapter(keyValue);
    String operationValue = String.isBlank(operation) ? '' : operation.toLowerCase();
    ConnectorExecutionResult result;
    if (operationValue == 'validateaddress') result = adapter.validateAddress(payload);
    else if (operationValue == 'quoterates') result = adapter.quoteRates(payload);
    else if (operationValue == 'createshipment') result = adapter.createShipment(payload);
    else if (operationValue == 'recoverlabel') result = adapter.recoverLabel(payload);
    else if (operationValue == 'createreturnlabel') result = adapter.createReturnLabel(payload);
    else if (operationValue == 'voidshipment') result = adapter.voidShipment(payload);
    else if (operationValue == 'tracking') result = adapter.synchronizeTracking(payload);
    else throw new AuraHandledException('Unsupported carrier operation.');
    persistCarrierOutcome(sourceRecordId, keyValue, operationValue, result);
    return result;
  }

  private static String requireReadyConnector(String connectorKey, String capability) {
    String keyValue = String.isBlank(connectorKey) ? null : connectorKey.trim().toLowerCase();
    if (String.isBlank(keyValue) || !ConnectorCapabilityRouter.hasCapability(keyValue, capability)) {
      throw new AuraHandledException('The selected connector capability is unavailable.');
    }
    ConnectorReadinessService.Assessment assessment = ConnectorReadinessService.assess(keyValue, true);
    if (!assessment.operationalReady) throw new AuraHandledException('The selected connector is not ready.');
    return keyValue;
  }

  private static String requireCapability(String value) {
    String result = String.isBlank(value) ? null : value.trim().toLowerCase();
    if (!new Set<String>{ 'carrier.operation', 'payment.checkout', 'payment.hosted' }.contains(result)) {
      throw new AuraHandledException('Unsupported connector capability.');
    }
    return result;
  }

  private static void assertRecordAccess(Id recordId) {
    if (recordId == null || !recordId.getSObjectType().getDescribe().isAccessible()) {
      throw new AuraHandledException('The source record is unavailable.');
    }
    List<UserRecordAccess> accessRows = [
      SELECT RecordId, HasReadAccess
      FROM UserRecordAccess
      WHERE UserId = :UserInfo.getUserId() AND RecordId = :recordId
    ];
    if (accessRows.isEmpty() || !accessRows[0].HasReadAccess) {
      throw new AuraHandledException('The source record is unavailable.');
    }
  }

  private static Map<String, Object> safeAttributes(String jsonValue) {
    if (String.isBlank(jsonValue)) return new Map<String, Object>();
    Object parsed;
    try { parsed = JSON.deserializeUntyped(jsonValue); }
    catch (Exception ignored) { throw new AuraHandledException('Request details are invalid.'); }
    if (!(parsed instanceof Map<String, Object>)) {
      throw new AuraHandledException('Request details are invalid.');
    }
    return (Map<String, Object>) parsed;
  }

  private static void persistPaymentOutcome(
    Id recordId,
    String connectorKey,
    String operation,
    PaymentCapabilityResult result
  ) {
    if (result != null && (result.successful || result.requiresAction)) {
      IntegrationOutcomeService.markSuccess(new Set<Id>{ recordId }, connectorKey, operation);
      return;
    }
    IntegrationOutcomeService.markFailure(new Set<Id>{ recordId }, connectorKey, operation);
    logFailure(recordId, connectorKey, operation,
      result == null ? 'The payment provider returned no result.' : result.errorSummary,
      result == null ? null : result.httpStatusCode,
      result != null && result.retryable,
      'QuickbridgeCapabilityController.submitPayment');
  }

  private static void persistCarrierOutcome(
    Id recordId,
    String connectorKey,
    String operation,
    ConnectorExecutionResult result
  ) {
    if (result != null && !result.hasFailures()) {
      IntegrationOutcomeService.markSuccess(new Set<Id>{ recordId }, connectorKey, operation);
      return;
    }
    IntegrationOutcomeService.markFailure(new Set<Id>{ recordId }, connectorKey, operation);
    logFailure(recordId, connectorKey, operation,
      result == null ? 'The carrier returned no result.' : result.errorSummary,
      result == null ? null : result.httpStatusCode,
      result != null && result.retryable,
      'QuickbridgeCapabilityController.executeCarrierOperation');
  }

  private static void logFailure(
    Id recordId,
    String connectorKey,
    String operation,
    String message,
    Integer httpStatusCode,
    Boolean retryable,
    String classMethod
  ) {
    IntegrationErrorLogService.Failure failure = new IntegrationErrorLogService.Failure();
    failure.recordId = recordId;
    failure.connectorKey = connectorKey;
    failure.operationKey = operation;
    failure.category = 'Record Action';
    failure.message = message;
    failure.httpStatusCode = httpStatusCode;
    failure.retryable = retryable;
    failure.retryCount = 0;
    failure.maximumAttempts = 1;
    failure.classMethod = classMethod;
    IntegrationErrorLogService.logFailures(
      new List<IntegrationErrorLogService.Failure>{ failure }
    );
  }
}