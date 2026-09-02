public inherited sharing class ConnectorHttpClient {
  public static final Integer DEFAULT_MAX_PAGES = 50;
  public static final Integer ABSOLUTE_MAX_PAGES = 200;
  public static final Integer DEFAULT_TIMEOUT_MILLISECONDS = 120000;

  private static final Set<String> SUPPORTED_METHODS = new Set<String>{
    'GET',
    'POST',
    'PUT',
    'PATCH',
    'DELETE'
  };
  private static final Set<Integer> RETRYABLE_STATUS_CODES = new Set<Integer>{
    408,
    409,
    425,
    429,
    500,
    502,
    503,
    504
  };

  public class RequestSpec {
    public String namedCredential { get; set; }
    public String relativeEndpoint { get; set; }
    public String approvedBaseUrl { get; set; }
    public String method { get; set; }
    public String body { get; set; }
    public Map<String, String> headers { get; set; }
    public Integer timeoutMilliseconds { get; set; }
    public Integer pageNumber { get; set; }
    public Integer maximumPages { get; set; }

    public RequestSpec() {
      method = 'GET';
      headers = new Map<String, String>();
      timeoutMilliseconds = DEFAULT_TIMEOUT_MILLISECONDS;
      pageNumber = 1;
      maximumPages = DEFAULT_MAX_PAGES;
    }
  }

  public class Response {
    public Integer statusCode { get; private set; }
    public String status { get; private set; }
    public String body { get; private set; }
    public Boolean successful { get; private set; }
    public Boolean retryable { get; private set; }
    public Integer retryAfterSeconds { get; private set; }
    public String errorSummary { get; private set; }

    private HttpResponse rawResponse;

    public String header(String name) {
      return rawResponse == null || String.isBlank(name)
        ? null
        : rawResponse.getHeader(name);
    }
  }

  public interface Transport {
    HttpResponse send(HttpRequest request);
  }

  private class DefaultTransport implements Transport {
    public HttpResponse send(HttpRequest request) {
      return new Http().send(request);
    }
  }

  private class ParsedUrl {
    String authority;
    String pathAndQuery;
    String path;
  }

  @TestVisible
  private static Transport testTransport;

  public static Response send(RequestSpec spec) {
    validateSpec(spec);
    HttpRequest request = new HttpRequest();
    request.setMethod(spec.method.trim().toUpperCase());
    request.setEndpoint(
      toNamedCredentialEndpoint(spec.namedCredential, spec.relativeEndpoint)
    );
    request.setTimeout(spec.timeoutMilliseconds);
    for (String headerName : spec.headers.keySet()) {
      assertSafeHeader(headerName, spec.headers.get(headerName));
      request.setHeader(headerName, spec.headers.get(headerName));
    }
    if (spec.body != null) {
      request.setBody(spec.body);
    }

    HttpResponse httpResponse = (Test.isRunningTest() && testTransport != null
        ? testTransport
        : new DefaultTransport())
      .send(request);
    if (httpResponse == null) {
      throw new ConnectorHttpClientException(
        'The connector returned no HTTP response.'
      );
    }
    return responseFrom(httpResponse);
  }

  public static String toNamedCredentialEndpoint(
    String namedCredential,
    String relativeEndpoint
  ) {
    validateNamedCredential(namedCredential);
    String path = validateRelativeEndpoint(relativeEndpoint);
    return 'callout:' + namedCredential + path;
  }

  public static String toSafeNextEndpoint(
    String namedCredential,
    String approvedBaseUrl,
    String nextUrl
  ) {
    validateNamedCredential(namedCredential);
    ParsedUrl approved = parseApprovedHttpsUrl(
      approvedBaseUrl,
      'Approved API base URL'
    );
    ParsedUrl next = parseApprovedHttpsUrl(nextUrl, 'Pagination URL');
    if (approved.authority != next.authority) {
      throw new ConnectorHttpClientException(
        'Pagination URL changed the approved API host.'
      );
    }
    if (!isApprovedPath(approved.path, next.path)) {
      throw new ConnectorHttpClientException(
        'Pagination URL left the approved API path.'
      );
    }
    return toNamedCredentialEndpoint(namedCredential, next.pathAndQuery);
  }

  public static String safeRelativeNext(
    String approvedBaseUrl,
    String nextUrl
  ) {
    ParsedUrl approved = parseApprovedHttpsUrl(
      approvedBaseUrl,
      'Approved API base URL'
    );
    ParsedUrl next = parseApprovedHttpsUrl(nextUrl, 'Pagination URL');
    if (
      approved.authority != next.authority ||
      !isApprovedPath(approved.path, next.path)
    ) {
      throw new ConnectorHttpClientException(
        'Pagination URL is outside the approved API boundary.'
      );
    }
    return validateRelativeEndpoint(next.pathAndQuery);
  }

  public static String extractLinkNext(String linkHeader) {
    if (String.isBlank(linkHeader)) {
      return null;
    }
    Matcher matcher = Pattern.compile(
        '(?i)<([^>]+)>\\s*;[^,]*rel\\s*=\\s*[\"\']?next[\"\']?'
      )
      .matcher(linkHeader);
    return matcher.find() ? matcher.group(1) : null;
  }

  public static String extractJsonNext(String body, String dottedPath) {
    Object value = jsonValueAtPath(body, dottedPath);
    if (value instanceof String) {
      return String.isBlank((String) value) ? null : (String) value;
    }
    if (value instanceof List<Object>) {
      for (Object item : (List<Object>) value) {
        if (item instanceof String && String.isNotBlank((String) item)) {
          return (String) item;
        }
      }
    }
    return null;
  }

  public static String extractCursor(String body, String dottedPath) {
    Object value = jsonValueAtPath(body, dottedPath);
    return value == null || String.isBlank(String.valueOf(value))
      ? null
      : String.valueOf(value);
  }

  public static Integer nextOffset(
    Integer currentOffset,
    Integer pageSize,
    Integer returnedCount,
    Boolean hasMore
  ) {
    if (
      currentOffset == null ||
      currentOffset < 0 ||
      pageSize == null ||
      pageSize < 1 ||
      returnedCount == null ||
      returnedCount < 0
    ) {
      throw new ConnectorHttpClientException(
        'Offset pagination values are invalid.'
      );
    }
    Boolean anotherPage =
      hasMore == true || (hasMore == null && returnedCount >= pageSize);
    if (!anotherPage || returnedCount == 0) {
      return null;
    }
    return currentOffset + returnedCount;
  }

  public static String appendQuery(
    String relativeEndpoint,
    Map<String, String> parameters
  ) {
    String endpoint = validateRelativeEndpoint(relativeEndpoint);
    if (parameters == null || parameters.isEmpty()) {
      return endpoint;
    }
    List<String> keys = new List<String>(parameters.keySet());
    keys.sort();
    List<String> pairs = new List<String>();
    for (String key : keys) {
      if (
        String.isBlank(key) ||
        !Pattern.matches('^[A-Za-z0-9_.\\[\\]-]+$', key) ||
        parameters.get(key) == null
      ) {
        throw new ConnectorHttpClientException(
          'Query parameter name or value is invalid.'
        );
      }
      pairs.add(urlEncode(key) + '=' + urlEncode(parameters.get(key)));
    }
    if (pairs.isEmpty()) {
      return endpoint;
    }
    return endpoint +
      (endpoint.contains('?') ? '&' : '?') +
      String.join(pairs, '&');
  }

  public static void assertPageWithinLimit(
    Integer pageNumber,
    Integer maximumPages
  ) {
    Integer safeLimit = maximumPages == null ? DEFAULT_MAX_PAGES : maximumPages;
    if (
      safeLimit < 1 ||
      safeLimit > ABSOLUTE_MAX_PAGES ||
      pageNumber == null ||
      pageNumber < 1 ||
      pageNumber > safeLimit
    ) {
      throw new ConnectorHttpClientException(
        'Connector pagination exceeded the safety limit.'
      );
    }
  }

  @TestVisible
  private static void setTestTransport(Transport transport) {
    testTransport = transport;
  }

  @TestVisible
  private static void clearTestTransport() {
    testTransport = null;
  }

  private static void validateSpec(RequestSpec spec) {
    if (spec == null) {
      throw new ConnectorHttpClientException(
        'HTTP request specification is required.'
      );
    }
    validateNamedCredential(spec.namedCredential);
    validateRelativeEndpoint(spec.relativeEndpoint);
    String method = String.isBlank(spec.method)
      ? ''
      : spec.method.trim().toUpperCase();
    if (!SUPPORTED_METHODS.contains(method)) {
      throw new ConnectorHttpClientException('HTTP method is unsupported.');
    }
    if (
      spec.timeoutMilliseconds == null ||
      spec.timeoutMilliseconds < 1 ||
      spec.timeoutMilliseconds > 120000
    ) {
      throw new ConnectorHttpClientException(
        'HTTP timeout is outside the supported range.'
      );
    }
    assertPageWithinLimit(spec.pageNumber, spec.maximumPages);
    if (spec.body != null && spec.body.length() > 3000000) {
      throw new ConnectorHttpClientException(
        'HTTP body exceeds the shared integration size limit.'
      );
    }
    if (spec.headers == null) {
      spec.headers = new Map<String, String>();
    }
  }

  private static Response responseFrom(HttpResponse httpResponse) {
    Response response = new Response();
    response.rawResponse = httpResponse;
    response.statusCode = httpResponse.getStatusCode();
    response.status = httpResponse.getStatus();
    response.body = httpResponse.getBody();
    response.successful =
      response.statusCode >= 200 &&
      response.statusCode < 300;
    response.retryable = RETRYABLE_STATUS_CODES.contains(response.statusCode);
    response.retryAfterSeconds = retryAfterSeconds(
      httpResponse.getHeader('Retry-After')
    );
    if (!response.successful) {
      response.errorSummary = boundedError(
        response.statusCode,
        response.status,
        response.body
      );
    }
    return response;
  }

  private static Integer retryAfterSeconds(String value) {
    if (
      String.isBlank(value) || !Pattern.matches('^[0-9]{1,10}$', value.trim())
    ) {
      return null;
    }
    try {
      return Math.min(86400, Integer.valueOf(value.trim()));
    } catch (Exception ignored) {
      return null;
    }
  }

  private static String boundedError(
    Integer statusCode,
    String status,
    String body
  ) {
    String summary =
      'HTTP ' +
      statusCode +
      (String.isBlank(status) ? '' : ' ' + status);
    if (String.isNotBlank(body)) {
      summary += ': ' + ConnectorExecutionResult.sanitizeError(body);
    }
    return summary.length() <= 2000
      ? summary
      : summary.substring(0, 1997) + '...';
  }

  private static Object jsonValueAtPath(String body, String dottedPath) {
    if (
      String.isBlank(body) ||
      String.isBlank(dottedPath) ||
      !Pattern.matches('^[A-Za-z0-9_-]+(?:\\.[A-Za-z0-9_-]+)*$', dottedPath)
    ) {
      return null;
    }
    Object current;
    try {
      current = JSON.deserializeUntyped(body);
    } catch (Exception exceptionValue) {
      throw new ConnectorHttpClientException(
        'Connector returned malformed JSON.'
      );
    }
    for (String segment : dottedPath.split('\\.')) {
      if (!(current instanceof Map<String, Object>)) {
        return null;
      }
      current = ((Map<String, Object>) current).get(segment);
    }
    return current;
  }

  private static String validateRelativeEndpoint(String relativeEndpoint) {
    String path = String.isBlank(relativeEndpoint)
      ? null
      : relativeEndpoint.trim();
    if (String.isBlank(path)) {
      throw new ConnectorHttpClientException(
        'A relative connector endpoint is required.'
      );
    }
    String lowerPath = path.toLowerCase();
    if (
      lowerPath.startsWith('http://') ||
      lowerPath.startsWith('https://') ||
      lowerPath.startsWith('callout:') ||
      path.startsWith('//') ||
      path.contains('\\') ||
      path.contains('#') ||
      lowerPath.contains('%0d') ||
      lowerPath.contains('%0a') ||
      lowerPath.contains('%2e%2e') ||
      path.contains('/../') ||
      path.endsWith('/..')
    ) {
      throw new ConnectorHttpClientException(
        'Connector endpoint must remain inside the Named Credential boundary.'
      );
    }
    return path.startsWith('/') ? path : '/' + path;
  }

  private static void validateNamedCredential(String namedCredential) {
    if (
      String.isBlank(namedCredential) ||
      !Pattern.matches('^[A-Za-z][A-Za-z0-9_]{0,79}$', namedCredential)
    ) {
      throw new ConnectorHttpClientException(
        'Named Credential identifier is invalid.'
      );
    }
  }

  private static void assertSafeHeader(String name, String value) {
    if (
      String.isBlank(name) ||
      !Pattern.matches('^[A-Za-z0-9-]{1,80}$', name) ||
      name.equalsIgnoreCase('Host') ||
      name.equalsIgnoreCase('Content-Length') ||
      (value != null && (value.contains('\r') || value.contains('\n')))
    ) {
      throw new ConnectorHttpClientException('HTTP header is invalid.');
    }
  }

  private static ParsedUrl parseApprovedHttpsUrl(String value, String label) {
    if (
      String.isBlank(value) ||
      value.contains('#') ||
      value.contains('\\') ||
      value.contains('\r') ||
      value.contains('\n')
    ) {
      throw new ConnectorHttpClientException(label + ' is invalid.');
    }
    Matcher matcher = Pattern.compile('(?i)^https://([^/?#]+)(/[^#]*)?$')
      .matcher(value.trim());
    if (!matcher.matches()) {
      throw new ConnectorHttpClientException(label + ' must be an HTTPS URL.');
    }
    String authority = matcher.group(1).toLowerCase();
    if (authority.contains('@')) {
      throw new ConnectorHttpClientException(
        label + ' cannot contain user information.'
      );
    }
    if (authority.endsWith(':443')) {
      authority = authority.substring(0, authority.length() - 4);
    }
    String pathAndQuery = String.isBlank(matcher.group(2))
      ? '/'
      : matcher.group(2);
    String path = pathAndQuery.contains('?')
      ? pathAndQuery.substring(0, pathAndQuery.indexOf('?'))
      : pathAndQuery;
    ParsedUrl result = new ParsedUrl();
    result.authority = authority;
    result.pathAndQuery = pathAndQuery;
    result.path = path;
    return result;
  }

  private static Boolean isApprovedPath(String approvedPath, String nextPath) {
    String basePath = String.isBlank(approvedPath) ? '/' : approvedPath;
    while (basePath.length() > 1 && basePath.endsWith('/')) {
      basePath = basePath.substring(0, basePath.length() - 1);
    }
    return basePath == '/' ||
      nextPath == basePath ||
      nextPath.startsWith(basePath + '/');
  }

  private static String urlEncode(String value) {
    return EncodingUtil.urlEncode(value, 'UTF-8').replace('+', '%20');
  }

  public class ConnectorHttpClientException extends Exception {
  }
}