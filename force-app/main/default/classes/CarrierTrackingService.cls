public without sharing class CarrierTrackingService {
  public static CarrierOperationModels.Result synchronizeNext(String connectorKey) {
    String connector = CarrierOperationCatalog.normalize(connectorKey);
    if (!new Set<String>{ 'fedex', 'ups', 'dhl' }.contains(connector)) {
      throw new CarrierTrackingException('Unsupported carrier tracking connector.');
    }
    List<Carrier_Shipment__c> shipments = [
      SELECT Id, Source_Record_Id__c
      FROM Carrier_Shipment__c
      WHERE Connector_Key__c = :connector AND Is_Terminal__c = false
      ORDER BY LastModifiedDate ASC
      LIMIT 1
    ];
    if (shipments.isEmpty()) {
      CarrierOperationModels.Result result = new CarrierOperationModels.Result();
      result.success = true;
      result.connectorKey = connector;
      result.operationKey = 'synctrackingstatus';
      result.message = 'No non-terminal carrier shipments are due for tracking.';
      return result;
    }
    Id sourceRecordId;
    try {
      sourceRecordId = (Id) shipments[0].Source_Record_Id__c;
    } catch (Exception invalidSource) {
      throw new CarrierTrackingException('A pending carrier shipment has an invalid source record.');
    }
    return CarrierOperationService.execute(
      connector, 'syncTrackingStatus', sourceRecordId, shipments[0].Id, null
    );
  }

  public class CarrierTrackingException extends Exception {}
}