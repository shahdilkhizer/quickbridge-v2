public inherited sharing class PaymentCapabilityResult {
  public Boolean successful { get; set; }
  public Boolean requiresAction { get; set; }
  public Boolean retryable { get; set; }
  public String providerReference { get; set; }
  public String clientActionToken { get; set; }
  public String status { get; set; }
  public String errorSummary { get; set; }
  public Integer httpStatusCode { get; set; }

  public PaymentCapabilityResult() {
    successful = false;
    requiresAction = false;
    retryable = false;
  }
}