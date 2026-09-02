public interface WebhookEventHandler {
  ConnectorExecutionResult handle(
    String requestBody,
    Map<String, String> requestHeaders
  );
}