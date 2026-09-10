public with sharing class CarrierOperationService {
  private static final Integer MAX_RESPONSE_LENGTH = 32000;
  @TestVisible private static List<Field_Mapping__mdt> testMappings;

  public static CarrierOperationModels.ActionContext getActionContext(Id sourceRecordId) {
    assertRecordRead(sourceRecordId);
    CarrierOperationModels.ActionContext context = new CarrierOperationModels.ActionContext();
    String sourceObject = sourceRecordId.getSObjectType().getDescribe().getName();
    requireReadable(Carrier_Shipment__c.SObjectType, 'carrier shipments');
    Set<String> shipmentConnectors = new Set<String>();
    List<Carrier_Shipment__c> linkedShipments = [
      SELECT Id, Connector_Key__c, Master_Tracking_Number__c, Shipment_Status__c, Is_Terminal__c
      FROM Carrier_Shipment__c
      WHERE Source_Record_Id__c = :String.valueOf(sourceRecordId)
      ORDER BY CreatedDate DESC
      LIMIT 50
    ];
    for (Carrier_Shipment__c row : linkedShipments) shipmentConnectors.add(row.Connector_Key__c);
    for (QuickbridgeCapabilityController.ProviderOption provider :
      QuickbridgeCapabilityController.availableProviders('carrier.operation')) {
      List<CarrierOperationModels.Definition> configured = new List<CarrierOperationModels.Definition>();
      for (CarrierOperationModels.Definition definition : CarrierOperationCatalog.definitionsFor(provider.key)) {
        if (definition.requiresShipment && !shipmentConnectors.contains(definition.connectorKey)) continue;
        if (isActionConfigured(definition, sourceObject)) configured.add(definition);
      }
      if (!configured.isEmpty()) {
        context.providers.add(provider);
        context.operations.addAll(configured);
      }
    }
    for (Carrier_Shipment__c row : linkedShipments) {
      CarrierOperationModels.ShipmentOption option = new CarrierOperationModels.ShipmentOption();
      option.id = row.Id;
      option.trackingNumber = row.Master_Tracking_Number__c;
      option.status = row.Shipment_Status__c;
      option.label = String.join(new List<String>{ row.Connector_Key__c, row.Master_Tracking_Number__c, row.Shipment_Status__c }, ' - ');
      context.shipments.add(option);
    }
    return context;
  }

  public static Id prepareMutation(
    String connectorKey,
    String operationKey,
    Id sourceRecordId,
    Id shipmentId
  ) {
    assertRecordRead(sourceRecordId);
    CarrierOperationModels.Definition definition = CarrierOperationCatalog.requireDefinition(connectorKey, operationKey);
    requireReadyConnector(definition.connectorKey);
    if (!CarrierOperationCatalog.isMutation(definition.operationKey)) {
      throw handled('Only carrier mutations require an operation attempt.');
    }
    assertShipment(definition, shipmentId, sourceRecordId, definition.connectorKey);
    requireReadable(Carrier_Operation_Attempt__c.SObjectType, 'carrier operation attempts');
    requireCreatable(Carrier_Operation_Attempt__c.SObjectType, 'carrier operation attempts');
    requireUpdateable(Carrier_Operation_Attempt__c.SObjectType, 'carrier operation attempts');
    String requestKey = String.join(new List<String>{
      definition.connectorKey, definition.operationKey, String.valueOf(sourceRecordId),
      String.valueOf(shipmentId), UserInfo.getUserId()
    }, ':').left(255);
    List<Carrier_Operation_Attempt__c> existing = [
      SELECT Id
      FROM Carrier_Operation_Attempt__c
      WHERE Request_Key__c = :requestKey
      LIMIT 1
    ];
    if (!existing.isEmpty()) return existing[0].Id;
    Carrier_Operation_Attempt__c attempt = new Carrier_Operation_Attempt__c(
      Request_Key__c = requestKey, Connector_Key__c = definition.connectorKey,
      Operation_Key__c = definition.operationKey, Source_Record_Id__c = String.valueOf(sourceRecordId),
      Shipment__c = shipmentId, Status__c = 'Prepared'
    );
    try {
      insert attempt;
    } catch (DmlException duplicateRequest) {
      List<Carrier_Operation_Attempt__c> concurrent = [
        SELECT Id FROM Carrier_Operation_Attempt__c WHERE Request_Key__c = :requestKey LIMIT 1
      ];
      if (concurrent.isEmpty()) throw duplicateRequest;
      return concurrent[0].Id;
    }
    attempt.Idempotency_Key__c = String.join(new List<String>{ definition.connectorKey, definition.operationKey, String.valueOf(attempt.Id) }, ':');
    update attempt;
    return attempt.Id;
  }

  public static CarrierOperationModels.Result execute(
    String connectorKey,
    String operationKey,
    Id sourceRecordId,
    Id shipmentId,
    Id attemptId
  ) {
    assertRecordRead(sourceRecordId);
    CarrierOperationModels.Definition definition = CarrierOperationCatalog.requireDefinition(connectorKey, operationKey);
    requireReadyConnector(definition.connectorKey);
    assertShipment(definition, shipmentId, sourceRecordId, definition.connectorKey);
    return executeInternal(definition, sourceRecordId, shipmentId, attemptId);
  }

  private static CarrierOperationModels.Result executeInternal(
    CarrierOperationModels.Definition definition,
    Id sourceRecordId,
    Id shipmentId,
    Id attemptId
  ) {
    Carrier_Operation_Attempt__c attempt;
    if (definition.requiresIdempotency == true) {
      if (attemptId == null) throw handled('Prepare the carrier mutation before execution.');
      requireReadable(Carrier_Operation_Attempt__c.SObjectType, 'carrier operation attempts');
      attempt = [
        SELECT Id, Connector_Key__c, Operation_Key__c, Source_Record_Id__c, Shipment__c, Status__c,
          Idempotency_Key__c, Result_JSON__c
        FROM Carrier_Operation_Attempt__c WHERE Id = :attemptId FOR UPDATE
      ];
      if (attempt.Connector_Key__c != definition.connectorKey ||
          attempt.Operation_Key__c != definition.operationKey ||
          attempt.Source_Record_Id__c != String.valueOf(sourceRecordId)) {
        throw handled('The carrier operation attempt does not match this request.');
      }
      if (attempt.Status__c == 'Succeeded') return cachedSuccess(attempt);
    }
    if (definition.operationKey == 'synctrackingstatus' && isTerminal(shipmentId)) {
      CarrierOperationModels.Result skipped = new CarrierOperationModels.Result();
      skipped.success = true; skipped.connectorKey = definition.connectorKey;
      skipped.operationKey = definition.operationKey; skipped.shipmentId = shipmentId;
      skipped.message = 'Shipment is terminal. Tracking sync skipped.';
      return skipped;
    }
    if (definition.operationKey == 'voidshipment') assertVoidAllowed(shipmentId);

    CarrierOperationModels.Request request = new CarrierOperationModels.Request();
    request.connectorKey = definition.connectorKey;
    request.operationKey = definition.operationKey;
    request.sourceRecordId = sourceRecordId;
    request.sourceObjectApiName = sourceRecordId.getSObjectType().getDescribe().getName();
    request.shipmentId = shipmentId;
    request.idempotencyKey = attempt == null ? null : attempt.Idempotency_Key__c;
    request.payload = buildPayload(request, definition);
    CarrierOperationModels.Result result = CarrierOperationAdapterFactory.forConnector(definition.connectorKey).execute(request);
    result.connectorKey = definition.connectorKey;
    result.operationKey = definition.operationKey;
    result.attemptId = attempt == null ? null : attempt.Id;
    if (result.success == true) {
      try {
        persistSuccess(result, request, definition);
        if (attempt != null) {
          attempt.Status__c = 'Succeeded';
          attempt.Result_JSON__c = JSON.serialize(result).left(MAX_RESPONSE_LENGTH);
          attempt.Error_Message__c = null;
          attempt.Http_Status_Code__c = result.httpStatusCode;
          attempt.Retryable__c = false;
          update attempt;
        }
      } catch (Exception persistenceFailure) {
        result.success = false;
        result.retryable = false;
        result.errorSummary = ConnectorExecutionResult.sanitizeError(persistenceFailure.getMessage());
        result.message = result.errorSummary;
        persistFailure(attempt, result, sourceRecordId, definition);
      }
    } else {
      persistFailure(attempt, result, sourceRecordId, definition);
    }
    return result;
  }

  public static CarrierOperationModels.Result applyValidatedAddress(
    String connectorKey, Id sourceRecordId, Map<String, Object> address
  ) {
    assertRecordRead(sourceRecordId);
    CarrierOperationModels.Definition definition = CarrierOperationCatalog.requireDefinition(connectorKey, 'validateAddress');
    CarrierOperationModels.Result result = new CarrierOperationModels.Result();
    result.connectorKey = definition.connectorKey; result.operationKey = definition.operationKey;
    result.correctedAddress = address;
    result.normalized.put('validatedAddress', address);
    applyResponseMappings(sourceRecordId, sourceRecordId.getSObjectType().getDescribe().getName(), definition, result.normalized);
    result.success = true; result.message = 'Validated address applied to the Salesforce record.';
    return result;
  }

  public static CarrierOperationModels.Result selectRateQuote(Id rateQuoteId, Id sourceRecordId) {
    assertRecordRead(sourceRecordId);
    Carrier_Rate_Quote__c quote = [
      SELECT Id, Connector_Key__c, Source_Record_Id__c, Service_Type__c, Service_Name__c, Total_Net_Charge__c,
        Currency_Code__c, Transit_Time__c, Delivery_Timestamp__c, Shipment__c
      FROM Carrier_Rate_Quote__c WHERE Id = :rateQuoteId LIMIT 1
    ];
    requireReadable(Carrier_Rate_Quote__c.SObjectType, 'carrier rate quotes');
    requireUpdateable(Carrier_Rate_Quote__c.SObjectType, 'carrier rate quotes');
    if (quote.Source_Record_Id__c != String.valueOf(sourceRecordId)) {
      throw handled('The selected rate does not belong to this Salesforce record.');
    }
    List<Carrier_Rate_Quote__c> prior = quote.Shipment__c == null ? [
      SELECT Id FROM Carrier_Rate_Quote__c WHERE Source_Record_Id__c = :String.valueOf(sourceRecordId) AND Id != :quote.Id AND Is_Selected__c = true
    ] : [SELECT Id FROM Carrier_Rate_Quote__c WHERE Shipment__c = :quote.Shipment__c AND Id != :quote.Id AND Is_Selected__c = true];
    for (Carrier_Rate_Quote__c row : prior) row.Is_Selected__c = false;
    quote.Is_Selected__c = true;
    Database.update(prior, false); update quote;
    CarrierOperationModels.Definition definition = CarrierOperationCatalog.requireDefinition(quote.Connector_Key__c, 'quoteRates');
    Map<String, Object> values = new Map<String, Object>{ 'selectedRate' => new Map<String, Object>{
      'serviceType'=>quote.Service_Type__c, 'serviceName'=>quote.Service_Name__c,
      'totalNetCharge'=>quote.Total_Net_Charge__c, 'currencyCode'=>quote.Currency_Code__c,
      'transitTime'=>quote.Transit_Time__c, 'deliveryTimestamp'=>quote.Delivery_Timestamp__c
    }};
    applyResponseMappings(sourceRecordId, sourceRecordId.getSObjectType().getDescribe().getName(), definition, values);
    CarrierOperationModels.Result result = new CarrierOperationModels.Result();
    result.success = true; result.message = 'Selected rate saved.'; result.connectorKey = quote.Connector_Key__c; result.operationKey = 'quoteRates';
    return result;
  }

  private static void persistSuccess(
    CarrierOperationModels.Result result, CarrierOperationModels.Request request,
    CarrierOperationModels.Definition definition
  ) {
    Id shipmentId = request.shipmentId;
    if (definition.operationKey == 'createshipment' || definition.operationKey == 'createreturnlabel') {
      shipmentId = ensureShipment(request, definition.operationKey == 'createreturnlabel');
    }
    if (shipmentId != null) {
      updateShipment(shipmentId, result, definition.operationKey);
      result.shipmentId = shipmentId;
      persistPackage(shipmentId, result.normalized, definition.connectorKey);
      if (definition.operationKey == 'synctrackingstatus') persistTracking(shipmentId, result.normalized, definition.connectorKey);
      Id fileId = saveLabel(shipmentId, result.normalized);
      if (fileId != null) result.fileId = fileId;
    }
    if (definition.operationKey == 'quoterates') persistRates(request.sourceRecordId, shipmentId, result);
    if (definition.operationKey == 'validateaddress') result.correctedAddress = mapAt(result.normalized, 'validatedAddress');
    applyResponseMappings(request.sourceRecordId, request.sourceObjectApiName, definition, result.normalized);
    IntegrationOutcomeService.markSuccess(new Set<Id>{ request.sourceRecordId }, definition.connectorKey, definition.operationKey);
    result.message = definition.operationKey == 'synctrackingstatus' ? 'Tracking status synchronized.' : 'Carrier action completed successfully.';
  }

  private static Map<String, Object> buildPayload(CarrierOperationModels.Request request, CarrierOperationModels.Definition definition) {
    Map<String, Object> payload = new Map<String, Object>();
    List<Field_Mapping__mdt> mappings = activeMappings(definition, request.sourceObjectApiName);
    Set<String> fields = new Set<String>{ 'Id' };
    for (Field_Mapping__mdt mapping : mappings) {
      if (isOutbound(mapping.Sync_Direction__c) && safeField(mapping.SF_Field__c)) fields.add(mapping.SF_Field__c);
    }
    if (!mappings.isEmpty()) {
      Id sourceId = request.sourceRecordId;
      SObject source = Database.query('SELECT ' + String.join(new List<String>(fields), ',') + ' FROM ' + request.sourceObjectApiName + ' WHERE Id = :sourceId LIMIT 1');
      Map<String, Schema.SObjectField> describe = source.getSObjectType().getDescribe().fields.getMap();
      for (Field_Mapping__mdt mapping : mappings) {
        if (!isOutbound(mapping.Sync_Direction__c) || !safeField(mapping.SF_Field__c) || !safePath(mapping.External_Field__c)) continue;
        Schema.SObjectField field = describe.get(mapping.SF_Field__c);
        if (field == null || !field.getDescribe().isAccessible()) throw handled('A configured carrier source field is not accessible.');
        Object value = source.get(mapping.SF_Field__c);
        if (value != null) CarrierOperationAdapterFactory.putPath(payload, mapping.External_Field__c, value);
      }
    }
    if (request.shipmentId != null) {
      requireReadable(Carrier_Shipment__c.SObjectType, 'carrier shipments');
      Carrier_Shipment__c shipment = [SELECT External_Shipment_Id__c, Master_Tracking_Number__c FROM Carrier_Shipment__c WHERE Id = :request.shipmentId];
      payload.put('shipmentId', shipment.External_Shipment_Id__c);
      payload.put('trackingNumber', shipment.Master_Tracking_Number__c);
    }
    if (requiresRequestPayload(definition.operationKey) && mappings.isEmpty()) throw handled('Configure active request mappings before running this carrier operation.');
    return payload;
  }

  private static void applyResponseMappings(Id sourceId, String objectName, CarrierOperationModels.Definition definition, Map<String, Object> values) {
    List<Field_Mapping__mdt> mappings = activeMappings(definition, objectName);
    if (mappings.isEmpty()) return;
    Schema.SObjectType objectType = sourceId.getSObjectType();
    if (!objectType.getDescribe().isUpdateable()) throw handled('The Salesforce record is not updateable.');
    Map<String, Schema.SObjectField> fields = objectType.getDescribe().fields.getMap();
    SObject updateRecord = objectType.newSObject(sourceId);
    Boolean changed = false;
    for (Field_Mapping__mdt mapping : mappings) {
      if (!isInbound(mapping.Sync_Direction__c) || !safeField(mapping.SF_Field__c) || !safePath(mapping.External_Field__c)) continue;
      Schema.SObjectField field = fields.get(mapping.SF_Field__c);
      if (field == null || !field.getDescribe().isUpdateable()) throw handled('A configured carrier response field is not updateable.');
      Object value = pathValue(values, mapping.External_Field__c);
      if (value != null) { updateRecord.put(mapping.SF_Field__c, value); changed = true; }
    }
    if (changed) Database.update(updateRecord, false);
  }

  private static Id ensureShipment(CarrierOperationModels.Request request, Boolean isReturn) {
    requireReadable(Carrier_Shipment__c.SObjectType, 'carrier shipments');
    List<Carrier_Shipment__c> rows = [
      SELECT Id FROM Carrier_Shipment__c WHERE Source_Record_Id__c = :String.valueOf(request.sourceRecordId)
        AND Connector_Key__c = :request.connectorKey AND Is_Return__c = :isReturn LIMIT 1
    ];
    if (!rows.isEmpty()) return rows[0].Id;
    requireCreatable(Carrier_Shipment__c.SObjectType, 'carrier shipments');
    Carrier_Shipment__c shipment = new Carrier_Shipment__c(
      Connector_Key__c=request.connectorKey, Source_Record_Id__c=String.valueOf(request.sourceRecordId),
      Source_Object__c=request.sourceObjectApiName, Is_Return__c=isReturn,
      Original_Shipment__c=isReturn ? request.shipmentId : null
    );
    insert shipment; return shipment.Id;
  }

  private static void updateShipment(Id shipmentId, CarrierOperationModels.Result result, String operation) {
    requireReadable(Carrier_Shipment__c.SObjectType, 'carrier shipments');
    requireUpdateable(Carrier_Shipment__c.SObjectType, 'carrier shipments');
    Carrier_Shipment__c existing = [
      SELECT External_Shipment_Id__c, Master_Tracking_Number__c, Latest_Status__c,
        Shipment_Status__c, Is_Terminal__c
      FROM Carrier_Shipment__c WHERE Id = :shipmentId LIMIT 1
    ];
    Carrier_Shipment__c updateRow = new Carrier_Shipment__c(Id=shipmentId);
    String externalShipmentId = stringAt(result.normalized, 'shipment.externalShipmentId');
    String trackingNumber = stringAt(result.normalized, 'shipment.masterTrackingNumber');
    String latestStatus = stringAt(result.normalized, 'tracking.latestStatus');
    updateRow.External_Shipment_Id__c = String.isBlank(externalShipmentId) ? existing.External_Shipment_Id__c : externalShipmentId;
    updateRow.Master_Tracking_Number__c = String.isBlank(trackingNumber) ? existing.Master_Tracking_Number__c : trackingNumber;
    updateRow.Latest_Status__c = String.isBlank(latestStatus) ? existing.Latest_Status__c : latestStatus;
    updateRow.Shipment_Status__c = operation == 'voidshipment' ? 'Voided' : (String.isBlank(latestStatus) ? existing.Shipment_Status__c : latestStatus);
    updateRow.Is_Terminal__c = operation == 'voidshipment' || isTerminalStatus(updateRow.Shipment_Status__c);
    updateRow.Raw_Response__c = stringAt(result.normalized, 'rawResponse');
    Database.update(updateRow, false);
    result.trackingNumber = updateRow.Master_Tracking_Number__c;
  }

  private static void persistPackage(Id shipmentId, Map<String,Object> values, String connectorKey) {
    String tracking = stringAt(values, 'package.trackingNumber');
    if (String.isBlank(tracking)) return;
    requireReadable(Carrier_Package__c.SObjectType, 'carrier packages');
    List<Carrier_Package__c> rows = [SELECT Id FROM Carrier_Package__c WHERE Shipment__c = :shipmentId AND Tracking_Number__c = :tracking LIMIT 1];
    if (rows.isEmpty()) {
      requireCreatable(Carrier_Package__c.SObjectType, 'carrier packages');
      insert new Carrier_Package__c(Shipment__c=shipmentId, Connector_Key__c=connectorKey, Tracking_Number__c=tracking);
    }
  }

  private static void persistRates(Id sourceId, Id shipmentId, CarrierOperationModels.Result result) {
    Object raw = pathValue(result.normalized, 'rates');
    if (!(raw instanceof List<Object>)) return;
    requireCreatable(Carrier_Rate_Quote__c.SObjectType, 'carrier rate quotes');
    List<Carrier_Rate_Quote__c> newRows = new List<Carrier_Rate_Quote__c>();
    for (Object item : (List<Object>) raw) {
      if (!(item instanceof Map<String,Object>)) continue;
      Map<String,Object> rate = (Map<String,Object>)item;
      Carrier_Rate_Quote__c row = new Carrier_Rate_Quote__c(
        Shipment__c=shipmentId, Source_Record_Id__c=String.valueOf(sourceId), Connector_Key__c=result.connectorKey,
        Service_Type__c=firstString(rate, new List<String>{'serviceType','serviceCode','serviceName'}),
        Service_Name__c=firstString(rate, new List<String>{'serviceName','serviceType'}),
        Total_Net_Charge__c=decimalAt(rate, new List<String>{'totalNetCharge','totalCharge','totalNetFedExCharge'}),
        Currency_Code__c=firstString(rate, new List<String>{'currencyCode','currency'}),
        Transit_Time__c=firstString(rate, new List<String>{'transitTime','commitDateDetail.dayFormat'})
      );
      newRows.add(row);
    }
    if (!newRows.isEmpty()) insert newRows;
    for (Carrier_Rate_Quote__c row : newRows) {
      CarrierOperationModels.RateQuote option = new CarrierOperationModels.RateQuote();
      option.id=row.Id; option.serviceType=row.Service_Type__c; option.serviceName=row.Service_Name__c;
      option.totalNetCharge=row.Total_Net_Charge__c; option.currencyCode=row.Currency_Code__c; option.transitTime=row.Transit_Time__c;
      result.rateQuotes.add(option);
    }
  }

  private static void persistTracking(Id shipmentId, Map<String,Object> values, String connectorKey) {
    Object raw = pathValue(values, 'tracking.events');
    if (!(raw instanceof List<Object>)) return;
    requireCreatable(Carrier_Tracking_Event__c.SObjectType, 'carrier tracking events');
    List<Carrier_Tracking_Event__c> rows = new List<Carrier_Tracking_Event__c>();
    Set<String> deduplicationKeys = new Set<String>();
    for (Object item : (List<Object>) raw) {
      if (!(item instanceof Map<String,Object>)) continue;
      Map<String,Object> event = (Map<String,Object>)item;
      String code=firstString(event,new List<String>{'code','eventCode','statusCode'});
      String stamp=firstString(event,new List<String>{'timestamp','date','eventTimestamp'});
      Carrier_Tracking_Event__c row=new Carrier_Tracking_Event__c(
        Shipment__c=shipmentId, Connector_Key__c=connectorKey,
        Tracking_Number__c=stringAt(values,'tracking.trackingNumber'), Event_Code__c=code,
        Event_Description__c=firstString(event,new List<String>{'description','eventDescription'}),
        Deduplication_Key__c=String.join(new List<String>{String.valueOf(shipmentId),String.valueOf(code),String.valueOf(stamp)},':').left(255)
      );
      if (deduplicationKeys.add(row.Deduplication_Key__c)) rows.add(row);
    }
    if (!rows.isEmpty()) upsert rows Carrier_Tracking_Event__c.Fields.Deduplication_Key__c;
  }

  private static Id saveLabel(Id shipmentId, Map<String,Object> values) {
    String content=stringAt(values,'label.content'); if (String.isBlank(content)) return null;
    if (!ContentVersion.SObjectType.getDescribe().isCreateable()) throw handled('You do not have access to save carrier label files.');
    requireUpdateable(Carrier_Shipment__c.SObjectType, 'carrier shipments');
    ContentVersion version = new ContentVersion(Title=stringAt(values,'label.fileName'), PathOnClient=stringAt(values,'label.fileName'), VersionData=EncodingUtil.base64Decode(content), FirstPublishLocationId=shipmentId);
    insert version;
    version=[SELECT ContentDocumentId FROM ContentVersion WHERE Id=:version.Id];
    update new Carrier_Shipment__c(Id=shipmentId,Label_Content_Document_Id__c=version.ContentDocumentId);
    return version.ContentDocumentId;
  }

  private static CarrierOperationModels.Result cachedSuccess(Carrier_Operation_Attempt__c attempt) {
    CarrierOperationModels.Result result = new CarrierOperationModels.Result();
    result.success=true; result.attemptId=attempt.Id; result.connectorKey=attempt.Connector_Key__c; result.operationKey=attempt.Operation_Key__c;
    result.message='This carrier action was already completed.'; return result;
  }
  private static void persistFailure(Carrier_Operation_Attempt__c attempt, CarrierOperationModels.Result result, Id sourceRecordId, CarrierOperationModels.Definition definition) {
    if (attempt != null) {
      requireUpdateable(Carrier_Operation_Attempt__c.SObjectType, 'carrier operation attempts');
      attempt.Status__c = result.retryable == true ? 'Retryable Failure' : 'Failed';
      attempt.Error_Message__c = result.errorSummary == null ? result.message : result.errorSummary;
      attempt.Http_Status_Code__c = result.httpStatusCode;
      attempt.Retryable__c = result.retryable == true;
      update attempt;
    }
    IntegrationOutcomeService.markFailure(new Set<Id>{ sourceRecordId }, definition.connectorKey, definition.operationKey);
  }
  private static void requireReadyConnector(String connectorKey) { if (!ConnectorReadinessService.assess(connectorKey, true).operationalReady) throw handled('The selected carrier is not ready.'); }
  private static void assertRecordRead(Id recordId) { if (recordId==null || !recordId.getSObjectType().getDescribe().isAccessible()) throw handled('The source record is unavailable.'); List<UserRecordAccess> rows=[SELECT RecordId, HasReadAccess FROM UserRecordAccess WHERE UserId=:UserInfo.getUserId() AND RecordId=:recordId]; if(rows.isEmpty()||!rows[0].HasReadAccess) throw handled('The source record is unavailable.'); }
  private static void assertShipment(CarrierOperationModels.Definition definition, Id shipmentId, Id sourceId, String connector) { if (!definition.requiresShipment) return; if (shipmentId==null) throw handled('Select a carrier shipment first.'); requireReadable(Carrier_Shipment__c.SObjectType, 'carrier shipments'); Carrier_Shipment__c row=[SELECT Id,Source_Record_Id__c,Connector_Key__c FROM Carrier_Shipment__c WHERE Id=:shipmentId LIMIT 1]; if(row.Source_Record_Id__c!=String.valueOf(sourceId)||row.Connector_Key__c!=connector) throw handled('The selected shipment does not belong to this carrier record.'); }
  private static Boolean isTerminal(Id shipmentId) { return shipmentId != null && [SELECT Is_Terminal__c FROM Carrier_Shipment__c WHERE Id=:shipmentId].Is_Terminal__c; }
  private static void assertVoidAllowed(Id shipmentId) { Carrier_Shipment__c row=[SELECT Is_Terminal__c,Shipment_Status__c FROM Carrier_Shipment__c WHERE Id=:shipmentId]; if(row.Is_Terminal__c||row.Shipment_Status__c=='Delivered') throw handled('Delivered or terminal shipments cannot be voided.'); }
  private static Boolean requiresRequestPayload(String op) { return new Set<String>{'validateaddress','quoterates','createshipment','createreturnlabel'}.contains(op); }
  private static Boolean isActionConfigured(CarrierOperationModels.Definition definition, String sourceObject) {
    if (!requiresRequestPayload(definition.operationKey)) return true;
    List<Field_Mapping__mdt> rows = activeMappings(definition, sourceObject);
    Set<String> outboundPaths = new Set<String>();
    for (Field_Mapping__mdt row : rows) if (isOutbound(row.Sync_Direction__c)) outboundPaths.add(row.External_Field__c);
    if (outboundPaths.isEmpty()) return false;
    if (String.isBlank(definition.requiredRequestPaths)) return true;
    for (String requiredPath : definition.requiredRequestPaths.split(',')) {
      String required = requiredPath == null ? null : requiredPath.trim();
      if (String.isBlank(required)) continue;
      Boolean found = false;
      for (String mapped : outboundPaths) if (mapped == required || mapped.startsWith(required + '.')) { found = true; break; }
      if (!found) return false;
    }
    return true;
  }
  private static List<Field_Mapping__mdt> activeMappings(CarrierOperationModels.Definition definition, String sourceObject) {
    if (Test.isRunningTest() && testMappings != null) return testMappings;
    return [
      SELECT SF_Field__c, External_Field__c, Sync_Direction__c
      FROM Field_Mapping__mdt
      WHERE Integration__c = :definition.connectorKey AND Action__c = :definition.operationKey
        AND SF_Object__c = :sourceObject AND Is_Active__c = true
    ];
  }
  private static void requireReadable(Schema.SObjectType objectType, String label) { if (!objectType.getDescribe().isAccessible()) throw handled('You do not have access to ' + label + '.'); }
  private static void requireCreatable(Schema.SObjectType objectType, String label) { if (!objectType.getDescribe().isCreateable()) throw handled('You do not have permission to create ' + label + '.'); }
  private static void requireUpdateable(Schema.SObjectType objectType, String label) { if (!objectType.getDescribe().isUpdateable()) throw handled('You do not have permission to update ' + label + '.'); }
  private static Boolean isOutbound(String d) { String v=String.isBlank(d)?'both':d.toLowerCase(); return v=='both'||v=='outbound'||v.contains('sf to'); }
  private static Boolean isInbound(String d) { String v=String.isBlank(d)?'both':d.toLowerCase(); return v=='both'||v=='inbound'||v.contains('to sf'); }
  private static Boolean safeField(String field) { return String.isNotBlank(field)&&Pattern.matches('^[A-Za-z][A-Za-z0-9_]{0,79}$',field); }
  private static Boolean safePath(String path) { return String.isNotBlank(path)&&Pattern.matches('^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z0-9_]+){0,19}$',path); }
  private static Object pathValue(Object value,String path) { Object c=value; for(String p:path.split('\\.')) { if(c instanceof Map<String,Object>) c=((Map<String,Object>)c).get(p); else if(c instanceof List<Object>&&Pattern.matches('^[0-9]+$',p)){List<Object> l=(List<Object>)c;Integer i=Integer.valueOf(p);c=i<l.size()?l[i]:null;}else return null;if(c==null)return null;}return c; }
  private static String stringAt(Map<String,Object> data,String path){Object v=pathValue(data,path);return v==null?null:String.valueOf(v);}
  private static Map<String,Object> mapAt(Map<String,Object> data,String path){Object v=pathValue(data,path);return v instanceof Map<String,Object>?(Map<String,Object>)v:null;}
  private static String firstString(Map<String,Object> data,List<String> paths){for(String p:paths){Object v=pathValue(data,p);if(v!=null&&String.isNotBlank(String.valueOf(v)))return String.valueOf(v);}return null;}
  private static Decimal decimalAt(Map<String,Object> data,List<String> paths){for(String p:paths){Object v=pathValue(data,p);try{if(v!=null)return Decimal.valueOf(String.valueOf(v));}catch(Exception ignored){}}return null;}
  private static Boolean isTerminalStatus(String status){return new Set<String>{'delivered','voided','cancelled','returned'}.contains(String.isBlank(status)?'':status.toLowerCase());}
  private static AuraHandledException handled(String message) {
    AuraHandledException error = new AuraHandledException(message);
    error.setMessage(message);
    return error;
  }
}