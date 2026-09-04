trigger QuickbridgePurchaseOrderLineTrigger on Purchase_Order_Line__c (after insert, after update, after delete) {
  IntegrationEventApi.dispatch('Purchase_Order_Line__c', Trigger.isInsert ? 'afterInsert' : (Trigger.isUpdate ? 'afterUpdate' : 'afterDelete'), Trigger.isDelete ? Trigger.old : Trigger.new, Trigger.oldMap);
}