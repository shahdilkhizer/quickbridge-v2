/**
 * Generic checkout adapter. Endpoint, content type and response paths are
 * metadata/configuration values; payment request validation remains in the
 * established shared payment base class.
 */
public without sharing class MetadataConnectorPaymentAdapter
  extends RestPaymentProviderAdapter implements ConnectorBoundAdapter {
  private String boundConnectorKey;

  public void bindConnector(String connectorKey) {
    boundConnectorKey = MetadataConnectorAdapterSupport.requireConnectorKey(connectorKey);
  }

  protected override String connectorKey() {
    return boundConnectorKey;
  }

  protected override String endpoint(
    String operation,
    PaymentCapabilityRequest request
  ) {
    String configured = ConnectorConfigService.getConfigValue(
      boundConnectorKey,
      operation + 'Path'
    );
    if (String.isBlank(configured)) {
      throw new MetadataConnectorPaymentException(
        'The payment operation endpoint is not configured.'
      );
    }
    String providerToken = request == null ? null : request.providerToken;
    return configured.replace(
      '{providerToken}',
      String.isBlank(providerToken)
        ? ''
        : EncodingUtil.urlEncode(providerToken, 'UTF-8')
    );
  }

  protected override String body(
    String operation,
    PaymentCapabilityRequest request
  ) {
    return JSON.serialize(new Map<String, Object>{
      'operation' => operation,
      'sourceRecordId' => request.sourceRecordId,
      'amount' => request.amount,
      'currencyCode' => request.currencyCode,
      'providerToken' => request.providerToken,
      'idempotencyKey' => request.idempotencyKey,
      'attributes' => request.attributes
    });
  }

  protected override String contentType() {
    String value = ConnectorConfigService.getConfigValue(
      boundConnectorKey,
      'paymentContentType'
    );
    return String.isBlank(value) ? 'application/json' : value;
  }

  protected override String referencePath() {
    return responsePath('paymentReferencePath', 'id');
  }

  protected override String statusPath() {
    return responsePath('paymentStatusPath', 'status');
  }

  protected override String actionTokenPath() {
    return responsePath('paymentActionTokenPath', 'client_secret');
  }

  private String responsePath(String fieldKey, String defaultValue) {
    String value = ConnectorConfigService.getConfigValue(boundConnectorKey, fieldKey);
    return String.isBlank(value) ? defaultValue : value;
  }

  public class MetadataConnectorPaymentException extends Exception {}
}