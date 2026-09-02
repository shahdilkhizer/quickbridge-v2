public inherited sharing class KlaviyoHealthProbe extends ConfiguredConnectorHealthProbe {
  protected override String connectorKey() { return 'klaviyo'; }
  protected override String defaultEndpoint() { return '/api/accounts/'; }
  protected override String identityPath() { return 'data.id'; }
  protected override String expectedIdentityConfigKey() { return 'accountId'; }
}