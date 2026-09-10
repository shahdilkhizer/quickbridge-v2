/**
 * Optional extension for providers that issue an inbound webhook challenge.
 */
public interface WebhookChallengeHandler {
  WebhookChallengeResult handleChallenge(Map<String, String> queryParameters);
}