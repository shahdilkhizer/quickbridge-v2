public inherited sharing class CarrierOperationModels {
  public class Definition {
    @AuraEnabled public String connectorKey;
    @AuraEnabled public String operationKey;
    @AuraEnabled public String label;
    @AuraEnabled public Boolean requiresShipment;
    @AuraEnabled public Boolean requiresIdempotency;
    @AuraEnabled public String requiredRequestPaths;
    @AuraEnabled public String responsePaths;
  }

  public class ShipmentOption {
    @AuraEnabled public Id id;
    @AuraEnabled public String label;
    @AuraEnabled public String trackingNumber;
    @AuraEnabled public String status;
  }

  public class ActionContext {
    @AuraEnabled public List<QuickbridgeCapabilityController.ProviderOption> providers =
      new List<QuickbridgeCapabilityController.ProviderOption>();
    @AuraEnabled public List<Definition> operations = new List<Definition>();
    @AuraEnabled public List<ShipmentOption> shipments = new List<ShipmentOption>();
  }

  public class Request {
    public String connectorKey;
    public String operationKey;
    public Id sourceRecordId;
    public String sourceObjectApiName;
    public Id shipmentId;
    public String idempotencyKey;
    public Map<String, Object> payload = new Map<String, Object>();
  }

  public class Result {
    @AuraEnabled public Boolean success;
    @AuraEnabled public String message;
    @AuraEnabled public String connectorKey;
    @AuraEnabled public String operationKey;
    @AuraEnabled public Id shipmentId;
    @AuraEnabled public Id fileId;
    @AuraEnabled public Id attemptId;
    @AuraEnabled public String trackingNumber;
    @AuraEnabled public Integer httpStatusCode;
    @AuraEnabled public Boolean retryable;
    @AuraEnabled public String errorSummary;
    @AuraEnabled public Map<String, Object> correctedAddress;
    @AuraEnabled public List<RateQuote> rateQuotes = new List<RateQuote>();
    public Map<String, Object> normalized = new Map<String, Object>();

  }

  public class RateQuote {
    @AuraEnabled public Id id;
    @AuraEnabled public String serviceType;
    @AuraEnabled public String serviceName;
    @AuraEnabled public Decimal totalNetCharge;
    @AuraEnabled public String currencyCode;
    @AuraEnabled public String transitTime;
    @AuraEnabled public String deliveryTimestamp;
  }
}