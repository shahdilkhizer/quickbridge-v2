public with sharing class QuickbridgeControlPanelController {
  private static final String PANEL_KEY = 'quickbridge_panel';
  private static final String SERVER_KEY = 'server';
  private static final String AVAILABLE_KEY = 'availableProductsVisible';
  private static final String RENEWAL_RECIPIENT_KEY = 'renewalRecipient';
  private static final Integer DEFAULT_WARNING_DAYS = 30;

  public class AuthenticationResponse {
    @AuraEnabled public Boolean successful;
    @AuraEnabled public String message;
    @AuraEnabled public String username;
    @AuraEnabled public String sessionToken;
    @AuraEnabled public Datetime sessionExpiresAt;
  }

  public class PanelBootstrap {
    @AuraEnabled public String username;
    @AuraEnabled public Datetime sessionExpiresAt;
    @AuraEnabled public Boolean availableProductsVisible;
    @AuraEnabled public List<ConnectorView> connectors = new List<ConnectorView>();
  }

  public class ConnectorView {
    @AuraEnabled public String key;
    @AuraEnabled public String productKey;
    @AuraEnabled public String label;
    @AuraEnabled public String description;
    @AuraEnabled public String logoResourceName;
    @AuraEnabled public Decimal displayOrder;
    @AuraEnabled public Boolean subscribed;
    @AuraEnabled public String entitlementStatus;
    @AuraEnabled public Date expiryDate;
    @AuraEnabled public Boolean active;
    @AuraEnabled public Boolean ready;
    @AuraEnabled public String readinessMessage;
    @AuraEnabled public String health;
    @AuraEnabled public Boolean hasConfig;
    @AuraEnabled public Boolean hasMapping;
    @AuraEnabled public Boolean hasReporting;
    @AuraEnabled public Boolean hasScheduler;
    @AuraEnabled public Boolean hasPayment;
    @AuraEnabled public Boolean hasCarrier;
    @AuraEnabled public Boolean hasCheckout;
    @AuraEnabled public Integer successCount = 0;
    @AuraEnabled public Integer pendingCount = 0;
    @AuraEnabled public Integer retryCount = 0;
    @AuraEnabled public Integer failureCount = 0;
    @AuraEnabled public Datetime lastRun;
    @AuraEnabled public Datetime nextRun;
    @AuraEnabled public String scheduleState;
  }

  public class ActionResponse {
    @AuraEnabled public Boolean successful;
    @AuraEnabled public String message;
  }

  public class ExpiryAlert {
    @AuraEnabled public Boolean shouldAlert = false;
    @AuraEnabled public String variant;
    @AuraEnabled public String title;
    @AuraEnabled public String message;
    @AuraEnabled public Date expiryDate;
    @AuraEnabled public Integer daysUntilExpiry;
  }

  @AuraEnabled
  public static AuthenticationResponse authenticateAdmin(String userId, String pin) {
    QuickbridgeAdminSecurity.requireView();
    AuthenticationResponse result = new AuthenticationResponse();
    String username = String.isBlank(userId) ? null : userId.trim();
    if (String.isBlank(username) || String.isBlank(pin) || !Pattern.matches('^[0-9]{4}$', pin)) {
      result.successful = false;
      result.message = 'Enter your User ID and four-digit PIN.';
      return result;
    }
    Map<String, String> serverConfig = getServerConfig();
    String companyName = serverConfig.get('companyname');
    if (String.isBlank(companyName)) {
      result.successful = false;
      result.message = 'Quickbridge Server companyName is not configured. Please check Server settings in Connector Config.';
      return result;
    }
    QuickbridgeAdminSecurity.checkRateLimit(username, QuickbridgeAdminSecurity.LOGIN_BUCKET);
    try {
      HttpResponse response = sendControlPlane('/services/apexrest/v1/validateClient/', new Map<String, Object>{
        'companyName' => companyName,
        'username' => username,
        'password' => pin
      });
      Map<String, Object> payload = parseObject(response);
      Boolean success = isSuccess(response, payload);
      result.successful = success;
      result.message = safeMessage(payload, success ? 'Login successful.' : 'The User ID or PIN was not accepted.');
      if (success) {
        QuickbridgeAdminSecurity.clearRateLimit(username, QuickbridgeAdminSecurity.LOGIN_BUCKET);
        QuickbridgeAdminSecurity.SessionResult session = QuickbridgeAdminSecurity.createSession(username);
        result.username = username;
        result.sessionToken = session.sessionToken;
        result.sessionExpiresAt = session.sessionExpiresAt;
        QuickbridgeAdminSecurity.audit('LOGIN', null, 'Success', null, null);
      } else {
        QuickbridgeAdminSecurity.recordFailedAttempt(username, QuickbridgeAdminSecurity.LOGIN_BUCKET);
        QuickbridgeAdminSecurity.audit('LOGIN', null, 'Failed', result.message, null);
      }
    } catch (Exception error) {
      QuickbridgeAdminSecurity.recordFailedAttempt(username, QuickbridgeAdminSecurity.LOGIN_BUCKET);
      QuickbridgeAdminSecurity.audit('LOGIN', null, 'Failed', error.getMessage(), null);
      handled('The Quickbridge control-plane connection is unavailable. Verify Quickbridge_Server_NC and try again.');
    }
    return result;
  }

  @AuraEnabled
  public static ActionResponse recoverPin(String userId) {
    QuickbridgeAdminSecurity.requireView();
    String username = String.isBlank(userId) ? null : userId.trim();
    if (String.isBlank(username)) return action(false, 'User ID is required.');
    QuickbridgeAdminSecurity.checkRateLimit(username, QuickbridgeAdminSecurity.RECOVERY_BUCKET);
    try {
      HttpResponse response = sendControlPlane('/services/apexrest/v1/recoverPin/', new Map<String, Object>{ 'username' => username });
      Map<String, Object> payload = parseObject(response);
      Boolean success = isSuccess(response, payload);
      if (success) {
        QuickbridgeAdminSecurity.clearRateLimit(username, QuickbridgeAdminSecurity.RECOVERY_BUCKET);
      } else {
        QuickbridgeAdminSecurity.recordFailedAttempt(username, QuickbridgeAdminSecurity.RECOVERY_BUCKET);
      }
      QuickbridgeAdminSecurity.audit('PIN_RECOVERY', null, success ? 'Success' : 'Failed', safeMessage(payload, null), null);
      return action(success, safeMessage(payload, success ? 'PIN recovery instructions were sent.' : 'PIN recovery could not be completed.'));
    } catch (Exception error) {
      QuickbridgeAdminSecurity.recordFailedAttempt(username, QuickbridgeAdminSecurity.RECOVERY_BUCKET);
      QuickbridgeAdminSecurity.audit('PIN_RECOVERY', null, 'Failed', error.getMessage(), null);
      return action(false, 'PIN recovery is temporarily unavailable.');
    }
  }

  @AuraEnabled
  public static Boolean revokeAdminSession(String sessionToken) {
    Boolean result = QuickbridgeAdminSecurity.revokeSession(sessionToken);
    QuickbridgeAdminSecurity.audit('LOGOUT', null, result ? 'Success' : 'No Session', null, null);
    return result;
  }

  @AuraEnabled(cacheable=false)
  public static PanelBootstrap getPanelBootstrap(String sessionToken) {
    Quickbridge_Admin_Session__c session = QuickbridgeAdminSecurity.requireSession(sessionToken);
    QuickbridgeConfigController.Dashboard dashboard = QuickbridgeConfigController.getDashboard();
    Map<String, QuickbridgeConfigController.ConnectorCard> dashboardByKey = new Map<String, QuickbridgeConfigController.ConnectorCard>();
    for (QuickbridgeConfigController.ConnectorCard card : dashboard.connectors) dashboardByKey.put(normalize(card.key), card);

    Map<String, Connector_Instance__c> instanceByKey = new Map<String, Connector_Instance__c>();
    for (Connector_Instance__c instance : [
      SELECT Connector_Key__c, Entitlement_Status__c, Expiry_Date__c, Active__c, Health_Status__c
      FROM Connector_Instance__c
    ]) instanceByKey.put(normalize(instance.Connector_Key__c), instance);

    PanelBootstrap result = new PanelBootstrap();
    result.username = session.Username__c;
    result.sessionExpiresAt = session.Expires_At__c;
    result.availableProductsVisible = panelBoolean(AVAILABLE_KEY, true);
    for (Integration_Connector__mdt definition : [
      SELECT Connector_Key__c, Product_Key__c, Provider_Label__c, Product_Description__c,
        Logo_Static_Resource__c, Display_Order__c, Has_Config__c, Has_Mapping__c,
        Has_Reporting__c, Has_Scheduler__c, Has_Payment__c, Has_Carrier__c, Has_Checkout__c
      FROM Integration_Connector__mdt WHERE Enabled__c = true ORDER BY Display_Order__c
    ]) {
      String key = normalize(definition.Connector_Key__c);
      Connector_Instance__c instance = instanceByKey.get(key);
      QuickbridgeConfigController.ConnectorCard dashboardCard = dashboardByKey.get(key);
      ConnectorView item = new ConnectorView();
      item.key = key;
      item.productKey = String.isBlank(definition.Product_Key__c) ? key : definition.Product_Key__c;
      item.label = definition.Provider_Label__c;
      item.description = definition.Product_Description__c;
      item.logoResourceName = safeLogo(definition.Logo_Static_Resource__c);
      item.displayOrder = definition.Display_Order__c;
      item.entitlementStatus = instance == null ? 'Available' : instance.Entitlement_Status__c;
      item.expiryDate = instance == null ? null : instance.Expiry_Date__c;
      item.active = instance != null && instance.Active__c;
      item.subscribed = item.active;
      item.health = instance == null || String.isBlank(instance.Health_Status__c) ? 'Unknown' : instance.Health_Status__c;
      item.hasConfig = definition.Has_Config__c;
      item.hasMapping = definition.Has_Mapping__c;
      item.hasReporting = definition.Has_Reporting__c;
      item.hasScheduler = definition.Has_Scheduler__c;
      item.hasPayment = definition.Has_Payment__c;
      item.hasCarrier = definition.Has_Carrier__c;
      item.hasCheckout = definition.Has_Checkout__c;
      if (dashboardCard != null) {
        item.ready = dashboardCard.ready;
        item.readinessMessage = dashboardCard.readinessMessage;
        item.successCount = dashboardCard.successCount;
        item.pendingCount = dashboardCard.pendingCount;
        item.retryCount = dashboardCard.retryCount;
        item.failureCount = dashboardCard.failureCount;
        item.lastRun = dashboardCard.lastRun;
        item.nextRun = dashboardCard.nextRun;
        item.scheduleState = dashboardCard.scheduleState;
      } else {
        item.ready = false;
        item.readinessMessage = 'Connector instance configuration is missing.';
      }
      result.connectors.add(item);
    }
    return result;
  }

  @AuraEnabled
  public static ActionResponse refreshLicenses(String sessionToken) {
    QuickbridgeAdminSecurity.requireManage();
    QuickbridgeAdminSecurity.requireSession(sessionToken);
    Map<String, String> serverConfig = getServerConfig();
    String companyName = serverConfig.get('companyname');
    String serverUsername = serverConfig.get('username');
    String serverPassword = serverConfig.get('password');

    if (String.isBlank(companyName) || String.isBlank(serverUsername) || String.isBlank(serverPassword)) {
      QuickbridgeAdminSecurity.audit('LICENSE_REFRESH', null, 'Failed', 'Missing server credentials in configuration', null);
      return action(false, 'Quickbridge Server credentials (companyName, username, password) are not configured. Please complete Server configuration.');
    }
    try {
      HttpResponse response = sendControlPlane('/services/apexrest/v1/getLicenses', new Map<String, Object>{
        'companyName' => companyName,
        'username' => serverUsername,
        'password' => serverPassword
      });
      Map<String, Object> payload = parseObject(response);
      if (!isSuccess(response, payload)) {
        String message = safeMessage(payload, 'License refresh failed.');
        QuickbridgeAdminSecurity.audit('LICENSE_REFRESH', null, 'Failed', message, null);
        return action(false, message);
      }
      applyLicenses((List<Object>) payload.get('licenses'));
      QuickbridgeAdminSecurity.audit('LICENSE_REFRESH', null, 'Success', null, null);
      return action(true, 'Licenses refreshed.');
    } catch (Exception error) {
      QuickbridgeAdminSecurity.audit('LICENSE_REFRESH', null, 'Failed', error.getMessage(), null);
      return action(false, 'Licenses could not be refreshed. Verify the target control-plane principal.');
    }
  }

  @AuraEnabled
  public static ActionResponse updateAvailableProductsVisible(String sessionToken, Boolean visible) {
    QuickbridgeAdminSecurity.requireManage();
    QuickbridgeAdminSecurity.requireSession(sessionToken);
    savePanelValue(AVAILABLE_KEY, visible == true ? 'true' : 'false');
    QuickbridgeAdminSecurity.audit('AVAILABLE_PRODUCTS_VISIBILITY', null, 'Success', 'visible=' + String.valueOf(visible == true), null);
    return action(true, 'Available-products display preference saved.');
  }

  @AuraEnabled
  public static ActionResponse sendRenewalRequest(String sessionToken, List<String> renewalConnectorKeys, List<String> additionalConnectorKeys) {
    QuickbridgeAdminSecurity.requireManage();
    QuickbridgeAdminSecurity.requireSession(sessionToken);
    Set<String> allowed = enabledConnectorKeys();
    List<String> renewals = validatedLabels(renewalConnectorKeys, allowed);
    List<String> additions = validatedLabels(additionalConnectorKeys, allowed);
    if (renewals.isEmpty() && additions.isEmpty()) return action(false, 'Select at least one product.');
    String recipient = panelValue(RENEWAL_RECIPIENT_KEY);
    if (String.isBlank(recipient)) return action(false, 'Configure the non-secret renewal recipient before sending a request.');
    Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
    email.setToAddresses(new List<String>{ recipient });
    email.setSubject('Quickbridge Renewal Request');
    email.setPlainTextBody('Renew existing subscriptions:\n- ' + String.join(renewals, '\n- ') + '\n\nRequest additional subscriptions:\n- ' + String.join(additions, '\n- '));
    if (!Test.isRunningTest()) Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ email }, false);
    QuickbridgeAdminSecurity.audit('RENEWAL_REQUEST', null, 'Success', 'Renewals=' + String.join(renewals, ',') + '; Additions=' + String.join(additions, ','), null);
    return action(true, 'Renewal request sent.');
  }

  @AuraEnabled
  public static ExpiryAlert checkIntegrationExpiry(String sessionToken, String connectorKey) {
    QuickbridgeAdminSecurity.requireSession(sessionToken);
    String key = requireConnector(connectorKey);
    List<Connector_Instance__c> rows = [SELECT Expiry_Date__c FROM Connector_Instance__c WHERE Connector_Key__c = :key LIMIT 1];
    ExpiryAlert result = new ExpiryAlert();
    if (rows.isEmpty() || rows[0].Expiry_Date__c == null) return result;
    result.expiryDate = rows[0].Expiry_Date__c;
    result.daysUntilExpiry = Date.today().daysBetween(result.expiryDate);
    if (result.daysUntilExpiry > DEFAULT_WARNING_DAYS) return result;
    result.shouldAlert = true;
    result.variant = result.daysUntilExpiry < 0 ? 'error' : 'warning';
    result.title = result.daysUntilExpiry < 0 ? 'Integration Expired' : 'Integration Expiring Soon';
    result.message = result.daysUntilExpiry < 0
      ? 'This integration expired on ' + String.valueOf(result.expiryDate) + '.'
      : 'This integration expires in ' + result.daysUntilExpiry + ' days.';
    recordExpiryAlertOnce(key, result);
    return result;
  }

  @AuraEnabled(cacheable=false)
  public static QuickbridgeConfigController.ConnectorConfiguration getConnectorConfiguration(String sessionToken, String connectorKey) {
    QuickbridgeAdminSecurity.requireSession(sessionToken);
    return QuickbridgeConfigController.getConnectorConfiguration(connectorKey);
  }

  @AuraEnabled
  public static QuickbridgeConfigController.ConnectorConfiguration saveConnectorConfiguration(String sessionToken, String connectorKey, String valuesJson) {
    QuickbridgeAdminSecurity.requireManage();
    QuickbridgeAdminSecurity.requireSession(sessionToken);
    QuickbridgeConfigController.ConnectorConfiguration result = QuickbridgeConfigController.saveConnectorConfiguration(connectorKey, valuesJson);
    QuickbridgeAdminSecurity.audit('CONFIG_SAVE', normalize(connectorKey), 'Success', null, null);
    return result;
  }

  @AuraEnabled
  public static ActionResponse resetConnectorConfiguration(String sessionToken, String connectorKey) {
    QuickbridgeAdminSecurity.requireManage();
    QuickbridgeAdminSecurity.requireSession(sessionToken);
    String key = requireConnector(connectorKey);
    List<Connector_Config_Value__c> values = [SELECT Id FROM Connector_Config_Value__c WHERE Connector_Key__c = :key AND Is_Secret_Reference__c = false];
    if (!values.isEmpty()) Database.delete(values, false);
    List<Connector_Instance__c> instances = [SELECT Id, Active__c FROM Connector_Instance__c WHERE Connector_Key__c = :key LIMIT 1 FOR UPDATE];
    if (!instances.isEmpty()) {
      instances[0].Active__c = false;
      Database.update(instances, false);
    }
    setScheduleStatus(key, 'Paused');
    QuickbridgeAdminSecurity.audit('CONFIG_RESET', key, 'Success', 'Non-secret values cleared.', instances.isEmpty() ? null : instances[0].Id);
    return action(true, 'Configuration reset. Credentials, mappings, and history were preserved.');
  }

  @AuraEnabled
  public static ConnectorHealthProbeResult runHealthProbe(String sessionToken, String connectorKey) {
    QuickbridgeAdminSecurity.requireManage();
    QuickbridgeAdminSecurity.requireSession(sessionToken);
    ConnectorHealthProbeResult result = QuickbridgeConfigController.runHealthProbe(connectorKey);
    QuickbridgeAdminSecurity.audit('HEALTH_PROBE', normalize(connectorKey), result.successful ? 'Success' : 'Failed', result.message, null);
    return result;
  }

  @AuraEnabled
  public static void setConnectorOperationalState(String sessionToken, String connectorKey, String requestedState) {
    QuickbridgeAdminSecurity.requireManage();
    QuickbridgeAdminSecurity.requireSession(sessionToken);
    Boolean pause = String.valueOf(requestedState).toLowerCase() == 'paused';
    QuickbridgeConfigController.setConnectorPaused(connectorKey, pause);
    QuickbridgeAdminSecurity.audit('CONNECTOR_STATE', normalize(connectorKey), 'Success', requestedState, null);
  }

  @AuraEnabled
  public static void runConnector(String sessionToken, String connectorKey) {
    QuickbridgeAdminSecurity.requireRun();
    QuickbridgeAdminSecurity.requireSession(sessionToken);
    QuickbridgeConfigController.runConnector(connectorKey);
    QuickbridgeAdminSecurity.audit('MANUAL_RUN', normalize(connectorKey), 'Queued', null, null);
  }

  private static HttpResponse sendControlPlane(String relativePath, Map<String, Object> payload) {
    HttpRequest request = new HttpRequest();
    request.setEndpoint('callout:Quickbridge_Server_NC' + relativePath);
    request.setMethod('POST');
    request.setHeader('Content-Type', 'application/json');
    request.setTimeout(20000);
    request.setBody(JSON.serialize(payload));
    return new Http().send(request);
  }

  private static Map<String, Object> parseObject(HttpResponse response) {
    if (response == null || String.isBlank(response.getBody())) return new Map<String, Object>();
    try { return (Map<String, Object>) JSON.deserializeUntyped(response.getBody()); }
    catch (Exception error) { return new Map<String, Object>(); }
  }

  private static Boolean isSuccess(HttpResponse response, Map<String, Object> payload) {
    if (response == null || response.getStatusCode() < 200 || response.getStatusCode() >= 300) return false;
    String status = String.valueOf(payload.get('status'));
    return String.isBlank(status) || status == 'null' || status.equalsIgnoreCase('success');
  }

  private static String safeMessage(Map<String, Object> payload, String fallback) {
    String message = payload == null ? null : String.valueOf(payload.get('message'));
    if (String.isBlank(message) || message == 'null') message = fallback;
    return IntegrationErrorLogService.sanitizeForUser(message);
  }

  private static void applyLicenses(List<Object> licenses) {
    if (licenses == null) licenses = new List<Object>();
    Set<String> keys = enabledConnectorKeys();
    Map<String, Connector_Instance__c> byKey = new Map<String, Connector_Instance__c>();
    for (Connector_Instance__c row : [SELECT Id, Connector_Key__c FROM Connector_Instance__c WHERE Connector_Key__c IN :keys FOR UPDATE]) byKey.put(normalize(row.Connector_Key__c), row);
    List<Connector_Instance__c> updates = new List<Connector_Instance__c>();
    for (Object item : licenses) {
      Map<String, Object> license = (Map<String, Object>) item;
      String key = normalize(String.valueOf(license.get('name')));
      if (!keys.contains(key) || !byKey.containsKey(key)) continue;
      Connector_Instance__c row = byKey.get(key);
      row.Entitlement_Status__c = 'Active';
      row.Last_Entitlement_Refresh_At__c = System.now();
      String endDate = String.valueOf(license.get('endDate'));
      if (String.isNotBlank(endDate) && endDate != 'null') {
        try { row.Expiry_Date__c = Date.valueOf(endDate.left(10)); } catch (Exception ignored) {}
      }
      updates.add(row);
    }
    if (!updates.isEmpty()) Database.update(updates, false);
  }

  private static void recordExpiryAlertOnce(String key, ExpiryAlert alert) {
    String stage = alert.daysUntilExpiry < 0 ? 'expired' : (alert.daysUntilExpiry <= 7 ? 'seven_day' : 'thirty_day');
    String markerKey = 'expiryAlert:' + key + ':' + stage + ':' + String.valueOf(Date.today());
    List<Connector_Config_Value__c> markers = [SELECT Id FROM Connector_Config_Value__c WHERE Connector_Key__c = :PANEL_KEY AND Field_Key__c = :markerKey LIMIT 1];
    if (!markers.isEmpty()) return;
    Database.insert(new Connector_Config_Value__c(Name = markerKey.left(80), Connector_Key__c = PANEL_KEY, Field_Key__c = markerKey, Value__c = 'sent', Is_Secret_Reference__c = false), false);
    String recipient = panelValue(RENEWAL_RECIPIENT_KEY);
    if (String.isNotBlank(recipient) && !Test.isRunningTest()) {
      Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
      email.setToAddresses(new List<String>{ recipient });
      email.setSubject(alert.title + ': ' + key);
      email.setPlainTextBody(alert.message);
      Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ email }, false);
    }
    QuickbridgeAdminSecurity.audit('EXPIRY_ALERT', key, 'Sent', stage, null);
  }

  private static void setScheduleStatus(String connectorKey, String status) {
    String integrationType = [SELECT Integration_Type__c FROM Integration_Connector__mdt WHERE Connector_Key__c = :connectorKey LIMIT 1].Integration_Type__c;
    List<Scheduled_Integration_Job__c> jobs = [SELECT Id, Status__c FROM Scheduled_Integration_Job__c WHERE Integration_Type__c = :integrationType AND Status__c != 'Deleted'];
    for (Scheduled_Integration_Job__c job : jobs) job.Status__c = status;
    if (!jobs.isEmpty()) Database.update(jobs, false);
  }

  private static Boolean panelBoolean(String key, Boolean defaultValue) {
    String value = panelValue(key);
    return String.isBlank(value) ? defaultValue : value.equalsIgnoreCase('true');
  }

  private static String panelValue(String key) {
    List<Connector_Config_Value__c> rows = [SELECT Value__c FROM Connector_Config_Value__c WHERE Connector_Key__c = :PANEL_KEY AND Field_Key__c = :key LIMIT 1];
    return rows.isEmpty() ? null : rows[0].Value__c;
  }

  private static Map<String, String> getServerConfig() {
    Map<String, String> configMap = new Map<String, String>();
    for (Connector_Config_Value__c row : [
      SELECT Field_Key__c, Value__c
      FROM Connector_Config_Value__c
      WHERE Connector_Key__c = :SERVER_KEY
    ]) {
      if (String.isNotBlank(row.Field_Key__c) && String.isNotBlank(row.Value__c)) {
        String cleanKey = row.Field_Key__c.trim().toLowerCase();
        if (cleanKey.endsWith('__c')) {
          cleanKey = cleanKey.removeEnd('__c');
        }
        configMap.put(cleanKey, row.Value__c.trim());
      }
    }
    return configMap;
  }

  private static void savePanelValue(String key, String value) {
    List<Connector_Config_Value__c> rows = [SELECT Id, Value__c FROM Connector_Config_Value__c WHERE Connector_Key__c = :PANEL_KEY AND Field_Key__c = :key LIMIT 1 FOR UPDATE];
    Connector_Config_Value__c row = rows.isEmpty()
      ? new Connector_Config_Value__c(Name = (PANEL_KEY + ':' + key).left(80), Connector_Key__c = PANEL_KEY, Field_Key__c = key, Is_Secret_Reference__c = false)
      : rows[0];
    row.Value__c = value;
    if (row.Id == null) Database.insert(row, false); else Database.update(row, false);
  }

  private static Set<String> enabledConnectorKeys() {
    Set<String> result = new Set<String>();
    for (Integration_Connector__mdt row : [SELECT Connector_Key__c, Product_Key__c FROM Integration_Connector__mdt WHERE Enabled__c = true]) {
      result.add(normalize(row.Connector_Key__c));
      if (String.isNotBlank(row.Product_Key__c)) result.add(normalize(row.Product_Key__c));
    }
    return result;
  }

  private static List<String> validatedLabels(List<String> requested, Set<String> allowed) {
    List<String> result = new List<String>();
    if (requested == null) return result;
    Map<String, String> labelsByKey = new Map<String, String>();
    for (Integration_Connector__mdt connector : [
      SELECT Connector_Key__c, Product_Key__c, Provider_Label__c
      FROM Integration_Connector__mdt WHERE Enabled__c = true
    ]) {
      labelsByKey.put(normalize(connector.Connector_Key__c), connector.Provider_Label__c);
      if (String.isNotBlank(connector.Product_Key__c)) {
        labelsByKey.put(normalize(connector.Product_Key__c), connector.Provider_Label__c);
      }
    }
    for (String value : requested) {
      String key = normalize(value);
      if (!allowed.contains(key)) handled('Unsupported connector in renewal request.');
      String label = labelsByKey.get(key);
      if (String.isNotBlank(label) && !result.contains(label)) result.add(label);
    }
    return result;
  }

  private static String requireConnector(String value) {
    String key = normalize(value);
    if (!enabledConnectorKeys().contains(key)) handled('Unsupported connector.');
    return key;
  }

  private static String safeLogo(String value) {
    if (String.isBlank(value) || !Pattern.matches('^[A-Za-z][A-Za-z0-9_]{0,79}$', value)) return 'QuickBridge_Logo';
    return value;
  }

  private static String normalize(String value) { return String.isBlank(value) ? null : value.trim().toLowerCase(); }
  private static ActionResponse action(Boolean success, String message) { ActionResponse result = new ActionResponse(); result.successful = success; result.message = message; return result; }
  private static void handled(String message) { AuraHandledException error = new AuraHandledException(message); error.setMessage(message); throw error; }
}