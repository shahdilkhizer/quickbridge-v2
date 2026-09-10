public inherited sharing class ConnectorHealthProbeSupport {
  public static ConnectorHttpClient.RequestSpec request(
    Connector_Instance__c connectorInstance,
    String relativeEndpoint
  ) {
    if (
      connectorInstance == null ||
      String.isBlank(connectorInstance.Named_Credential__c)
    ) {
      throw new ConnectorHealthProbeException(
        'The connector Named Credential is not configured.'
      );
    }
    ConnectorHttpClient.RequestSpec specification =
      new ConnectorHttpClient.RequestSpec();
    specification.namedCredential = connectorInstance.Named_Credential__c;
    specification.relativeEndpoint = relativeEndpoint;
    specification.method = 'GET';
    specification.timeoutMilliseconds = 20000;
    specification.maximumPages = 1;
    specification.pageNumber = 1;
    specification.headers.put('Accept', 'application/json');
    return specification;
  }

  public static ConnectorHealthProbeResult fromResponse(
    ConnectorHttpClient.Response response,
    Boolean identityMatches
  ) {
    if (response == null) {
      return ConnectorHealthProbeResult.failed(
        'Unavailable',
        'The provider returned no health response.',
        null,
        true
      );
    }
    if (response.successful && identityMatches == true) {
      ConnectorHealthProbeResult result = ConnectorHealthProbeResult.ready();
      result.httpStatusCode = response.statusCode;
      return result;
    }
    if (response.successful) {
      return ConnectorHealthProbeResult.failed(
        'Error',
        'The provider identity did not match the connector configuration.',
        response.statusCode,
        false
      );
    }
    String healthStatus = response.statusCode == 401 || response.statusCode == 403
      ? 'Authentication Required'
      : (response.retryable ? 'Warning' : 'Error');
    return ConnectorHealthProbeResult.failed(
      healthStatus,
      response.errorSummary,
      response.statusCode,
      response.retryable
    );
  }

  public static ConnectorHealthProbeResult fromException(Exception failure) {
    String safeMessage = ConnectorExecutionResult.sanitizeError(
      failure == null ? null : failure.getMessage()
    );
    String normalized = String.isBlank(safeMessage)
      ? ''
      : safeMessage.toLowerCase();
    Boolean authenticationFailure =
      normalized.contains('external credential') ||
      normalized.contains('not fully configured') ||
      normalized.contains('authentication') ||
      normalized.contains('unauthorized');
    return ConnectorHealthProbeResult.failed(
      authenticationFailure ? 'Authentication Required' : 'Unavailable',
      String.isBlank(safeMessage)
        ? 'The provider health probe could not be completed.'
        : safeMessage,
      null,
      !authenticationFailure
    );
  }

  public static Object jsonValue(String body, String path) {
    if (String.isBlank(body) || String.isBlank(path)) return null;
    Object current;
    try {
      current = JSON.deserializeUntyped(body);
    } catch (Exception ignored) {
      return null;
    }
    for (String segment : path.split('\\.')) {
      if (current instanceof Map<String, Object>) {
        current = ((Map<String, Object>) current).get(segment);
      } else if (
        current instanceof List<Object> &&
        Pattern.matches('^[0-9]{1,4}$', segment)
      ) {
        Integer index = Integer.valueOf(segment);
        List<Object> values = (List<Object>) current;
        if (index < 0 || index >= values.size()) return null;
        current = values[index];
      } else {
        return null;
      }
    }
    return current;
  }

  public class ConnectorHealthProbeException extends Exception {}
}