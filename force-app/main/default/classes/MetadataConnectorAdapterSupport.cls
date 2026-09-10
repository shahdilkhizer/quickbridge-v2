/**
 * Small shared guard for metadata-bound adapters. It deliberately accepts only
 * connector keys, never endpoint or credential values.
 */
public inherited sharing class MetadataConnectorAdapterSupport {
  public static String requireConnectorKey(String connectorKey) {
    if (
      String.isBlank(connectorKey) ||
      !Pattern.matches('^[A-Za-z][A-Za-z0-9_-]{0,79}$', connectorKey.trim())
    ) {
      throw new MetadataConnectorAdapterException('Connector key is invalid.');
    }
    return connectorKey.trim().toLowerCase();
  }

  public static Boolean matches(String left, String right) {
    return String.isNotBlank(left) &&
      String.isNotBlank(right) &&
      left.trim().equalsIgnoreCase(right.trim());
  }

  public class MetadataConnectorAdapterException extends Exception {}
}