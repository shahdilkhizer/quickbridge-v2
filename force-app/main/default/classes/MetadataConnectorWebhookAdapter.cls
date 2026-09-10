/**
 * Metadata-bound webhook adapter. Signature, event identity, work operation,
 * and optional challenge details are configuration values; secret values remain
 * in Connector_Secret__c.
 */
public without sharing class MetadataConnectorWebhookAdapter
  implements WebhookEventHandler, WebhookChallengeHandler, ConnectorBoundAdapter {
  private static final Set<String> SUPPORTED_HMAC_ALGORITHMS =
    new Set<String>{ 'HmacSHA256', 'HmacSHA512' };
  private String boundConnectorKey;

  public void bindConnector(String connectorKey) {
    boundConnectorKey = MetadataConnectorAdapterSupport.requireConnectorKey(connectorKey);
  }

  public ConnectorExecutionResult handle(
    String requestBody,
    Map<String, String> requestHeaders
  ) {
    if (String.isBlank(boundConnectorKey)) {
      return ConnectorExecutionResult.failed(
        'The dynamic webhook adapter is not bound to a connector.',
        false,
        null
      );
    }
    String operationKey = config('webhookOperation');
    String headerName = config('webhookSignatureHeader');
    String algorithm = config('webhookSignatureAlgorithm');
    if (
      String.isBlank(operationKey) ||
      String.isBlank(headerName) ||
      !SUPPORTED_HMAC_ALGORITHMS.contains(algorithm)
    ) {
      return ConnectorExecutionResult.failed(
        'Webhook signature and routing metadata are incomplete.',
        false,
        null
      );
    }
    String secretKind = config('webhookSecretKind');
    if (String.isBlank(secretKind)) secretKind = 'webhookSigningSecret';
    String secret = ConnectorSecretService.getActiveSecret(boundConnectorKey, secretKind);
    if (!WebhookWorkService.verifyHexHmac(
      algorithm,
      requestBody,
      WebhookWorkService.header(requestHeaders, headerName),
      config('webhookSignaturePrefix'),
      secret
    )) {
      return ConnectorExecutionResult.failed(
        'Webhook signature verification failed.',
        false,
        null
      );
    }
    String eventId = WebhookWorkService.jsonString(
      requestBody,
      config('webhookEventIdPath')
    );
    if (String.isBlank(eventId)) {
      eventId = EncodingUtil.convertToHex(
        Crypto.generateDigest('SHA-256', Blob.valueOf(requestBody == null ? '' : requestBody))
      );
    }
    return WebhookWorkService.enqueue(
      boundConnectorKey,
      operationKey,
      eventId,
      requestBody
    );
  }

  public WebhookChallengeResult handleChallenge(
    Map<String, String> queryParameters
  ) {
    String challengeParameter = config('webhookChallengeParameter');
    String verifyParameter = config('webhookVerifyTokenParameter');
    if (String.isBlank(challengeParameter) || String.isBlank(verifyParameter)) {
      return WebhookChallengeResult.rejected(404, 'Webhook challenge is not configured.');
    }
    String suppliedToken = parameter(queryParameters, verifyParameter);
    String secretKind = config('webhookVerifyTokenSecretKind');
    if (String.isBlank(secretKind)) secretKind = 'webhookVerifyToken';
    String expectedToken = ConnectorSecretService.getActiveSecret(
      boundConnectorKey,
      secretKind
    );
    if (
      String.isBlank(suppliedToken) ||
      String.isBlank(expectedToken) ||
      suppliedToken != expectedToken
    ) {
      return WebhookChallengeResult.rejected(401, 'Webhook challenge verification failed.');
    }
    String modeParameter = config('webhookChallengeModeParameter');
    String expectedMode = config('webhookChallengeModeValue');
    if (
      String.isNotBlank(modeParameter) &&
      String.isNotBlank(expectedMode) &&
      parameter(queryParameters, modeParameter) != expectedMode
    ) {
      return WebhookChallengeResult.rejected(400, 'Webhook challenge mode is invalid.');
    }
    String challenge = parameter(queryParameters, challengeParameter);
    return String.isBlank(challenge)
      ? WebhookChallengeResult.rejected(400, 'Webhook challenge is missing.')
      : WebhookChallengeResult.accepted(challenge);
  }

  private String config(String fieldKey) {
    return ConnectorConfigService.getConfigValue(boundConnectorKey, fieldKey);
  }

  private static String parameter(
    Map<String, String> queryParameters,
    String parameterName
  ) {
    if (queryParameters == null || String.isBlank(parameterName)) return null;
    for (String key : queryParameters.keySet()) {
      if (key != null && key.equalsIgnoreCase(parameterName)) {
        return queryParameters.get(key);
      }
    }
    return null;
  }
}