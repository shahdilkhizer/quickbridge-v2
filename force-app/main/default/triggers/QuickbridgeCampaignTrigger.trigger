trigger QuickbridgeCampaignTrigger on Campaign (after insert, after update, after delete) {
  IntegrationEventApi.dispatch(
    'Campaign',
    Trigger.isInsert ? 'afterInsert' : (Trigger.isUpdate ? 'afterUpdate' : 'afterDelete'),
    Trigger.isDelete ? Trigger.old : Trigger.new,
    Trigger.oldMap
  );
}