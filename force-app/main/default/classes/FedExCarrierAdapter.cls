public without sharing class FedExCarrierAdapter extends RestCarrierAdapter {
  protected override String connectorKey() { return 'fedex'; }
  protected override String defaultEndpoint(String operation) {
    Map<String, String> paths = new Map<String, String>{
      'addressValidation' => '/address/v1/addresses/resolve',
      'rateQuote' => '/rate/v1/rates/quotes',
      'createShipment' => '/ship/v1/shipments',
      'recoverLabel' => '/ship/v1/shipments/tag',
      'createReturn' => '/ship/v1/shipments',
      'voidShipment' => '/ship/v1/shipments/cancel',
      'tracking' => '/track/v1/trackingnumbers'
    };
    return paths.get(operation);
  }
}