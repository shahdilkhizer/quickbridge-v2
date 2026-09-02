public inherited sharing class ConnectorExecutionResult {
  private static final Integer MAXIMUM_ERROR_LENGTH = 2000;

  public Integer processedCount { get; set; }
  public Integer successfulCount { get; set; }
  public Integer failedCount { get; set; }
  public String nextCursor { get; set; }
  public Integer retryDelaySeconds { get; set; }
  public Boolean retryable { get; set; }
  public Id asyncJobId { get; set; }
  public String errorSummary { get; set; }
  public Integer httpStatusCode { get; set; }
  public String errorCategory { get; set; }
  public String dmlOperation { get; set; }
  public String classMethod { get; set; }
  public List<Id> retryRecordIds { get; set; }

  public ConnectorExecutionResult() {
    processedCount = 0;
    successfulCount = 0;
    failedCount = 0;
    retryable = false;
    retryRecordIds = new List<Id>();
  }

  public static ConnectorExecutionResult success() {
    return new ConnectorExecutionResult();
  }

  public static ConnectorExecutionResult failed(
    String message,
    Boolean canRetry,
    Integer delaySeconds
  ) {
    ConnectorExecutionResult result = new ConnectorExecutionResult();
    result.processedCount = 1;
    result.failedCount = 1;
    result.retryable = canRetry == true;
    result.retryDelaySeconds = result.retryable
      ? boundedDelay(delaySeconds)
      : null;
    result.addError(message);
    return result;
  }

  public ConnectorExecutionResult addError(String message) {
    String safeMessage = sanitizeError(message);
    if (String.isBlank(safeMessage)) {
      return this;
    }
    String combined = String.isBlank(errorSummary)
      ? safeMessage
      : errorSummary + ' | ' + safeMessage;
    errorSummary = combined.length() <= MAXIMUM_ERROR_LENGTH
      ? combined
      : combined.substring(0, MAXIMUM_ERROR_LENGTH - 3) + '...';
    return this;
  }

  public ConnectorExecutionResult mergeFrom(ConnectorExecutionResult other) {
    if (other == null) {
      return this;
    }
    processedCount =
      safeCount(processedCount) + safeCount(other.processedCount);
    successfulCount =
      safeCount(successfulCount) + safeCount(other.successfulCount);
    failedCount = safeCount(failedCount) + safeCount(other.failedCount);
    if (String.isNotBlank(other.nextCursor)) {
      nextCursor = other.nextCursor;
    }
    if (other.asyncJobId != null) {
      asyncJobId = other.asyncJobId;
    }
    if (other.httpStatusCode != null) httpStatusCode = other.httpStatusCode;
    if (String.isNotBlank(other.errorCategory)) errorCategory = other.errorCategory;
    if (String.isNotBlank(other.dmlOperation)) dmlOperation = other.dmlOperation;
    if (String.isNotBlank(other.classMethod)) classMethod = other.classMethod;
    retryable = retryable == true || other.retryable == true;
    if (other.retryDelaySeconds != null) {
      retryDelaySeconds = retryDelaySeconds == null
        ? boundedDelay(other.retryDelaySeconds)
        : Math.max(retryDelaySeconds, boundedDelay(other.retryDelaySeconds));
    }
    addError(other.errorSummary);
    Set<Id> mergedRetryIds = new Set<Id>(
      retryRecordIds == null ? new List<Id>() : retryRecordIds
    );
    mergedRetryIds.addAll(
      other.retryRecordIds == null ? new List<Id>() : other.retryRecordIds
    );
    retryRecordIds = new List<Id>(mergedRetryIds);
    return this;
  }

  public Boolean hasFailures() {
    return safeCount(failedCount) > 0 || String.isNotBlank(errorSummary);
  }

  private static Integer safeCount(Integer value) {
    return value == null || value < 0 ? 0 : value;
  }

  private static Integer boundedDelay(Integer value) {
    if (value == null) {
      return null;
    }
    return Math.max(0, Math.min(86400, value));
  }

  public static String sanitizeError(String message) {
    if (String.isBlank(message)) {
      return null;
    }
    String result = message.replaceAll('[\\r\\n\\t]+', ' ').trim();
    result = result.replaceAll(
      '(?i)(authorization\\s*[:=]\\s*(?:bearer|basic)\\s+)[^ ,;]+',
      '$1[REDACTED]'
    );
    result = result.replaceAll(
      '(?i)("?(?:access[_-]?token|client[_-]?secret|password|api[_-]?key)"?\\s*[:=]\\s*"?)[^" ,;&}]+',
      '$1[REDACTED]'
    );
    return result;
  }
}