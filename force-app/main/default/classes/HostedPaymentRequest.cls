public inherited sharing class HostedPaymentRequest {
  public String connectorKey { get; set; }
  public Id sourceRecordId { get; set; }
  public Decimal amount { get; set; }
  public String currencyCode { get; set; }
  public String referenceNumber { get; set; }
  public String customerEmail { get; set; }
  public String customerName { get; set; }
  public String description { get; set; }
  public Date dueDate { get; set; }
  public String idempotencyKey { get; set; }
}