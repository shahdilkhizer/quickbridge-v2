@RestResource(urlMapping='/quickbridge/webhooks/*')
global without sharing class QuickbridgeWebhookRestResource {
  @HttpPost
  global static void receive() {
    RestRequest request = RestContext.request;
    RestResponse response = RestContext.response;
    String connectorKey = connectorFromUri(request == null ? null : request.requestURI);
    try {
      ConnectorReadinessService.Assessment readiness =
        ConnectorReadinessService.assess(connectorKey, true);
      if (!readiness.operationalReady) {
        respond(response, 503, 'Connector is not ready.');
        return;
      }
      String body = request.requestBody == null
        ? ''
        : request.requestBody.toString();
      if (body.length() > 3000000) {
        respond(response, 413, 'Webhook payload is too large.');
        return;
      }
      ConnectorExecutionResult result =
        ConnectorCapabilityRouter.webhookHandler(connectorKey)
          .handle(body, request.headers);
      if (result == null || result.hasFailures()) {
        respond(response, 401, 'Webhook validation failed.');
        return;
      }
      respond(response, 202, 'Accepted');
    } catch (Exception failure) {
      respond(response, 400, 'Webhook request could not be processed.');
    }
  }

  private static String connectorFromUri(String uri) {
    if (String.isBlank(uri)) return null;
    List<String> parts = uri.split('/');
    String candidate = parts.isEmpty() ? null : parts[parts.size() - 1];
    if (
      String.isBlank(candidate) ||
      !Pattern.matches('^[A-Za-z][A-Za-z0-9_-]{0,79}$', candidate)
    ) return null;
    return candidate.toLowerCase();
  }

  private static void respond(RestResponse response, Integer status, String message) {
    response.statusCode = status;
    response.addHeader('Content-Type', 'application/json');
    response.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
      'status' => message
    }));
  }
}