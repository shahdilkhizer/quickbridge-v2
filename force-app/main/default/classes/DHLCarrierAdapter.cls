public without sharing class DHLCarrierAdapter extends RestCarrierAdapter {
  protected override String connectorKey() { return 'dhl'; }
  protected override String defaultEndpoint(String operation) {
    Map<String, String> paths = new Map<String, String>{
      'addressValidation' => '/address-validate',
      'rateQuote' => '/rates',
      'createShipment' => '/shipments',
      'recoverLabel' => '/shipments/labels',
      'createReturn' => '/shipments',
      'voidShipment' => '/shipments/cancel',
      'tracking' => '/shipments/tracking'
    };
    return paths.get(operation);
  }
}