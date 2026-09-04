trigger QuickbridgeOrderTrigger on Order (after insert, after update, after delete) {
  IntegrationEventApi.dispatch('Order', Trigger.isInsert ? 'afterInsert' : (Trigger.isUpdate ? 'afterUpdate' : 'afterDelete'), Trigger.isDelete ? Trigger.old : Trigger.new, Trigger.oldMap);
}