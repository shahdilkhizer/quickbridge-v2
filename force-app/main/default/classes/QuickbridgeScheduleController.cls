public with sharing class QuickbridgeScheduleController {
  private static final Set<String> FREQUENCIES = new Set<String>{
    'Minutes',
    'Hours',
    'Days',
    'Weeks',
    'Months'
  };
  private static final Set<String> DIRECTIONS = new Set<String>{
    'Inbound',
    'Outbound',
    'Bidirectional',
    'In',
    'Out'
  };

  public class Workspace {
    @AuraEnabled
    public String connectorKey;
    @AuraEnabled
    public List<Option> objects = new List<Option>();
    @AuraEnabled
    public List<Option> directions = new List<Option>();
    @AuraEnabled
    public List<Option> frequencies = new List<Option>();
    @AuraEnabled
    public List<ScheduleView> schedules = new List<ScheduleView>();
    @AuraEnabled
    public String heartbeatStatus;
    @AuraEnabled
    public Datetime nextHeartbeat;
    @AuraEnabled
    public Integer backlogCount;
    @AuraEnabled
    public Integer activeLeaseCount;
  }
  public class Option {
    @AuraEnabled
    public String label;
    @AuraEnabled
    public String value;
    public Option(String l, String v) {
      label = l;
      value = v;
    }
  }
  public class ScheduleView {
    @AuraEnabled
    public Id id;
    @AuraEnabled
    public String name;
    @AuraEnabled
    public String sourceObject;
    @AuraEnabled
    public String direction;
    @AuraEnabled
    public String status;
    @AuraEnabled
    public Decimal frequencyValue;
    @AuraEnabled
    public String frequencyType;
    @AuraEnabled
    public Datetime nextRun;
    @AuraEnabled
    public Datetime lastRun;
    @AuraEnabled
    public String lastError;
    @AuraEnabled
    public String createdBy;
    @AuraEnabled
    public Datetime createdAt;
    @AuraEnabled
    public Datetime leaseExpiresAt;
    @AuraEnabled
    public String processorJobId;
    @AuraEnabled
    public String executionState;
  }
  public class SaveRequest {
    public Id scheduleId;
    public String connectorKey;
    public String sourceObject;
    public String direction;
    public Decimal frequencyValue;
    public String frequencyType;
    public String schedulerName;
  }
  public class RecentRun {
    @AuraEnabled
    public Id id;
    @AuraEnabled
    public Datetime runAt;
    @AuraEnabled
    public Datetime completedAt;
    @AuraEnabled
    public String status;
    @AuraEnabled
    public Integer processed;
    @AuraEnabled
    public Integer succeeded;
    @AuraEnabled
    public Integer failed;
    @AuraEnabled
    public Integer skipped;
    @AuraEnabled
    public Long durationMs;
    @AuraEnabled
    public String message;
  }
  public class Preview {
    @AuraEnabled
    public List<Datetime> nextRuns = new List<Datetime>();
  }

  @AuraEnabled(cacheable=false)
  public static Workspace getScheduleWorkspace(
    String sessionToken,
    String connectorKey
  ) {
    QuickbridgeAdminSecurity.requireSession(sessionToken);
    String key = requireConnector(connectorKey);
    Workspace result = new Workspace();
    result.connectorKey = key;
    Set<String> objects = new Set<String>();
    Set<String> directions = new Set<String>();
    for (Integration_Operation__mdt operation : [
      SELECT Salesforce_Object__c, Direction__c
      FROM Integration_Operation__mdt
      WHERE Connector_Key__c = :key AND Active__c = TRUE
    ]) {
      if (String.isNotBlank(operation.Salesforce_Object__c))
        objects.add(operation.Salesforce_Object__c);
      if (String.isNotBlank(operation.Direction__c))
        directions.add(operation.Direction__c);
    }
    List<String> sortedObjects = new List<String>(objects);
    sortedObjects.sort();
    for (String objectName : sortedObjects)
      result.objects.add(new Option(labelForObject(objectName), objectName));
    if (directions.isEmpty())
      directions.addAll(new Set<String>{ 'Inbound', 'Outbound' });
    List<String> sortedDirections = new List<String>(directions);
    sortedDirections.sort();
    for (String direction : sortedDirections)
      result.directions.add(new Option(direction, direction));
    for (
      String frequency : new List<String>{
        'Minutes',
        'Hours',
        'Days',
        'Weeks',
        'Months'
      }
    )
      result.frequencies.add(new Option(frequency, frequency));
    result.schedules = getSchedulesInternal(key);
    result.backlogCount = [
      SELECT COUNT()
      FROM Integration_Work_Item__c
      WHERE
        Integration__c = :key
        AND Status__c IN ('Pending', 'Processing', 'Retry')
    ];
    result.activeLeaseCount = 0;
    for (ScheduleView schedule : result.schedules)
      if (schedule.executionState == 'Leased')
        result.activeLeaseCount++;
    List<CronTrigger> heartbeat = [
      SELECT State, NextFireTime
      FROM CronTrigger
      WHERE CronJobDetail.Name = 'Quickbridge Integration Heartbeat'
      LIMIT 1
    ];
    result.heartbeatStatus = heartbeat.isEmpty()
      ? 'Not scheduled'
      : heartbeat[0].State;
    result.nextHeartbeat = heartbeat.isEmpty()
      ? null
      : heartbeat[0].NextFireTime;
    return result;
  }

  @AuraEnabled(cacheable=false)
  public static Preview previewSchedule(
    String sessionToken,
    Decimal frequencyValue,
    String frequencyType,
    Datetime fromTime
  ) {
    QuickbridgeAdminSecurity.requireSession(sessionToken);
    if (
      frequencyValue == null ||
      frequencyValue < 1 ||
      frequencyValue > 10000 ||
      !FREQUENCIES.contains(frequencyType)
    )
      handled('Choose a valid schedule frequency.');
    Preview result = new Preview();
    Datetime cursor = fromTime == null ? System.now() : fromTime;
    for (Integer index = 0; index < 3; index++) {
      cursor = IntegrationScheduleDispatcher.calculateNextRun(
        frequencyValue,
        frequencyType,
        cursor
      );
      result.nextRuns.add(cursor);
    }
    return result;
  }

  @AuraEnabled(cacheable=false)
  public static List<ScheduleView> getSchedules(
    String sessionToken,
    String connectorKey
  ) {
    QuickbridgeAdminSecurity.requireSession(sessionToken);
    return getSchedulesInternal(requireConnector(connectorKey));
  }

  @AuraEnabled
  public static ScheduleView saveSchedule(
    String sessionToken,
    String requestJson
  ) {
    QuickbridgeAdminSecurity.requireRun();
    QuickbridgeAdminSecurity.requireSession(sessionToken);
    SaveRequest request;
    try {
      request = (SaveRequest) JSON.deserialize(requestJson, SaveRequest.class);
    } catch (Exception error) {
      handled('Schedule details are invalid.');
      return null;
    }
    String key = requireConnector(request.connectorKey);
    validateRequest(key, request);
    Integration_Connector__mdt connector = [
      SELECT Integration_Type__c, Provider_Label__c
      FROM Integration_Connector__mdt
      WHERE Connector_Key__c = :key
      LIMIT 1
    ];
    Scheduled_Integration_Job__c row;
    if (request.scheduleId == null) {
      String seed =
        key +
        ':' +
        request.sourceObject +
        ':' +
        request.direction +
        ':' +
        System.now().getTime();
      row = new Scheduled_Integration_Job__c(
        Logical_Job_Key__c = digest(seed),
        Created_By_User__c = UserInfo.getUserId(),
        Created_DateTime__c = System.now(),
        Status__c = 'Ready'
      );
    } else {
      List<Scheduled_Integration_Job__c> rows = [
        SELECT Id, Logical_Job_Key__c, Status__c
        FROM Scheduled_Integration_Job__c
        WHERE
          Id = :request.scheduleId
          AND Integration_Type__c = :connector.Integration_Type__c
          AND Status__c != 'Deleted'
        LIMIT 1
        FOR UPDATE
      ];
      if (rows.isEmpty())
        handled('The selected schedule no longer exists.');
      row = rows[0];
    }
    row.Integration_Type__c = connector.Integration_Type__c;
    row.Source_Object__c = request.sourceObject;
    row.Direction__c = request.direction;
    row.Frequency_Value__c = request.frequencyValue;
    row.Frequency_Type__c = request.frequencyType;
    row.Scheduler_Name__c = String.isBlank(request.schedulerName)
      ? connector.Provider_Label__c + ' - ' + request.sourceObject
      : request.schedulerName.left(80);
    row.Next_Run_At__c = IntegrationScheduleDispatcher.calculateNextRun(
      request.frequencyValue,
      request.frequencyType,
      System.now()
    );
    row.Lease_Token__c = null;
    row.Lease_Expires_At__c = null;
    Database.SaveResult saved = row.Id == null
      ? Database.insert(row, false)
      : Database.update(row, false);
    if (!saved.isSuccess())
      handled(
        'The schedule could not be saved: ' + saved.getErrors()[0].getMessage()
      );
    if (row.Id == null)
      row.Id = saved.getId();
    QuickbridgeAdminSecurity.audit(
      request.scheduleId == null ? 'SCHEDULE_CREATE' : 'SCHEDULE_UPDATE',
      key,
      'Success',
      row.Scheduler_Name__c,
      row.Id
    );
    return getSchedule(row.Id);
  }

  @AuraEnabled
  public static void setScheduleState(
    String sessionToken,
    Id scheduleId,
    String requestedState
  ) {
    QuickbridgeAdminSecurity.requireRun();
    QuickbridgeAdminSecurity.requireSession(sessionToken);
    if (
      scheduleId == null ||
      !new Set<String>{ 'Paused', 'Ready' }.contains(requestedState)
    )
      handled('Unsupported schedule state.');
    List<Scheduled_Integration_Job__c> rows = [
      SELECT Id, Status__c, Integration_Type__c, Next_Run_At__c
      FROM Scheduled_Integration_Job__c
      WHERE Id = :scheduleId AND Status__c != 'Deleted'
      LIMIT 1
      FOR UPDATE
    ];
    if (rows.isEmpty())
      handled('The selected schedule no longer exists.');
    rows[0].Status__c = requestedState;
    rows[0].Next_Run_At__c = requestedState == 'Ready'
      ? System.now()
      : rows[0].Next_Run_At__c;
    rows[0].Lease_Token__c = null;
    rows[0].Lease_Expires_At__c = null;
    Database.update(rows[0], false);
    QuickbridgeAdminSecurity.audit(
      'SCHEDULE_STATE',
      connectorForIntegrationType(rows[0].Integration_Type__c),
      'Success',
      requestedState,
      scheduleId
    );
  }

  @AuraEnabled
  public static void deleteSchedule(String sessionToken, Id scheduleId) {
    QuickbridgeAdminSecurity.requireRun();
    QuickbridgeAdminSecurity.requireSession(sessionToken);
    if (scheduleId == null)
      handled('Schedule is required.');
    List<Scheduled_Integration_Job__c> rows = [
      SELECT Id, Integration_Type__c
      FROM Scheduled_Integration_Job__c
      WHERE Id = :scheduleId AND Status__c != 'Deleted'
      LIMIT 1
      FOR UPDATE
    ];
    if (rows.isEmpty())
      handled('The selected schedule no longer exists.');
    rows[0].Status__c = 'Deleted';
    rows[0].Deleted_DateTime__c = System.now();
    rows[0].Lease_Token__c = null;
    rows[0].Lease_Expires_At__c = null;
    Database.update(rows[0], false);
    QuickbridgeAdminSecurity.audit(
      'SCHEDULE_DELETE',
      connectorForIntegrationType(rows[0].Integration_Type__c),
      'Success',
      null,
      scheduleId
    );
  }

  @AuraEnabled(cacheable=false)
  public static List<RecentRun> getRecentRuns(
    String sessionToken,
    Id scheduleId
  ) {
    QuickbridgeAdminSecurity.requireSession(sessionToken);
    List<RecentRun> result = new List<RecentRun>();
    for (Integration_Run__c item : [
      SELECT
        Id,
        Started_At__c,
        Requested_At__c,
        Completed_At__c,
        Status__c,
        Processed_Count__c,
        Successful_Count__c,
        Failed_Count__c,
        Skipped_Count__c,
        Message__c
      FROM Integration_Run__c
      WHERE Scheduled_Job__c = :scheduleId
      ORDER BY Requested_At__c DESC
      LIMIT 10
    ]) {
      RecentRun run = new RecentRun();
      run.id = item.Id;
      run.runAt = item.Started_At__c == null
        ? item.Requested_At__c
        : item.Started_At__c;
      run.completedAt = item.Completed_At__c;
      run.status = item.Status__c;
      run.processed = integerValue(item.Processed_Count__c);
      run.succeeded = integerValue(item.Successful_Count__c);
      run.failed = integerValue(item.Failed_Count__c);
      run.skipped = integerValue(item.Skipped_Count__c);
      run.durationMs = item.Completed_At__c == null ||
        run.runAt == null
        ? null
        : item.Completed_At__c.getTime() - run.runAt.getTime();
      run.message = IntegrationErrorLogService.sanitizeForUser(item.Message__c);
      result.add(run);
    }
    if (result.isEmpty()) {
      Scheduled_Integration_Job__c schedule = [
        SELECT Source_Object__c, Integration_Type__c
        FROM Scheduled_Integration_Job__c
        WHERE Id = :scheduleId
        LIMIT 1
      ];
      String connectorKey = connectorForIntegrationType(
        schedule.Integration_Type__c
      );
      for (Integration_Work_Item__c item : [
        SELECT Id, Status__c, Last_Attempt_At__c, Completed_At__c, Last_Error__c
        FROM Integration_Work_Item__c
        WHERE
          Integration__c = :connectorKey
          AND Source_Object__c = :schedule.Source_Object__c
        ORDER BY Last_Attempt_At__c DESC NULLS LAST
        LIMIT 10
      ]) {
        RecentRun run = new RecentRun();
        run.id = item.Id;
        run.runAt = item.Last_Attempt_At__c;
        run.completedAt = item.Completed_At__c;
        run.status = item.Status__c;
        run.processed = 0;
        run.succeeded = 0;
        run.failed = 0;
        run.skipped = 0;
        run.message = IntegrationErrorLogService.sanitizeForUser(
          item.Last_Error__c
        );
        result.add(run);
      }
    }
    return result;
  }

  private static List<ScheduleView> getSchedulesInternal(String key) {
    String integrationType = [
      SELECT Integration_Type__c
      FROM Integration_Connector__mdt
      WHERE Connector_Key__c = :key
      LIMIT 1
    ]
    .Integration_Type__c;
    List<ScheduleView> result = new List<ScheduleView>();
    for (Scheduled_Integration_Job__c row : [
      SELECT
        Id,
        Scheduler_Name__c,
        Source_Object__c,
        Direction__c,
        Status__c,
        Frequency_Value__c,
        Frequency_Type__c,
        Next_Run_At__c,
        Last_Run_At__c,
        Last_Error__c,
        Created_DateTime__c,
        Created_By_User__r.Name,
        Lease_Expires_At__c,
        Processor_Job_Id__c
      FROM Scheduled_Integration_Job__c
      WHERE Integration_Type__c = :integrationType AND Status__c != 'Deleted'
      ORDER BY Created_DateTime__c DESC
      LIMIT 100
    ])
      result.add(toView(row));
    return result;
  }

  private static ScheduleView getSchedule(Id scheduleId) {
    Scheduled_Integration_Job__c row = [
      SELECT
        Id,
        Scheduler_Name__c,
        Source_Object__c,
        Direction__c,
        Status__c,
        Frequency_Value__c,
        Frequency_Type__c,
        Next_Run_At__c,
        Last_Run_At__c,
        Last_Error__c,
        Created_DateTime__c,
        Created_By_User__r.Name,
        Lease_Expires_At__c,
        Processor_Job_Id__c
      FROM Scheduled_Integration_Job__c
      WHERE Id = :scheduleId
      LIMIT 1
    ];
    return toView(row);
  }

  private static ScheduleView toView(Scheduled_Integration_Job__c row) {
    ScheduleView view = new ScheduleView();
    view.id = row.Id;
    view.name = row.Scheduler_Name__c;
    view.sourceObject = row.Source_Object__c;
    view.direction = row.Direction__c;
    view.status = row.Status__c;
    view.frequencyValue = row.Frequency_Value__c;
    view.frequencyType = row.Frequency_Type__c;
    view.nextRun = row.Next_Run_At__c;
    view.lastRun = row.Last_Run_At__c;
    view.lastError = IntegrationErrorLogService.sanitizeForUser(
      row.Last_Error__c
    );
    view.createdAt = row.Created_DateTime__c;
    view.createdBy = row.Created_By_User__r == null
      ? 'System'
      : row.Created_By_User__r.Name;
    view.leaseExpiresAt = row.Lease_Expires_At__c;
    view.processorJobId = row.Processor_Job_Id__c;
    view.executionState = (row.Status__c == 'Claimed' ||
      row.Status__c == 'Running')
      ? 'Leased'
      : row.Status__c;
    return view;
  }

  private static void validateRequest(String key, SaveRequest request) {
    if (
      request == null ||
      request.frequencyValue == null ||
      request.frequencyValue < 1 ||
      request.frequencyValue > 10000 ||
      !FREQUENCIES.contains(request.frequencyType)
    )
      handled('Choose a valid schedule frequency.');
    if (
      String.isBlank(request.sourceObject) ||
      String.isBlank(request.direction) ||
      !DIRECTIONS.contains(request.direction)
    )
      handled('Choose a supported object and direction.');
    Integer validCount = [
      SELECT COUNT()
      FROM Integration_Operation__mdt
      WHERE
        Connector_Key__c = :key
        AND Active__c = TRUE
        AND Salesforce_Object__c = :request.sourceObject
    ];
    if (validCount == 0)
      handled('The selected object is not enabled for this connector.');
  }

  private static String requireConnector(String connectorKey) {
    String key = String.isBlank(connectorKey)
      ? null
      : connectorKey.trim().toLowerCase();
    List<Integration_Connector__mdt> rows = [
      SELECT Connector_Key__c, Has_Scheduler__c
      FROM Integration_Connector__mdt
      WHERE Connector_Key__c = :key AND Enabled__c = TRUE
      LIMIT 1
    ];
    if (rows.isEmpty() || !rows[0].Has_Scheduler__c)
      handled('Scheduling is not enabled for this connector.');
    return key;
  }
  private static String connectorForIntegrationType(String integrationType) {
    List<Integration_Connector__mdt> rows = [
      SELECT Connector_Key__c
      FROM Integration_Connector__mdt
      WHERE Integration_Type__c = :integrationType
      LIMIT 1
    ];
    return rows.isEmpty()
      ? integrationType.toLowerCase()
      : rows[0].Connector_Key__c;
  }
  private static String labelForObject(String apiName) {
    Schema.SObjectType typeValue = Schema.getGlobalDescribe().get(apiName);
    return typeValue == null ? apiName : typeValue.getDescribe().getLabel();
  }
  private static String digest(String value) {
    return EncodingUtil.convertToHex(
        Crypto.generateDigest('SHA-256', Blob.valueOf(value))
      )
      .left(80);
  }
  private static Integer integerValue(Decimal value) {
    return value == null ? 0 : value.intValue();
  }
  private static void handled(String message) {
    AuraHandledException error = new AuraHandledException(message);
    error.setMessage(message);
    throw error;
  }
}