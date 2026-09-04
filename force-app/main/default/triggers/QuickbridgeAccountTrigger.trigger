trigger QuickbridgeAccountTrigger on Account (after insert, after update, after delete) {
  IntegrationEventApi.dispatch(
    'Account',
    Trigger.isInsert ? 'afterInsert' : (Trigger.isUpdate ? 'afterUpdate' : 'afterDelete'),
    Trigger.isDelete ? Trigger.old : Trigger.new,
    Trigger.oldMap
  );
}