trigger QuickbridgeCreditMemoTrigger on Credit_Memo__c (after insert, after update, after delete) {
  IntegrationEventApi.dispatch('Credit_Memo__c', Trigger.isInsert ? 'afterInsert' : (Trigger.isUpdate ? 'afterUpdate' : 'afterDelete'), Trigger.isDelete ? Trigger.old : Trigger.new, Trigger.oldMap);
}