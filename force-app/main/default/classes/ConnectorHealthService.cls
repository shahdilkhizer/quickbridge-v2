public inherited sharing class ConnectorHealthService {
  public static ConnectorHealthProbeResult probe(String connectorKey) {
    Connector_Instance__c instanceRecord = ConnectorConfigService.getInstance(
      connectorKey
    );
    if (instanceRecord == null) {
      throw new ConnectorHealthException('Connector instance is missing.');
    }
    ConnectorHealthProbeResult result;
    try {
      result = ConnectorCapabilityRouter.healthProbe(connectorKey).probe(
        instanceRecord
      );
    } catch (Exception failure) {
      result = ConnectorHealthProbeSupport.fromException(failure);
    }
    persist(instanceRecord, result);
    return result;
  }

  private static void persist(
    Connector_Instance__c instanceRecord,
    ConnectorHealthProbeResult result
  ) {
    instanceRecord.Health_Status__c = String.isBlank(result.status)
      ? 'Unavailable'
      : result.status.left(60);
    instanceRecord.Last_Health_Check_At__c = System.now();
    if (result.successful != true) {
      instanceRecord.Active__c = false;
    }
    Database.SaveResult saveResult = Database.update(instanceRecord, false);
    if (!saveResult.isSuccess()) {
      throw new ConnectorHealthException(
        'Connector health status could not be saved.'
      );
    }
    if (result.successful != true) {
      logFailure(instanceRecord, result);
    }
  }

  private static void logFailure(
    Connector_Instance__c instanceRecord,
    ConnectorHealthProbeResult result
  ) {
    IntegrationErrorLogService.Failure failure =
      new IntegrationErrorLogService.Failure();
    failure.recordId = instanceRecord.Id;
    failure.connectorKey = instanceRecord.Connector_Key__c;
    failure.operationKey = 'CredentialProbe';
    failure.category = result.httpStatusCode == 401 || result.httpStatusCode == 403
      ? 'Authentication'
      : 'Readiness';
    failure.message = result.message;
    failure.httpStatusCode = result.httpStatusCode;
    failure.retryable = result.retryable;
    failure.retryCount = 0;
    failure.maximumAttempts = 0;
    failure.classMethod = 'ConnectorHealthService.probe';
    IntegrationErrorLogService.logFailures(
      new List<IntegrationErrorLogService.Failure>{ failure }
    );
  }

  public class ConnectorHealthException extends Exception {}
}