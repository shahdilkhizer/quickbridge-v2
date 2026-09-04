trigger QuickbridgeOrderItemTrigger on OrderItem (after insert, after update, after delete) {
  IntegrationEventApi.dispatch('OrderItem', Trigger.isInsert ? 'afterInsert' : (Trigger.isUpdate ? 'afterUpdate' : 'afterDelete'), Trigger.isDelete ? Trigger.old : Trigger.new, Trigger.oldMap);
}