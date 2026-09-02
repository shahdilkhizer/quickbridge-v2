public without sharing class MetaIntegrationWorker
  extends MetadataIntegrationWorkHandler {
  protected override String connectorKey() {
    return 'meta';
  }
}