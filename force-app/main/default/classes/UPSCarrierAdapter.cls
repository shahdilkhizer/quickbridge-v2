public without sharing class UPSCarrierAdapter extends RestCarrierAdapter {
  protected override String connectorKey() { return 'ups'; }
  protected override String defaultEndpoint(String operation) {
    Map<String, String> paths = new Map<String, String>{
      'addressValidation' => '/api/addressvalidation/v2/3',
      'rateQuote' => '/api/rating/v2409/Rate',
      'createShipment' => '/api/shipments/v2409/ship',
      'recoverLabel' => '/api/labels/v2409/recovery',
      'createReturn' => '/api/shipments/v2409/ship',
      'voidShipment' => '/api/shipments/v2409/void/cancel',
      'tracking' => '/api/track/v1/details'
    };
    return paths.get(operation);
  }
}