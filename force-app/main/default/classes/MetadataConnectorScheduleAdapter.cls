/**
 * Provider-neutral schedule capability that preserves the current job-lease
 * and generic runtime semantics.
 */
public without sharing class MetadataConnectorScheduleAdapter
  implements ScheduledOperationAdapter, ConnectorBoundAdapter {
  private String boundConnectorKey;

  public void bindConnector(String connectorKey) {
    boundConnectorKey = MetadataConnectorAdapterSupport.requireConnectorKey(connectorKey);
  }

  public ConnectorExecutionResult execute(Scheduled_Integration_Job__c job) {
    if (String.isBlank(boundConnectorKey)) {
      return ConnectorExecutionResult.failed(
        'The dynamic schedule adapter is not bound to a connector.',
        false,
        null
      );
    }
    return MetadataScheduledOperationAdapter.executeForConnector(boundConnectorKey, job);
  }
}