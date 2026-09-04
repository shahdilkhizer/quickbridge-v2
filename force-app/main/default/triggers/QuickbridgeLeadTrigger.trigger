trigger QuickbridgeLeadTrigger on Lead (after insert, after update, after delete) {
  IntegrationEventApi.dispatch(
    'Lead',
    Trigger.isInsert ? 'afterInsert' : (Trigger.isUpdate ? 'afterUpdate' : 'afterDelete'),
    Trigger.isDelete ? Trigger.old : Trigger.new,
    Trigger.oldMap
  );
}