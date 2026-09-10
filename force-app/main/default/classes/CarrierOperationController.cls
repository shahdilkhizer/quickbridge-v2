public with sharing class CarrierOperationController {
  @AuraEnabled(cacheable=true)
  public static CarrierOperationModels.ActionContext getActionContext(Id sourceRecordId) {
    return CarrierOperationService.getActionContext(sourceRecordId);
  }

  @AuraEnabled
  public static Id prepareMutation(
    String connectorKey, String operationKey, Id sourceRecordId, Id shipmentId
  ) {
    return CarrierOperationService.prepareMutation(connectorKey, operationKey, sourceRecordId, shipmentId);
  }

  @AuraEnabled
  public static CarrierOperationModels.Result execute(
    String connectorKey, String operationKey, Id sourceRecordId, Id shipmentId, Id attemptId
  ) {
    return CarrierOperationService.execute(connectorKey, operationKey, sourceRecordId, shipmentId, attemptId);
  }

  @AuraEnabled
  public static CarrierOperationModels.Result applyValidatedAddress(
    String connectorKey, Id sourceRecordId, String addressJson
  ) {
    return CarrierOperationService.applyValidatedAddress(
      connectorKey, sourceRecordId, parseMap(addressJson)
    );
  }

  @AuraEnabled
  public static CarrierOperationModels.Result selectRateQuote(Id rateQuoteId, Id sourceRecordId) {
    return CarrierOperationService.selectRateQuote(rateQuoteId, sourceRecordId);
  }

  private static Map<String, Object> parseMap(String jsonValue) {
    if (String.isBlank(jsonValue)) throw handled('Address confirmation is missing.');
    try {
      Object parsed = JSON.deserializeUntyped(jsonValue);
      if (parsed instanceof Map<String, Object>) return (Map<String, Object>) parsed;
    } catch (Exception ignored) { }
    throw handled('Address confirmation is invalid.');
  }

  private static AuraHandledException handled(String message) {
    AuraHandledException error = new AuraHandledException(message);
    error.setMessage(message);
    return error;
  }
}