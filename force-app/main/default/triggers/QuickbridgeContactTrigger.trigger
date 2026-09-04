trigger QuickbridgeContactTrigger on Contact (after insert, after update, after delete) {
  IntegrationEventApi.dispatch(
    'Contact',
    Trigger.isInsert ? 'afterInsert' : (Trigger.isUpdate ? 'afterUpdate' : 'afterDelete'),
    Trigger.isDelete ? Trigger.old : Trigger.new,
    Trigger.oldMap
  );
}