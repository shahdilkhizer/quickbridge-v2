trigger QuickbridgeProductTrigger on Product2 (after insert, after update, after delete) {
  IntegrationEventApi.dispatch('Product2', Trigger.isInsert ? 'afterInsert' : (Trigger.isUpdate ? 'afterUpdate' : 'afterDelete'), Trigger.isDelete ? Trigger.old : Trigger.new, Trigger.oldMap);
}