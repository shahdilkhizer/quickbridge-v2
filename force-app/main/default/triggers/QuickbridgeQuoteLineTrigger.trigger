trigger QuickbridgeQuoteLineTrigger on QuoteLineItem (after insert, after update, after delete) {
  IntegrationEventApi.dispatch('QuoteLineItem', Trigger.isInsert ? 'afterInsert' : (Trigger.isUpdate ? 'afterUpdate' : 'afterDelete'), Trigger.isDelete ? Trigger.old : Trigger.new, Trigger.oldMap);
}