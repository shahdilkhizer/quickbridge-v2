trigger QuickbridgeItemSalesTaxTrigger on Item_Sales_Tax__c (after insert, after update, after delete) {
  IntegrationEventApi.dispatch('Item_Sales_Tax__c', Trigger.isInsert ? 'afterInsert' : (Trigger.isUpdate ? 'afterUpdate' : 'afterDelete'), Trigger.isDelete ? Trigger.old : Trigger.new, Trigger.oldMap);
}