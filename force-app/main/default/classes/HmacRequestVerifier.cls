/**
 * Reusable HMAC request verifier for inbound REST endpoints.
 *
 * Mirrors the proven Stripe-webhook verification in PaymentWebhookRestResource:
 * HmacSHA256 over "timestamp.body", hex-encoded, case-insensitive compare, with a
 * timestamp tolerance window to limit replay. Returns a structured Result carrying
 * the HTTP status code and a generic, safe message.
 */
public with sharing class HmacRequestVerifier {
  public static final Integer DEFAULT_TOLERANCE_SECONDS = 300;

  public class Result {
    public Boolean ok;
    public Integer statusCode;
    public String message;
    public Result(Boolean ok, Integer statusCode, String message) {
      this.ok = ok;
      this.statusCode = statusCode;
      this.message = message;
    }
  }

  /**
   * Verifies a request signature.
   * @param body            raw request body (exact bytes the sender signed)
   * @param signatureHeader hex-encoded HmacSHA256 signature supplied by the caller
   * @param timestampHeader unix-epoch-seconds timestamp supplied by the caller
   * @param secret          shared signing secret
   * @param toleranceSeconds max allowed clock skew (defaults applied if null/<=0)
   */
  public static Result verify(
    String body,
    String signatureHeader,
    String timestampHeader,
    String secret,
    Integer toleranceSeconds
  ) {
    if (String.isBlank(secret)) {
      // Misconfiguration, not a client error.
      return new Result(false, 503, 'Request signing secret is not configured.');
    }
    if (String.isBlank(signatureHeader) || String.isBlank(timestampHeader)) {
      return new Result(false, 401, 'Request signature or timestamp is missing.');
    }

    Long timestampSeconds;
    try {
      timestampSeconds = Long.valueOf(timestampHeader.trim());
    } catch (Exception e) {
      return new Result(false, 401, 'Request timestamp is invalid.');
    }

    Integer tolerance = (toleranceSeconds == null || toleranceSeconds <= 0)
      ? DEFAULT_TOLERANCE_SECONDS
      : toleranceSeconds;
    Long nowSeconds = Datetime.now().getTime() / 1000;
    if (Math.abs(nowSeconds - timestampSeconds) > tolerance) {
      return new Result(false, 401, 'Request timestamp is outside the allowed tolerance.');
    }

    String expected = computeSignature(timestampHeader.trim(), body, secret);
    String provided = signatureHeader.trim().toLowerCase();
    if (!isHexValue(provided) || provided != expected) {
      return new Result(false, 401, 'Request signature verification failed.');
    }
    return new Result(true, 200, null);
  }

  /**
   * Computes the canonical hex HmacSHA256 of "timestamp.body" with the secret.
   * Exposed so senders/tests can produce a matching signature.
   */
  public static String computeSignature(String timestamp, String body, String secret) {
    String signedPayload = timestamp + '.' + (body == null ? '' : body);
    return EncodingUtil.convertToHex(
        Crypto.generateMac(
          'HmacSHA256',
          Blob.valueOf(signedPayload),
          Blob.valueOf(secret)
        )
      )
      .toLowerCase();
  }

  /** Case-insensitive header lookup (REST header keys vary in casing). */
  public static String getHeaderValue(RestRequest request, String headerName) {
    if (request == null || String.isBlank(headerName) || request.headers == null) {
      return null;
    }
    if (request.headers.containsKey(headerName)) {
      return request.headers.get(headerName);
    }
    for (String key : request.headers.keySet()) {
      if (key != null && key.equalsIgnoreCase(headerName)) {
        return request.headers.get(key);
      }
    }
    return null;
  }

  public static Boolean isHexValue(String value) {
    return String.isNotBlank(value) && Pattern.matches('(?i)^[0-9a-f]+$', value);
  }
}