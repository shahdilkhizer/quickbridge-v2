public class IntegrationRetryPolicy {
  public static final Integer DEFAULT_MAX_ATTEMPTS = 5;
  private static final Integer BASE_DELAY_SECONDS = 60;
  private static final Integer MAX_DELAY_SECONDS = 3600;
  private static final Set<Integer> PERMANENT_FAILURE_STATUS_CODES = new Set<Integer>{
    400,
    401,
    403,
    404,
    409,
    422
  };

  public class StatusCodeException extends Exception {
    public Integer statusCode;
  }

  public class RetryDecision {
    public Boolean retryable;
    public String reasonCode;
    public Integer httpStatusCode;
    public Integer retryAfterSeconds;
    public String providerCode;

    private RetryDecision(
      Boolean retryable,
      String reasonCode,
      Integer httpStatusCode
    ) {
      this.retryable = retryable;
      this.reasonCode = reasonCode;
      this.httpStatusCode = httpStatusCode;
    }
  }

  private static RetryDecision retry(String reasonCode, Integer statusCode) {
    return new RetryDecision(true, reasonCode, statusCode);
  }

  private static RetryDecision noRetry(String reasonCode, Integer statusCode) {
    return new RetryDecision(false, reasonCode, statusCode);
  }

  public static RetryDecision classify(HttpResponse response) {
    Integer statusCode = response == null ? null : response.getStatusCode();
    if (statusCode == null)
      return noRetry('NULL_RESPONSE', null);
    if (statusCode == 408)
      return retry('REQUEST_TIMEOUT', statusCode);
    if (statusCode == 429)
      return retry('RATE_LIMITED', statusCode);
    if (statusCode == 503)
      return retry('SERVICE_UNAVAILABLE', statusCode);
    if (statusCode >= 500 && statusCode <= 504)
      return retry('SERVER_ERROR', statusCode);
    if (statusCode == 400)
      return noRetry('BAD_REQUEST', statusCode);
    if (statusCode == 401)
      return noRetry('UNAUTHORIZED', statusCode);
    if (statusCode == 403)
      return noRetry('FORBIDDEN', statusCode);
    if (statusCode == 404)
      return noRetry('NOT_FOUND', statusCode);
    if (statusCode == 409)
      return noRetry('CONFLICT', statusCode);
    if (statusCode == 422)
      return noRetry('VALIDATION_ERROR', statusCode);
    if (statusCode >= 200 && statusCode < 300)
      return noRetry('SUCCESS', statusCode);
    return noRetry('UNCLASSIFIED', statusCode);
  }

  public static RetryDecision classify(Integer statusCode) {
    HttpResponse r = new HttpResponse();
    if (statusCode != null)
      r.setStatusCode(statusCode);
    return statusCode == null ? noRetry('NO_STATUS_CODE', null) : classify(r);
  }

  public static RetryDecision classify(Exception e) {
    if (e == null)
      return noRetry('NO_EXCEPTION', null);
    if (e instanceof StatusCodeException) {
      return classify(((StatusCodeException) e).statusCode);
    }
    Integer statusCode = httpStatusCodeFromMessage(e.getMessage());
    if (statusCode != null)
      return classify(statusCode);
    if (isRetryableMessage(e.getMessage()))
      return retry('TRANSIENT_PLATFORM_OR_NETWORK_FAILURE', null);
    return noRetry('UNSTRUCTURED_EXCEPTION', null);
  }

  public static Integer getMaxAttempts(Integration_Work_Item__c item) {
    if (
      item != null &&
      item.Max_Attempts__c != null &&
      item.Max_Attempts__c > 0
    ) {
      return Integer.valueOf(item.Max_Attempts__c);
    }
    return DEFAULT_MAX_ATTEMPTS;
  }

  public static Datetime nextAttemptAt(Integer attemptCount) {
    Integer exponent = Math.max(
      0,
      Math.min(6, attemptCount == null ? 0 : attemptCount)
    );
    Integer multiplier = 1;
    for (Integer i = 0; i < exponent; i++) {
      multiplier *= 2;
    }
    Integer delay = BASE_DELAY_SECONDS * multiplier;
    if (delay > MAX_DELAY_SECONDS) {
      delay = MAX_DELAY_SECONDS;
    }
    return System.now().addSeconds(delay);
  }

  public static Boolean isRetryable(Exception e) {
    if (e == null || String.isBlank(e.getMessage())) {
      return false;
    }
    if (e instanceof StatusCodeException) {
      return isRetryable(((StatusCodeException) e).statusCode);
    }
    Integer httpStatusCode = httpStatusCodeFromMessage(e.getMessage());
    if (httpStatusCode != null) {
      return isRetryable(httpStatusCode);
    }
    return false;
  }

  public static StatusCodeException exceptionForStatus(
    Integer httpStatusCode,
    String message
  ) {
    StatusCodeException ex = new StatusCodeException(message);
    ex.statusCode = httpStatusCode;
    return ex;
  }

  public static Boolean isRetryable(HttpResponse response) {
    return response != null && isRetryable(response.getStatusCode());
  }

  public static Boolean isRetryable(Integer httpStatusCode) {
    if (httpStatusCode == null) {
      return false;
    }
    if (isPermanentFailure(httpStatusCode)) {
      return false;
    }
    return httpStatusCode == 408 ||
      httpStatusCode == 429 ||
      httpStatusCode == 503 ||
      (httpStatusCode >= 500 &&
      httpStatusCode <= 504);
  }

  public static Boolean isRateLimited(Integer httpStatusCode) {
    return httpStatusCode == 429;
  }

  public static Boolean isPermanentFailure(Integer httpStatusCode) {
    return httpStatusCode != null &&
      PERMANENT_FAILURE_STATUS_CODES.contains(httpStatusCode);
  }

  public static Boolean isRetryableMessage(String message) {
    if (String.isBlank(message)) {
      return false;
    }
    String lower = message.toLowerCase();
    return lower.contains('unable_to_lock_row') ||
      lower.contains('unable to obtain exclusive access') ||
      lower.contains('row lock') ||
      lower.contains('timeout') ||
      lower.contains('timed out') ||
      lower.contains('temporarily unavailable') ||
      lower.contains('read timed out');
  }

  public static Integer httpStatusCodeFromMessage(String message) {
    if (String.isBlank(message)) {
      return null;
    }
    Matcher matcher = Pattern.compile(
        '(?i)(?:http|status|status code)\\s*[:=]?\\s*(\\d{3})'
      )
      .matcher(message);
    if (!matcher.find()) {
      return null;
    }
    try {
      return Integer.valueOf(matcher.group(1));
    } catch (Exception ignored) {
      return null;
    }
  }
}