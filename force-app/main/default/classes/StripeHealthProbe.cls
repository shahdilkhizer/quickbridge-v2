public inherited sharing class StripeHealthProbe extends ConfiguredConnectorHealthProbe {
  protected override String connectorKey() { return 'stripe'; }
  protected override String defaultEndpoint() { return '/v1/account'; }
  protected override String identityPath() { return 'id'; }
  protected override String expectedIdentityConfigKey() { return 'accountId'; }
}