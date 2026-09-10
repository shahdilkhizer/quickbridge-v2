import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import syncToProvider from '@salesforce/apex/QuickbridgeRecordSyncController.syncToProvider';

export default class QuickbridgeSyncToQbo extends LightningElement {
    @api recordId;

    @api async invoke() {
        if (!this.recordId) {
            this.showToast('Error', 'Record ID is missing.', 'error');
            return;
        }

        try {
            const result = await syncToProvider({ recordId: this.recordId, connectorKey: 'qbo' });
            if (result.success) {
                this.showToast('Success', result.message, 'success');
                await notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
            } else {
                this.showToast('Sync Failed', result.message, 'error');
            }
        } catch (error) {
            const errorMsg = error?.body?.message || error?.message || 'Sync failed due to an unexpected error.';
            this.showToast('Error', errorMsg, 'error');
        }
    }

    showToast(title, message, variant) {
        this.dispatchEvent(
            new ShowToastEvent({
                title,
                message,
                variant
            })
        );
    }
}