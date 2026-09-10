global without sharing class CarrierTrackingScheduler implements Schedulable, Database.AllowsCallouts {
  private String connectorKey;

  global CarrierTrackingScheduler() { }

  global CarrierTrackingScheduler(String connectorKey) {
    this.connectorKey = CarrierOperationCatalog.normalize(connectorKey);
  }

  global void execute(SchedulableContext context) {
    CarrierOperationModels.Result result = CarrierTrackingService.synchronizeNext(connectorKey);
    if (result.success != true) {
      throw new CarrierTrackingSchedulerException(
        result.errorSummary == null ? result.message : result.errorSummary
      );
    }
  }

  global class CarrierTrackingSchedulerException extends Exception {}
}