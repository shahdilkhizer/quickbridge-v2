trigger QuickbridgePurchaseOrderTrigger on Purchase_Order__c (after insert, after update, after delete) {
  IntegrationEventApi.dispatch('Purchase_Order__c', Trigger.isInsert ? 'afterInsert' : (Trigger.isUpdate ? 'afterUpdate' : 'afterDelete'), Trigger.isDelete ? Trigger.old : Trigger.new, Trigger.oldMap);
}