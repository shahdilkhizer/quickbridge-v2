public inherited sharing class CarrierOperationCatalog {
  private static final Set<String> CONNECTORS = new Set<String>{ 'fedex', 'ups', 'dhl' };
  private static final Set<String> OPERATIONS = new Set<String>{
    'validateaddress', 'quoterates', 'createshipment', 'recoverlabel',
    'createreturnlabel', 'synctrackingstatus', 'voidshipment'
  };
  @TestVisible private static Boolean forceTestFallback = false;
  @TestVisible private static List<Carrier_Operation__mdt> testRows;

  public static CarrierOperationModels.Definition requireDefinition(
    String connectorKey,
    String operationKey
  ) {
    String connector = normalize(connectorKey);
    String operation = normalize(operationKey);
    if (!CONNECTORS.contains(connector) || !OPERATIONS.contains(operation)) {
      throw new CarrierOperationException('Unsupported carrier operation.');
    }
    List<Carrier_Operation__mdt> rows = [
      SELECT Connector_Key__c, Operation_Key__c, MasterLabel, Requires_Shipment__c,
        Requires_Idempotency__c, Required_Request_Paths__c, Response_Paths__c, Enabled__c
      FROM Carrier_Operation__mdt
      WHERE Connector_Key__c = :connector AND Operation_Key__c = :operation
      LIMIT 1
    ];
    if (Test.isRunningTest() && testRows != null) rows = testRows;
    if ((rows.isEmpty() || forceTestFallback) && Test.isRunningTest()) return testDefinition(connector, operation);
    if (rows.isEmpty() || rows[0].Enabled__c != true) {
      throw new CarrierOperationException('This carrier operation is not enabled.');
    }
    return toDefinition(rows[0]);
  }

  public static List<CarrierOperationModels.Definition> definitionsFor(String connectorKey) {
    String connector = normalize(connectorKey);
    if (!CONNECTORS.contains(connector)) return new List<CarrierOperationModels.Definition>();
    List<CarrierOperationModels.Definition> result = new List<CarrierOperationModels.Definition>();
    List<Carrier_Operation__mdt> rows = [
      SELECT Connector_Key__c, Operation_Key__c, MasterLabel, Requires_Shipment__c,
        Requires_Idempotency__c, Required_Request_Paths__c, Response_Paths__c, Enabled__c
      FROM Carrier_Operation__mdt
      WHERE Connector_Key__c = :connector AND Enabled__c = true
      ORDER BY MasterLabel
    ];
    if (Test.isRunningTest() && testRows != null) rows = testRows;
    for (Carrier_Operation__mdt row : rows) {
      if (OPERATIONS.contains(normalize(row.Operation_Key__c))) result.add(toDefinition(row));
    }
    if ((result.isEmpty() || forceTestFallback) && Test.isRunningTest()) {
      for (String operation : OPERATIONS) result.add(testDefinition(connector, operation));
    }
    return result;
  }

  public static Boolean isMutation(String operationKey) {
    return new Set<String>{ 'createshipment', 'recoverlabel', 'createreturnlabel', 'voidshipment' }
      .contains(normalize(operationKey));
  }

  public static Boolean needsShipment(String operationKey) {
    return new Set<String>{ 'recoverlabel', 'createreturnlabel', 'synctrackingstatus', 'voidshipment' }
      .contains(normalize(operationKey));
  }

  private static CarrierOperationModels.Definition toDefinition(Carrier_Operation__mdt row) {
    CarrierOperationModels.Definition result = new CarrierOperationModels.Definition();
    result.connectorKey = normalize(row.Connector_Key__c);
    result.operationKey = normalize(row.Operation_Key__c);
    result.label = row.MasterLabel;
    result.requiresShipment = row.Requires_Shipment__c == true;
    result.requiresIdempotency = row.Requires_Idempotency__c == true;
    result.requiredRequestPaths = String.isBlank(row.Required_Request_Paths__c)
      ? defaultRequestPaths(result.connectorKey, result.operationKey)
      : row.Required_Request_Paths__c;
    result.responsePaths = String.isBlank(row.Response_Paths__c)
      ? defaultResponsePaths(result.operationKey)
      : row.Response_Paths__c;
    return result;
  }

  private static String defaultRequestPaths(String connector, String operation) {
    if (operation == 'createshipment') {
      if (connector == 'ups') return 'Shipment.Shipper,Shipment.ShipTo,Shipment.Package';
      if (connector == 'fedex') return 'requestedShipment.shipper,requestedShipment.recipient,requestedShipment.requestedPackageLineItems';
      return 'customerDetails.shipperDetails,customerDetails.receiverDetails,packages';
    }
    if (operation == 'createreturnlabel') {
      if (connector == 'ups') return 'Shipment.ReturnService,Shipment.ShipFrom';
      if (connector == 'fedex') return 'requestedShipment.returnShipmentDetail,requestedShipment.recipient';
      return 'returnShipment,customerDetails.receiverDetails';
    }
    return null;
  }

  private static String defaultResponsePaths(String operation) {
    if (operation == 'validateaddress') return 'validatedAddress';
    if (operation == 'quoterates') return 'rates,selectedRate';
    if (operation == 'createshipment' || operation == 'createreturnlabel') return 'shipment.externalShipmentId,shipment.masterTrackingNumber,label.content';
    if (operation == 'recoverlabel') return 'label.content';
    if (operation == 'synctrackingstatus') return 'tracking.latestStatus,tracking.events';
    if (operation == 'voidshipment') return 'tracking.latestStatus';
    return null;
  }

  private static CarrierOperationModels.Definition testDefinition(String connector, String operation) {
    CarrierOperationModels.Definition result = new CarrierOperationModels.Definition();
    result.connectorKey = connector;
    result.operationKey = operation;
    result.label = operation;
    result.requiresShipment = needsShipment(operation);
    result.requiresIdempotency = isMutation(operation);
    result.requiredRequestPaths = defaultRequestPaths(connector, operation);
    result.responsePaths = defaultResponsePaths(operation);
    return result;
  }

  public static String normalize(String value) {
    return String.isBlank(value) ? '' : value.trim().toLowerCase().replaceAll('[^a-z0-9]', '');
  }

  public class CarrierOperationException extends Exception {}
}