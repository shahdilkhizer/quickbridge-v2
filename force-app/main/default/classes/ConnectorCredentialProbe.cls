public with sharing class ConnectorCredentialProbe {
  public class ProbeResult {
    @AuraEnabled public String connectorKey;
    @AuraEnabled public Boolean successful;
    @AuraEnabled public Integer statusCode;
    @AuraEnabled public String message;
  }

  public static ProbeResult probe(String connectorKey) {
    String normalizedKey = normalize(connectorKey);
    if (!ConnectorCredentialPolicy.supportedConnectorKeys().contains(normalizedKey)) {
      throw new AuraHandledException('Unsupported connector.');
    }
    Connector_Instance__c instanceRecord = ConnectorConfigService.getInstance(
      normalizedKey
    );
    if (instanceRecord == null) {
      throw new AuraHandledException('Connector configuration is missing.');
    }
    ConnectorReadinessService.Evaluation prerequisites =
      ConnectorReadinessService.evaluateForProbe(instanceRecord);
    if (!prerequisites.ready) {
      return result(normalizedKey, false, null, prerequisites.message);
    }

    ConnectorHealthProbeResult healthResult = ConnectorHealthService.probe(
      normalizedKey
    );
    Boolean successful = healthResult != null && healthResult.successful == true;
    ProbeResult probeResult = result(
      normalizedKey,
      successful,
      healthResult == null ? null : healthResult.httpStatusCode,
      successful
        ? 'Credential health probe succeeded.'
        : (healthResult == null ? 'The provider health probe failed.' : healthResult.message)
    );
    return probeResult;
  }

  private static ProbeResult result(
    String connectorKey,
    Boolean successful,
    Integer statusCode,
    String message
  ) {
    ProbeResult resultValue = new ProbeResult();
    resultValue.connectorKey = connectorKey;
    resultValue.successful = successful == true;
    resultValue.statusCode = statusCode;
    resultValue.message = IntegrationErrorLogService.sanitizeForUser(
      String.isBlank(message) ? 'The provider health probe failed.' : message
    ).left(2000);
    return resultValue;
  }

  private static String normalize(String value) {
    return String.isBlank(value)
      ? ''
      : value.trim().toLowerCase().replaceAll('[^a-z0-9]', '');
  }
}