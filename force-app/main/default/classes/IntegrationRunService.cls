/**
 * Persists execution telemetry for scheduled and administrator-requested runs.
 * This internal service intentionally runs without sharing because the scheduler
 * executes as a system process. User-facing access is enforced by its controllers.
 */
public without sharing class IntegrationRunService {
  public static final String STATUS_REQUESTED = 'Requested';
  public static final String STATUS_QUEUED = 'Queued';
  public static final String STATUS_RUNNING = 'Running';
  public static final String STATUS_COMPLETED = 'Completed';
  public static final String STATUS_PARTIAL = 'Partial';
  public static final String STATUS_FAILED = 'Failed';

  public class ManualRunRequest {
    public String groupKey;
    public Datetime requestedAt;
    public Integer scheduleCount;
    public String status;
  }

  public class RunGroupSnapshot {
    public String groupKey;
    public String status;
    public Datetime requestedAt;
    public Datetime startedAt;
    public Datetime completedAt;
    public Integer requestedCount = 0;
    public Integer processedCount = 0;
    public Integer successfulCount = 0;
    public Integer failedCount = 0;
    public Integer skippedCount = 0;
    public String message;
    public List<Integration_Run__c> runs = new List<Integration_Run__c>();
  }

  public static ManualRunRequest requestManualRuns(
    String connectorKey,
    String integrationType
  ) {
    Datetime requestedAt = System.now();
    List<Scheduled_Integration_Job__c> schedules = [
      SELECT Id, Status__c, Pending_Run_Key__c
      FROM Scheduled_Integration_Job__c
      WHERE
        Integration_Type__c = :integrationType
        AND Status__c IN ('Ready', 'Active', 'Failed')
      FOR UPDATE
    ];
    if (schedules.isEmpty()) {
      fail('Create at least one schedule before running this connector.');
    }
    for (Scheduled_Integration_Job__c scheduleRow : schedules) {
      if (String.isNotBlank(scheduleRow.Pending_Run_Key__c)) {
        fail('A manual run is already pending or active for this connector.');
      }
    }

    String groupKey = newKey('group:' + connectorKey);
    List<Integration_Run__c> runs = new List<Integration_Run__c>();
    for (Scheduled_Integration_Job__c scheduleRow : schedules) {
      String runKey = newKey(groupKey + ':' + scheduleRow.Id);
      scheduleRow.Pending_Run_Key__c = runKey;
      scheduleRow.Status__c = 'Ready';
      scheduleRow.Next_Run_At__c = requestedAt;
      scheduleRow.Lease_Token__c = null;
      scheduleRow.Lease_Expires_At__c = null;
      runs.add(
        new Integration_Run__c(
          Run_Key__c = runKey,
          Run_Group_Key__c = groupKey,
          Connector_Key__c = connectorKey,
          Trigger_Source__c = 'Manual',
          Scheduled_Job__c = scheduleRow.Id,
          Status__c = STATUS_QUEUED,
          Requested_At__c = requestedAt,
          Requested_By__c = UserInfo.getUserId()
        )
      );
    }
    insert runs;
    update schedules;

    ManualRunRequest result = new ManualRunRequest();
    result.groupKey = groupKey;
    result.requestedAt = requestedAt;
    result.scheduleCount = schedules.size();
    result.status = STATUS_REQUESTED;
    return result;
  }

  public static void markQueued(
    Id scheduleId,
    String pendingRunKey,
    Id asyncJobId
  ) {
    if (scheduleId == null || String.isBlank(pendingRunKey))
      return;
    List<Integration_Run__c> rows = [
      SELECT Id, Status__c
      FROM Integration_Run__c
      WHERE Run_Key__c = :pendingRunKey AND Scheduled_Job__c = :scheduleId
      LIMIT 1
    ];
    if (rows.isEmpty())
      return;
    rows[0].Status__c = STATUS_QUEUED;
    rows[0].Async_Job_Id__c = asyncJobId == null
      ? null
      : String.valueOf(asyncJobId);
    Database.update(rows[0], false);
  }

  public static void markQueued(Map<String, Id> asyncJobByRunKey) {
    if (asyncJobByRunKey == null || asyncJobByRunKey.isEmpty())
      return;
    List<Integration_Run__c> updates = new List<Integration_Run__c>();
    for (Integration_Run__c row : [
      SELECT Id, Run_Key__c
      FROM Integration_Run__c
      WHERE Run_Key__c IN :asyncJobByRunKey.keySet()
    ]) {
      Id asyncJobId = asyncJobByRunKey.get(row.Run_Key__c);
      row.Status__c = STATUS_QUEUED;
      row.Async_Job_Id__c = asyncJobId == null
        ? null
        : String.valueOf(asyncJobId);
      updates.add(row);
    }
    if (!updates.isEmpty())
      Database.update(updates, false);
  }

  public static void failQueuedRun(String runKey, String message) {
    if (String.isBlank(runKey))
      return;
    List<Integration_Run__c> rows = [
      SELECT Id
      FROM Integration_Run__c
      WHERE Run_Key__c = :runKey
      LIMIT 1
    ];
    if (rows.isEmpty())
      return;
    rows[0].Status__c = STATUS_FAILED;
    rows[0].Started_At__c = System.now();
    rows[0].Completed_At__c = System.now();
    rows[0].Failed_Count__c = 1;
    rows[0].Processed_Count__c = 1;
    rows[0].Message__c = safeMessage(message);
    Database.update(rows[0], false);
  }

  public static void failQueuedRuns(Map<String, String> messageByRunKey) {
    if (messageByRunKey == null || messageByRunKey.isEmpty())
      return;
    List<Integration_Run__c> rows = [
      SELECT Id, Run_Key__c
      FROM Integration_Run__c
      WHERE Run_Key__c IN :messageByRunKey.keySet()
    ];
    Datetime completedAt = System.now();
    for (Integration_Run__c row : rows) {
      row.Status__c = STATUS_FAILED;
      row.Completed_At__c = completedAt;
      row.Failed_Count__c = 1;
      row.Message__c = safeMessage(messageByRunKey.get(row.Run_Key__c));
    }
    if (!rows.isEmpty())
      Database.update(rows, false);
  }

  public static Id startForSchedule(
    Id scheduleId,
    String connectorKey,
    String pendingRunKey,
    Id asyncJobId
  ) {
    Datetime nowValue = System.now();
    Integration_Run__c runRow;
    if (String.isNotBlank(pendingRunKey)) {
      List<Integration_Run__c> existing = [
        SELECT Id, Status__c, Started_At__c, Async_Job_Id__c
        FROM Integration_Run__c
        WHERE Run_Key__c = :pendingRunKey AND Scheduled_Job__c = :scheduleId
        LIMIT 1
        FOR UPDATE
      ];
      if (!existing.isEmpty())
        runRow = existing[0];
    }
    if (runRow == null) {
      String runKey = newKey('scheduled:' + scheduleId);
      runRow = new Integration_Run__c(
        Run_Key__c = runKey,
        Run_Group_Key__c = runKey,
        Connector_Key__c = connectorKey,
        Trigger_Source__c = 'Scheduled',
        Scheduled_Job__c = scheduleId,
        Status__c = STATUS_RUNNING,
        Requested_At__c = nowValue,
        Requested_By__c = UserInfo.getUserId()
      );
    }
    runRow.Status__c = STATUS_RUNNING;
    runRow.Started_At__c = runRow.Started_At__c == null
      ? nowValue
      : runRow.Started_At__c;
    runRow.Async_Job_Id__c = asyncJobId == null
      ? runRow.Async_Job_Id__c
      : String.valueOf(asyncJobId);
    upsert runRow;
    return runRow.Id;
  }

  public static void updateAsyncJob(Id runId, Id asyncJobId) {
    if (runId == null || asyncJobId == null)
      return;
    Database.update(
      new Integration_Run__c(
        Id = runId,
        Async_Job_Id__c = String.valueOf(asyncJobId),
        Status__c = STATUS_RUNNING
      ),
      false
    );
  }

  public static void completeForSchedule(
    Id scheduleId,
    ConnectorExecutionResult executionResult
  ) {
    if (scheduleId == null)
      return;
    List<Integration_Run__c> rows = [
      SELECT Id, Status__c
      FROM Integration_Run__c
      WHERE
        Scheduled_Job__c = :scheduleId
        AND Status__c IN ('Requested', 'Queued', 'Running')
      LIMIT 1
      FOR UPDATE
    ];
    if (rows.isEmpty())
      return;
    ConnectorExecutionResult safeResult = executionResult == null
      ? ConnectorExecutionResult.failed(
          'Connector execution returned no result.',
          false,
          null
        )
      : executionResult;
    Integer processed = safeCount(safeResult.processedCount);
    Integer successful = safeCount(safeResult.successfulCount);
    Integer failed = safeCount(safeResult.failedCount);
    Integration_Run__c runRow = rows[0];
    runRow.Processed_Count__c = processed;
    runRow.Successful_Count__c = successful;
    runRow.Failed_Count__c = failed;
    runRow.Skipped_Count__c = Math.max(0, processed - successful - failed);
    runRow.Completed_At__c = System.now();
    runRow.Message__c = safeMessage(safeResult.errorSummary);
    runRow.Status__c = failed > 0 &&
      successful > 0
      ? STATUS_PARTIAL
      : (safeResult.hasFailures() ? STATUS_FAILED : STATUS_COMPLETED);
    Database.update(runRow, false);
  }

  public static RunGroupSnapshot getGroupSnapshot(String groupKey) {
    RunGroupSnapshot snapshot = new RunGroupSnapshot();
    snapshot.groupKey = groupKey;
    if (String.isBlank(groupKey))
      return snapshot;
    snapshot.runs = [
      SELECT
        Id,
        Run_Key__c,
        Run_Group_Key__c,
        Connector_Key__c,
        Trigger_Source__c,
        Scheduled_Job__c,
        Status__c,
        Requested_At__c,
        Started_At__c,
        Completed_At__c,
        Async_Job_Id__c,
        Processed_Count__c,
        Successful_Count__c,
        Failed_Count__c,
        Skipped_Count__c,
        Message__c
      FROM Integration_Run__c
      WHERE Run_Group_Key__c = :groupKey
      ORDER BY Requested_At__c, Id
      LIMIT 100
    ];
    if (snapshot.runs.isEmpty())
      return snapshot;
    snapshot.status = STATUS_COMPLETED;
    for (Integration_Run__c row : snapshot.runs) {
      snapshot.requestedCount++;
      snapshot.requestedAt = earlier(snapshot.requestedAt, row.Requested_At__c);
      snapshot.startedAt = earlier(snapshot.startedAt, row.Started_At__c);
      snapshot.completedAt = later(snapshot.completedAt, row.Completed_At__c);
      snapshot.processedCount += decimalCount(row.Processed_Count__c);
      snapshot.successfulCount += decimalCount(row.Successful_Count__c);
      snapshot.failedCount += decimalCount(row.Failed_Count__c);
      snapshot.skippedCount += decimalCount(row.Skipped_Count__c);
      if (String.isNotBlank(row.Message__c))
        snapshot.message = append(snapshot.message, row.Message__c);
      snapshot.status = aggregateStatus(snapshot.status, row.Status__c);
    }
    return snapshot;
  }

  private static String aggregateStatus(String current, String candidate) {
    Map<String, Integer> rankByStatus = new Map<String, Integer>{
      STATUS_COMPLETED => 0,
      STATUS_REQUESTED => 1,
      STATUS_QUEUED => 2,
      STATUS_RUNNING => 3,
      STATUS_PARTIAL => 4,
      STATUS_FAILED => 5
    };
    return rankByStatus.get(candidate) > rankByStatus.get(current)
      ? candidate
      : current;
  }

  private static String newKey(String seed) {
    return EncodingUtil.convertToHex(
      Crypto.generateDigest(
        'SHA-256',
        Blob.valueOf(
          seed + ':' + System.now().getTime() + ':' + Crypto.getRandomInteger()
        )
      )
    );
  }
  private static Integer safeCount(Integer value) {
    return value == null || value < 0 ? 0 : value;
  }
  private static Integer decimalCount(Decimal value) {
    return value == null || value < 0 ? 0 : value.intValue();
  }
  private static Datetime earlier(Datetime leftValue, Datetime rightValue) {
    return leftValue == null || (rightValue != null && rightValue < leftValue)
      ? rightValue
      : leftValue;
  }
  private static Datetime later(Datetime leftValue, Datetime rightValue) {
    return leftValue == null || (rightValue != null && rightValue > leftValue)
      ? rightValue
      : leftValue;
  }
  private static String append(String existing, String value) {
    String combined = String.isBlank(existing)
      ? value
      : existing + ' | ' + value;
    return combined.length() > 2000 ? combined.left(1997) + '...' : combined;
  }
  private static String safeMessage(String value) {
    String sanitized = IntegrationErrorLogService.sanitizeForUser(value);
    return String.isBlank(sanitized) ? null : sanitized.left(2000);
  }
  private static void fail(String message) {
    AuraHandledException error = new AuraHandledException(message);
    error.setMessage(message);
    throw error;
  }
}