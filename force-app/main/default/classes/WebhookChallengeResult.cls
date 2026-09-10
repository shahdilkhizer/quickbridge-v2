public inherited sharing class WebhookChallengeResult {
  public Boolean successful { get; set; }
  public Integer statusCode { get; set; }
  public String responseBody { get; set; }
  public String errorSummary { get; set; }

  public WebhookChallengeResult() {
    successful = false;
    statusCode = 400;
  }

  public static WebhookChallengeResult accepted(String responseValue) {
    WebhookChallengeResult result = new WebhookChallengeResult();
    result.successful = true;
    result.statusCode = 200;
    result.responseBody = responseValue;
    return result;
  }

  public static WebhookChallengeResult rejected(Integer status, String message) {
    WebhookChallengeResult result = new WebhookChallengeResult();
    result.statusCode = status == null ? 400 : status;
    result.errorSummary = ConnectorExecutionResult.sanitizeError(message);
    return result;
  }
}