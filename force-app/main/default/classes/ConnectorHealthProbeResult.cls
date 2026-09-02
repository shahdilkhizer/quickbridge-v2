public inherited sharing class ConnectorHealthProbeResult {
  public Boolean successful { get; set; }
  public String status { get; set; }
  public String message { get; set; }
  public Integer httpStatusCode { get; set; }
  public Boolean retryable { get; set; }

  public ConnectorHealthProbeResult() {
    successful = false;
    status = 'Unavailable';
    retryable = false;
  }

  public static ConnectorHealthProbeResult ready() {
    ConnectorHealthProbeResult result = new ConnectorHealthProbeResult();
    result.successful = true;
    result.status = 'Ready';
    return result;
  }

  public static ConnectorHealthProbeResult failed(
    String statusValue,
    String messageValue,
    Integer responseCode,
    Boolean canRetry
  ) {
    ConnectorHealthProbeResult result = new ConnectorHealthProbeResult();
    result.status = String.isBlank(statusValue) ? 'Unavailable' : statusValue;
    result.message = ConnectorExecutionResult.sanitizeError(messageValue);
    result.httpStatusCode = responseCode;
    result.retryable = canRetry == true;
    return result;
  }
}