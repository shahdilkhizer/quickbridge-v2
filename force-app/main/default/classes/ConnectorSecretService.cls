public without sharing class ConnectorSecretService {
  public static String getActiveSecret(String connectorKey, String secretKind) {
    String safeConnector = requireToken(connectorKey, 'Connector key');
    String safeKind = requireToken(secretKind, 'Secret kind');
    List<Connector_Secret__c> rows = [
      SELECT Secret_Value__c, Rotation_Due_At__c
      FROM Connector_Secret__c
      WHERE Connector_Key__c = :safeConnector
        AND Secret_Kind__c = :safeKind
        AND Active__c = true
      ORDER BY LastModifiedDate DESC
      LIMIT 1
    ];
    if (rows.isEmpty() || String.isBlank(rows[0].Secret_Value__c)) {
      throw new ConnectorSecretException(
        'Required inbound verification material is not configured.'
      );
    }
    if (
      rows[0].Rotation_Due_At__c != null &&
      rows[0].Rotation_Due_At__c <= System.now()
    ) {
      throw new ConnectorSecretException(
        'Inbound verification material requires rotation.'
      );
    }
    return rows[0].Secret_Value__c;
  }

  public static Boolean hasActiveSecret(String connectorKey, String secretKind) {
    try {
      return String.isNotBlank(getActiveSecret(connectorKey, secretKind));
    } catch (Exception ignored) {
      return false;
    }
  }

  private static String requireToken(String value, String label) {
    String result = String.isBlank(value) ? null : value.trim().toLowerCase();
    if (
      String.isBlank(result) ||
      !Pattern.matches('^[a-z][a-z0-9_-]{0,79}$', result)
    ) {
      throw new ConnectorSecretException(label + ' is invalid.');
    }
    return result;
  }

  public class ConnectorSecretException extends Exception {}
}