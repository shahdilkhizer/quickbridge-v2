public inherited sharing class MetaHealthProbe extends ConfiguredConnectorHealthProbe {
  protected override String connectorKey() { return 'meta'; }
  protected override String defaultEndpoint() { return '/me?fields=id,name'; }
  protected override String identityPath() { return 'id'; }
  protected override String expectedIdentityConfigKey() { return 'businessAccountId'; }
}