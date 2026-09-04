trigger QuickbridgeCampaignMemberTrigger on CampaignMember (after insert, after update, after delete) {
  IntegrationEventApi.dispatch(
    'CampaignMember',
    Trigger.isInsert ? 'afterInsert' : (Trigger.isUpdate ? 'afterUpdate' : 'afterDelete'),
    Trigger.isDelete ? Trigger.old : Trigger.new,
    Trigger.oldMap
  );
}