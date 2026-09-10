public inherited sharing class CarrierOperationAdapterFactory {
  private static final Set<String> ALLOWED_CONNECTORS = new Set<String>{ 'fedex', 'ups', 'dhl' };

  public static CarrierOperationAdapter forConnector(String connectorKey) {
    String key = CarrierOperationCatalog.normalize(connectorKey);
    if (!ALLOWED_CONNECTORS.contains(key)) {
      throw new CarrierOperationAdapterException('Unsupported carrier connector.');
    }
    return new CarrierOperationHttpAdapter(key);
  }

  private class CarrierOperationHttpAdapter implements CarrierOperationAdapter {
    private String connectorKey;
    CarrierOperationHttpAdapter(String connectorKey) { this.connectorKey = connectorKey; }

    public CarrierOperationModels.Result execute(CarrierOperationModels.Request request) {
      CarrierOperationModels.Result result = new CarrierOperationModels.Result();
      result.connectorKey = connectorKey;
      result.operationKey = CarrierOperationCatalog.normalize(request.operationKey);
      try {
        rejectSecrets(request.payload);
        ConnectorHttpClient.RequestSpec spec = new ConnectorHttpClient.RequestSpec();
        spec.namedCredential = ConnectorConfigService.namedCredentialFor(connectorKey);
        spec.relativeEndpoint = endpointFor(result.operationKey);
        spec.method = methodFor(result.operationKey);
        spec.headers.put('Accept', 'application/json');
        spec.headers.put('Content-Type', 'application/json');
        if (String.isNotBlank(request.idempotencyKey)) {
          spec.headers.put('Idempotency-Key', request.idempotencyKey.left(255));
        }
        spec.body = JSON.serialize(shapePayload(request.payload));
        ConnectorHttpClient.Response response = ConnectorHttpClient.send(spec);
        result.httpStatusCode = response.statusCode;
        result.retryable = response.retryable;
        if (!response.successful) {
          result.success = false;
          result.errorSummary = ConnectorExecutionResult.sanitizeError(response.errorSummary);
          result.message = result.errorSummary;
          return result;
        }
        result.success = true;
        result.message = 'Carrier action completed successfully.';
        result.normalized.put('rawResponse', response.body);
        Map<String, Object> body = asMap(response.body);
        normalize(result, body);
        return result;
      } catch (CarrierOperationAdapterException error) {
        result.success = false;
        result.retryable = false;
        result.errorSummary = ConnectorExecutionResult.sanitizeError(error.getMessage());
        result.message = result.errorSummary;
        return result;
      } catch (Exception error) {
        result.success = false;
        result.retryable = true;
        result.errorSummary = ConnectorExecutionResult.sanitizeError(error.getMessage());
        result.message = result.errorSummary;
        return result;
      }
    }

    private Map<String, Object> shapePayload(Map<String, Object> input) {
      Map<String, Object> payload = input == null
        ? new Map<String, Object>()
        : (Map<String, Object>) JSON.deserializeUntyped(JSON.serialize(input));
      String accountNumber = ConnectorConfigService.getConfigValue(connectorKey, 'accountNumber');
      if (String.isNotBlank(accountNumber)) {
        if (connectorKey == 'fedex') putPath(payload, 'accountNumber.value', accountNumber);
        else if (connectorKey == 'ups') putPath(payload, 'Shipment.Shipper.ShipperNumber', accountNumber);
        else putPath(payload, 'accounts.shipperNumber', accountNumber);
      }
      return payload;
    }

    private String endpointFor(String operation) {
      Map<String, Map<String, String>> profiles = new Map<String, Map<String, String>>{
        'fedex' => new Map<String, String>{ 'validateaddress'=>'/address/v1/addresses/resolve','quoterates'=>'/rate/v1/rates/quotes','createshipment'=>'/ship/v1/shipments','recoverlabel'=>'/ship/v1/shipments/tag','createreturnlabel'=>'/ship/v1/shipments','voidshipment'=>'/ship/v1/shipments/cancel','synctrackingstatus'=>'/track/v1/trackingnumbers' },
        'ups' => new Map<String, String>{ 'validateaddress'=>'/api/addressvalidation/v2/3','quoterates'=>'/api/rating/v2409/Rate','createshipment'=>'/api/shipments/v2409/ship','recoverlabel'=>'/api/labels/v2409/recovery','createreturnlabel'=>'/api/shipments/v2409/ship','voidshipment'=>'/api/shipments/v2409/void/cancel','synctrackingstatus'=>'/api/track/v1/details' },
        'dhl' => new Map<String, String>{ 'validateaddress'=>'/address-validate','quoterates'=>'/rates','createshipment'=>'/shipments','recoverlabel'=>'/shipments/labels','createreturnlabel'=>'/shipments','voidshipment'=>'/shipments/cancel','synctrackingstatus'=>'/shipments/tracking' }
      };
      String endpoint = profiles.get(connectorKey).get(operation);
      if (String.isBlank(endpoint)) throw new CarrierOperationAdapterException('Unsupported carrier operation.');
      return endpoint;
    }

    private String methodFor(String operation) {
      return operation == 'recoverlabel' && connectorKey == 'dhl' ? 'GET' : 'POST';
    }

    private void normalize(CarrierOperationModels.Result result, Map<String, Object> body) {
      String tracking = firstString(body, new List<String>{
        'shipment.masterTrackingNumber','shipmentTrackingNumber','output.transactionShipments.0.masterTrackingNumber','ShipmentResponse.ShipmentResults.PackageResults.0.TrackingNumber','tracking.trackingNumber','trackingNumber','output.completeTrackResults.0.trackResults.0.trackingNumberInfo.trackingNumber','trackResponse.shipment.0.package.0.trackingNumber','shipments.0.id'
      });
      String externalId = firstString(body, new List<String>{ 'shipment.externalShipmentId','shipment.id','transactionId','output.transactionShipments.0.shipDatestamp','ShipmentResponse.Response.ResponseStatus.Code' });
      String status = firstString(body, new List<String>{ 'tracking.latestStatus','status','output.completeTrackResults.0.trackResults.0.latestStatusDetail.description','trackResponse.shipment.0.status','shipments.0.status.statusCode' });
      putPath(result.normalized, 'shipment.masterTrackingNumber', tracking);
      putPath(result.normalized, 'shipment.externalShipmentId', externalId);
      putPath(result.normalized, 'tracking.trackingNumber', tracking);
      putPath(result.normalized, 'tracking.latestStatus', status);
      List<Object> events = firstList(body, new List<String>{
        'tracking.events','output.completeTrackResults.0.trackResults.0.scanEvents',
        'trackResponse.shipment.0.package.0.activity','shipments.0.events'
      });
      if (events != null) putPath(result.normalized, 'tracking.events', events);
      if (result.operationKey == 'validateaddress') {
        Map<String, Object> address = firstMap(body, new List<String>{ 'validatedAddress','output.resolvedAddresses.0','addressValidationResults.0.address','candidate.0.address' });
        if (address != null) {
          result.correctedAddress = address;
          result.normalized.put('validatedAddress', address);
        }
      }
      if (result.operationKey == 'quoterates') {
        List<Object> rates = firstList(body, new List<String>{ 'rates','output.rateReplyDetails','RateResponse.RatedShipment','products' });
        if (rates != null) result.normalized.put('rates', rates);
      }
      String content = firstString(body, new List<String>{ 'label.content','labelContent','documents.0.content','output.transactionShipments.0.pieceResponses.0.packageDocuments.0.encodedLabel','ShipmentResponse.ShipmentResults.PackageResults.0.ShippingLabel.GraphicImage' });
      if (String.isNotBlank(content)) {
        putPath(result.normalized, 'label.content', content);
        putPath(result.normalized, 'label.fileName', connectorKey + '-' + (String.isBlank(tracking) ? 'label' : tracking) + '.pdf');
      }
    }
  }

  private static void rejectSecrets(Map<String, Object> payload) {
    if (payload == null) return;
      for (String key : payload.keySet()) {
        String normalized = key == null ? '' : key.toLowerCase().replaceAll('[^a-z0-9]', '');
        if (new Set<String>{ 'password','secret','token','authorization','apikey','clientsecret' }.contains(normalized)) {
          throw new CarrierOperationAdapterException('Credentials must be supplied by the External Credential.');
        }
        Object value = payload.get(key);
        if (value instanceof Map<String, Object>) rejectSecrets((Map<String, Object>) value);
        if (value instanceof List<Object>) {
          for (Object item : (List<Object>) value) {
            if (item instanceof Map<String, Object>) rejectSecrets((Map<String, Object>) item);
          }
        }
      }
  }

  private static Map<String, Object> asMap(String body) {
    if (String.isBlank(body)) return new Map<String, Object>();
    try {
      Object parsed = JSON.deserializeUntyped(body);
      if (parsed instanceof Map<String, Object>) return (Map<String, Object>) parsed;
    } catch (Exception ignored) { }
    throw new CarrierOperationAdapterException('Carrier response was malformed.');
  }

  private static Object pathValue(Object value, String path) {
    Object cursor = value;
    for (String part : path.split('\\.')) {
      if (cursor instanceof Map<String, Object>) cursor = ((Map<String, Object>) cursor).get(part);
      else if (cursor instanceof List<Object> && Pattern.matches('^[0-9]+$', part)) {
        Integer index = Integer.valueOf(part);
        List<Object> rows = (List<Object>) cursor;
        cursor = index < rows.size() ? rows[index] : null;
      } else return null;
      if (cursor == null) return null;
    }
    return cursor;
  }

  private static String firstString(Map<String, Object> data, List<String> paths) {
    for (String path : paths) { Object value = pathValue(data, path); if (value != null && String.isNotBlank(String.valueOf(value))) return String.valueOf(value); }
    return null;
  }
  private static Map<String, Object> firstMap(Map<String, Object> data, List<String> paths) {
    for (String path : paths) { Object value = pathValue(data, path); if (value instanceof Map<String, Object>) return (Map<String, Object>) value; }
    return null;
  }
  private static List<Object> firstList(Map<String, Object> data, List<String> paths) {
    for (String path : paths) { Object value = pathValue(data, path); if (value instanceof List<Object>) return (List<Object>) value; }
    return null;
  }
  public static void putPath(Map<String, Object> target, String path, Object value) {
    if (target == null || String.isBlank(path)) return;
    List<String> parts = path.split('\\.'); Map<String, Object> cursor = target;
    for (Integer index = 0; index < parts.size() - 1; index++) {
      Object next = cursor.get(parts[index]);
      if (!(next instanceof Map<String, Object>)) { next = new Map<String, Object>(); cursor.put(parts[index], next); }
      cursor = (Map<String, Object>) next;
    }
    cursor.put(parts[parts.size() - 1], value);
  }
  public class CarrierOperationAdapterException extends Exception {}
}