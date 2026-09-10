public inherited sharing class HostedPaymentResult {
  @AuraEnabled public Boolean successful { get; set; }
  @AuraEnabled public Boolean retryable { get; set; }
  @AuraEnabled public String providerReference { get; set; }
  @AuraEnabled public String status { get; set; }
  @AuraEnabled public String launchMode { get; set; }
  @AuraEnabled public String hostedUrl { get; set; }
  @AuraEnabled public String formToken { get; set; }
  @AuraEnabled public Datetime expiresAt { get; set; }
  @AuraEnabled public String errorSummary { get; set; }
  @AuraEnabled public Integer httpStatusCode { get; set; }
  @AuraEnabled public Id invoiceRecordId { get; set; }
  @AuraEnabled public Boolean reusedExisting { get; set; }
  public HostedPaymentResult() {
    successful = false;
    retryable = false;
    reusedExisting = false;
  }
}