public with sharing class ConnectorScheduleService {
  @TestVisible
  private static Boolean leaseRefreshCapacityOverride;

  public static Boolean hasLeaseRefreshCapacity() {
    if (Test.isRunningTest() && leaseRefreshCapacityOverride != null) {
      return leaseRefreshCapacityOverride;
    }
    return Limits.getDmlStatements() < Limits.getLimitDmlStatements() &&
      Limits.getQueries() < Limits.getLimitQueries();
  }

  public static Boolean markRunning(
    Id scheduleId,
    String leaseToken,
    Id asyncJobId
  ) {
    return markRunning(scheduleId, leaseToken, asyncJobId, null);
  }

  public static Boolean markRunning(
    Id scheduleId,
    String leaseToken,
    Id asyncJobId,
    Integer deferredSeconds
  ) {
    if (scheduleId == null || String.isBlank(leaseToken)) {
      return false;
    }

    List<Scheduled_Integration_Job__c> jobs = [
      SELECT Id, Status__c, Lease_Token__c, Pending_Run_Key__c
      FROM Scheduled_Integration_Job__c
      WHERE Id = :scheduleId
      LIMIT 1
      FOR UPDATE
    ];
    if (jobs.isEmpty()) {
      return false;
    }

    Scheduled_Integration_Job__c job = jobs[0];
    if (
      (job.Status__c != 'Claimed' && job.Status__c != 'Running') ||
      job.Lease_Token__c != leaseToken
    ) {
      return false;
    }

    job.Status__c = 'Running';
    job.Pending_Run_Key__c = null;
    Datetime nowValue = Datetime.now();
    job.Lease_Expires_At__c = deferredSeconds == null
      ? IntegrationScheduleDispatcher.leaseExpiresAt(nowValue)
      : nowValue.addSeconds(
          Math.max(600, Math.min(86400, deferredSeconds + 300))
        );
    if (asyncJobId != null) {
      job.Processor_Job_Id__c = String.valueOf(asyncJobId);
    }
    update job;
    return true;
  }

  public static void complete(
    Id scheduleId,
    String leaseToken,
    ConnectorExecutionResult result
  ) {
    if (result == null) {
      completeFailure(
        scheduleId,
        leaseToken,
        'Connector execution returned no result.'
      );
      return;
    }
    IntegrationRunService.completeForSchedule(scheduleId, result);
    if (result.hasFailures()) {
      IntegrationScheduleDispatcher.completeRun(
        scheduleId,
        leaseToken,
        false,
        String.isBlank(result.errorSummary)
          ? 'Connector execution failed.'
          : result.errorSummary.left(32768)
      );
      return;
    }
    IntegrationScheduleDispatcher.completeRun(
      scheduleId,
      leaseToken,
      true,
      null
    );
  }

  public static void completeSuccess(Id scheduleId, String leaseToken) {
    if (scheduleId == null || String.isBlank(leaseToken)) {
      return;
    }
    ConnectorExecutionResult result = ConnectorExecutionResult.success();
    IntegrationRunService.completeForSchedule(scheduleId, result);
    IntegrationScheduleDispatcher.completeRun(
      scheduleId,
      leaseToken,
      true,
      null
    );
  }

  public static void completeFailure(
    Id scheduleId,
    String leaseToken,
    String errorMessage
  ) {
    if (scheduleId == null || String.isBlank(leaseToken)) {
      return;
    }
    ConnectorExecutionResult result = ConnectorExecutionResult.failed(
      errorMessage,
      false,
      null
    );
    IntegrationRunService.completeForSchedule(scheduleId, result);
    IntegrationScheduleDispatcher.completeRun(
      scheduleId,
      leaseToken,
      false,
      String.isBlank(errorMessage)
        ? 'Connector execution failed.'
        : errorMessage.left(32768)
    );
  }
}