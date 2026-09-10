/** Transport-only lifecycle operations for deleted records, whose source row no longer exists. */
public inherited sharing class GenericResourceLifecycle {
  public static ConnectorExecutionResult replay(GenericIntegrationRuntime.OperationDefinition definition, String externalId) {
    GenericResourceContract contract = GenericResourceContract.parse(definition.resourceContractJson);
    GenericResourceContract.require(contract != null && String.isNotBlank(externalId), 'Replay requires a resource contract and external identity.');
    ConnectorHttpClient.RequestSpec spec = new ConnectorHttpClient.RequestSpec();
    spec.namedCredential = definition.namedCredential;
    spec.approvedBaseUrl = definition.approvedBaseUrl;
    spec.relativeEndpoint = contract.endpoint(definition, externalId);
    spec.method = 'GET';
    ConnectorHttpClient.Response response = ConnectorHttpClient.send(spec);
    if (!response.successful) return ConnectorExecutionResult.failed(response.errorSummary,
      GenericIntegrationRuntime.isRetryable(definition, response.statusCode), GenericIntegrationRuntime.retryDelaySeconds(definition, response));
    definition.responseCollectionPath = contract.envelope;
    ConnectorExecutionResult result=GenericInboundResourcePersistence.persist(definition, response.body, false);
    if (!result.hasFailures()) IntegrationErrorLogService.markExternalResolved(definition.connectorKey,definition.operationKey,externalId);
    return result;
  }
  public static ConnectorExecutionResult deleteResource(GenericIntegrationRuntime.OperationDefinition definition, String externalId) {
    GenericResourceContract contract = GenericResourceContract.parse(definition.resourceContractJson);
    GenericResourceContract.require(contract != null && contract.deleteEnabled == true, 'Delete propagation is unsupported for this operation.');
    if (String.isBlank(externalId)) return ConnectorExecutionResult.success();
    ConnectorHttpClient.RequestSpec spec = new ConnectorHttpClient.RequestSpec();
    spec.namedCredential = definition.namedCredential;
    spec.approvedBaseUrl = definition.approvedBaseUrl;
    spec.relativeEndpoint = contract.endpoint(definition, externalId);
    spec.method = 'DELETE';
    spec.timeoutMilliseconds = definition.timeoutMilliseconds;
    ConnectorHttpClient.Response response = ConnectorHttpClient.send(spec);
    if (response.successful || response.statusCode == 404) return ConnectorExecutionResult.success();
    return ConnectorExecutionResult.failed(response.errorSummary,
      GenericIntegrationRuntime.isRetryable(definition, response.statusCode),
      GenericIntegrationRuntime.retryDelaySeconds(definition, response));
  }
}