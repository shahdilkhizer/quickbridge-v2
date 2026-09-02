public inherited sharing class PaymentCapabilityRequest {
  public String connectorKey { get; set; }
  public String operation { get; set; }
  public Id sourceRecordId { get; set; }
  public Decimal amount { get; set; }
  public String currencyCode { get; set; }
  public String providerToken { get; set; }
  public String idempotencyKey { get; set; }
  public Map<String, Object> attributes { get; set; }

  public PaymentCapabilityRequest() {
    attributes = new Map<String, Object>();
  }
}