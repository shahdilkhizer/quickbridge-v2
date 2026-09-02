public with sharing class QuickbridgeAdminSecurity {
  public class SessionException extends Exception {}
  public static final String LOGIN_BUCKET = 'login';
  public static final String RECOVERY_BUCKET = 'pin_recovery';
  private static final Integer MAX_ATTEMPTS = 5;
  private static final Integer WINDOW_MINUTES = 15;
  @TestVisible private static Boolean bypassPermissionsForTests = false;
  @TestVisible private static Boolean bypassRateLimitForTests = false;

  public class SessionResult {
    @AuraEnabled public String sessionToken;
    @AuraEnabled public Datetime sessionExpiresAt;
  }

  public static void requireView() {
    if (!hasPermission('View_QuickBridge')) handled('Quickbridge view access is required.');
  }

  public static void requireManage() {
    if (!hasPermission('Manage_QuickBridge')) handled('Quickbridge administrator access is required.');
  }

  public static void requireRun() {
    if (!hasPermission('Run_QuickBridge_Sync')) handled('Quickbridge sync access is required.');
  }

  public static Quickbridge_Admin_Session__c requireSession(String rawToken) {
    requireView();
    if (String.isBlank(rawToken)) throw new SessionException('Quickbridge admin session is required. Please log in again.');
    String tokenHash = hashToken(rawToken);
    List<Quickbridge_Admin_Session__c> rows = [
      SELECT Id, Username__c, Status__c, Expires_At__c, Last_Used_At__c
      FROM Quickbridge_Admin_Session__c WHERE Token_Hash__c = :tokenHash LIMIT 1
    ];
    if (rows.isEmpty() || rows[0].Status__c != 'Active') {
      throw new SessionException('Quickbridge admin session is invalid. Please log in again.');
    }
    Quickbridge_Admin_Session__c row = rows[0];
    if (row.Expires_At__c <= System.now()) {
      Database.update(new Quickbridge_Admin_Session__c(Id = row.Id, Status__c = 'Expired', Last_Used_At__c = System.now()), false);
      throw new SessionException('Quickbridge admin session expired. Please log in again.');
    }
    if (row.Last_Used_At__c == null || row.Last_Used_At__c.addMinutes(5) < System.now()) {
      Database.update(new Quickbridge_Admin_Session__c(Id = row.Id, Last_Used_At__c = System.now()), false);
    }
    return row;
  }

  public static SessionResult createSession(String username) {
    requireView();
    String rawToken = newToken(username);
    Datetime expiresAt = System.now().addHours(2);
    Database.SaveResult result = Database.insert(new Quickbridge_Admin_Session__c(
      Username__c = username.trim(), Token_Hash__c = hashToken(rawToken), Status__c = 'Active',
      Expires_At__c = expiresAt, Last_Used_At__c = System.now()
    ), false);
    if (!result.isSuccess()) handled('The Quickbridge administrator session could not be created.');
    SessionResult response = new SessionResult();
    response.sessionToken = rawToken;
    response.sessionExpiresAt = expiresAt;
    return response;
  }

  public static Boolean revokeSession(String rawToken) {
    if (String.isBlank(rawToken)) return false;
    String tokenHash = hashToken(rawToken);
    List<Quickbridge_Admin_Session__c> rows = [SELECT Id FROM Quickbridge_Admin_Session__c WHERE Token_Hash__c = :tokenHash LIMIT 1];
    if (rows.isEmpty()) return false;
    Database.SaveResult result = Database.update(new Quickbridge_Admin_Session__c(
      Id = rows[0].Id, Status__c = 'Revoked', Revoked_At__c = System.now(), Last_Used_At__c = System.now()
    ), false);
    return result.isSuccess();
  }

  public static void checkRateLimit(String username, String bucket) {
    if (bypassRateLimitForTests || String.isBlank(username)) return;
    String key = bucketHash(username, bucket);
    Datetime nowValue = System.now();
    List<Quickbridge_Admin_Rate_Limit__c> rows = [
      SELECT Id, Attempt_Count__c, Expires_At__c FROM Quickbridge_Admin_Rate_Limit__c
      WHERE Bucket_Hash__c = :key LIMIT 1 FOR UPDATE
    ];
    Quickbridge_Admin_Rate_Limit__c row;
    if (rows.isEmpty()) {
      row = new Quickbridge_Admin_Rate_Limit__c(Bucket_Hash__c = key, Attempt_Count__c = 1, Expires_At__c = nowValue.addMinutes(WINDOW_MINUTES));
      Database.SaveResult inserted = Database.insert(row, false);
      if (!inserted.isSuccess()) handled('Login protection is temporarily unavailable. Please try again later.');
      return;
    }
    row = rows[0];
    if (row.Expires_At__c <= nowValue) {
      row.Attempt_Count__c = 1;
      row.Expires_At__c = nowValue.addMinutes(WINDOW_MINUTES);
    } else if (row.Attempt_Count__c >= MAX_ATTEMPTS) {
      handled('Too many attempts. Please wait 15 minutes before trying again.');
    } else {
      row.Attempt_Count__c++;
    }
    if (!Database.update(row, false).isSuccess()) handled('Login protection is temporarily unavailable. Please try again later.');
  }

  public static void clearRateLimit(String username, String bucket) {
    if (String.isBlank(username)) return;
    String key = bucketHash(username, bucket);
    List<Quickbridge_Admin_Rate_Limit__c> rows = [SELECT Id FROM Quickbridge_Admin_Rate_Limit__c WHERE Bucket_Hash__c = :key LIMIT 1];
    if (!rows.isEmpty()) Database.delete(rows, false);
  }

  public static void audit(String action, String connectorKey, String status, String details, Id relatedRecordId) {
    try {
      String safeDetails = IntegrationErrorLogService.sanitizeForUser(details);
      Database.insert(new Quickbridge_Admin_Audit__c(
        Action__c = String.valueOf(action).left(80), Connector_Key__c = String.valueOf(connectorKey).left(80),
        Status__c = String.valueOf(status).left(40), Details__c = String.isBlank(safeDetails) ? null : safeDetails.left(32768),
        Actor_User__c = UserInfo.getUserId(), Related_Record_Id__c = relatedRecordId == null ? null : String.valueOf(relatedRecordId)
      ), false);
    } catch (Exception ignored) {
      System.debug(LoggingLevel.WARN, 'Quickbridge administrator audit could not be persisted.');
    }
  }

  @TestVisible static String hashToken(String rawToken) {
    return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(rawToken == null ? '' : rawToken)));
  }

  private static Boolean hasPermission(String permissionName) {
    return (Test.isRunningTest() && bypassPermissionsForTests) || FeatureManagement.checkPermission(permissionName);
  }

  private static String bucketHash(String username, String bucket) {
    String seed = UserInfo.getOrganizationId() + ':' + String.valueOf(bucket).toLowerCase() + ':' + username.trim().toLowerCase();
    return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(seed)));
  }

  private static String newToken(String username) {
    String seed = username + ':' + UserInfo.getOrganizationId() + ':' + UserInfo.getUserId() + ':' + System.now().getTime() + ':' + Crypto.getRandomInteger();
    return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-512', Blob.valueOf(seed))).left(64);
  }

  private static void handled(String message) {
    AuraHandledException error = new AuraHandledException(message);
    error.setMessage(message);
    throw error;
  }
}