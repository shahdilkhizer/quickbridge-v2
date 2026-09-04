trigger QuickbridgeEventTrigger on Event (after insert, after update, after delete) {
  IntegrationEventApi.dispatch(
    'Event',
    Trigger.isInsert ? 'afterInsert' : (Trigger.isUpdate ? 'afterUpdate' : 'afterDelete'),
    Trigger.isDelete ? Trigger.old : Trigger.new,
    Trigger.oldMap
  );
}