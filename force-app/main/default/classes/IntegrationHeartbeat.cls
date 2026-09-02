global without sharing class IntegrationHeartbeat implements Schedulable {
  public static final String JOB_NAME = 'Quickbridge Integration Heartbeat';
  private static final Integer INTERVAL_MINUTES = 1;
  @TestVisible private static Boolean suppressRescheduleForTests = false;

  global void execute(SchedulableContext context) {
    try {
      Integer available = Limits.getLimitQueueableJobs() - Limits.getQueueableJobs();
      Integer budget = Math.min(IntegrationScheduleDispatcher.MAX_DISPATCH_SIZE, available);
      Integer scheduledCount = IntegrationScheduleDispatcher.dispatchDue(budget);
      Integer remaining = Math.max(0, budget - scheduledCount);
      IntegrationWorkDispatcher.dispatchDueWork(remaining);
    } finally {
      if (context != null && context.getTriggerId() != null) {
        System.abortJob(context.getTriggerId());
      }
      if (!(Test.isRunningTest() && suppressRescheduleForTests)) scheduleNextRun();
    }
  }

  @AuraEnabled
  public static void ensureScheduled() {
    List<CronTrigger> existing = [
      SELECT Id
      FROM CronTrigger
      WHERE
        CronJobDetail.Name = :JOB_NAME
        AND State NOT IN ('DELETED', 'COMPLETE', 'ERROR')
      LIMIT 1
    ];
    if (existing.isEmpty()) {
      scheduleNextRun();
    }
  }

  private static void scheduleNextRun() {
    Datetime nextRun = System.now().addMinutes(INTERVAL_MINUTES);
    String cron = nextRun.format('s m H d M ? yyyy');
    System.schedule(JOB_NAME, cron, new IntegrationHeartbeat());
  }
}