trigger QuickbridgeQuoteTrigger on Quote (after insert, after update, after delete) {
  IntegrationEventApi.dispatch('Quote', Trigger.isInsert ? 'afterInsert' : (Trigger.isUpdate ? 'afterUpdate' : 'afterDelete'), Trigger.isDelete ? Trigger.old : Trigger.new, Trigger.oldMap);
}