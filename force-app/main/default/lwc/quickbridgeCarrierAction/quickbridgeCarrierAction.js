import { LightningElement, api } from 'lwc';
import { CloseActionScreenEvent } from 'lightning/actions';
import availableProviders from '@salesforce/apex/QuickbridgeCapabilityController.availableProviders';
import executeCarrierOperation from '@salesforce/apex/QuickbridgeCapabilityController.executeCarrierOperation';

const OPERATIONS = [
  ['Validate address', 'validateAddress'], ['Quote rates', 'quoteRates'],
  ['Create shipment', 'createShipment'], ['Recover label', 'recoverLabel'],
  ['Create return label', 'createReturnLabel'], ['Void shipment', 'voidShipment'],
  ['Refresh tracking', 'tracking']
].map(([label, value]) => ({ label, value }));

export default class QuickbridgeCarrierAction extends LightningElement {
  @api recordId;
  providers = [];
  provider;
  operation = 'quoteRates';
  operations = OPERATIONS;
  loading = true;
  message;
  error = false;

  connectedCallback() {
    availableProviders({ capabilityKey: 'carrier.operation' })
      .then((rows) => {
        this.providers = (rows || []).map((row) => ({ label: row.label, value: row.key }));
        this.provider = this.providers[0]?.value;
      })
      .catch((failure) => this.setError(failure))
      .finally(() => { this.loading = false; });
  }

  get disabled() { return this.loading || !this.provider || !this.operation || !this.recordId; }
  get messageClass() { return this.error ? 'slds-notify slds-notify_alert slds-alert_error slds-m-bottom_small' : 'slds-notify slds-notify_alert slds-theme_success slds-m-bottom_small'; }
  handleProvider(event) { this.provider = event.detail.value; }
  handleOperation(event) { this.operation = event.detail.value; }
  close() { this.dispatchEvent(new CloseActionScreenEvent()); }

  async run() {
    this.loading = true;
    this.message = null;
    try {
      const payload = {
        idempotencyKey: `${this.provider}:${this.operation}:${this.recordId}`
      };
      const result = await executeCarrierOperation({
        connectorKey: this.provider,
        operation: this.operation,
        sourceRecordId: this.recordId,
        payloadJson: JSON.stringify(payload)
      });
      if (result?.failedCount || result?.errorSummary) throw new Error(result.errorSummary || 'Carrier action failed.');
      this.error = false;
      this.message = 'Carrier action completed successfully.';
    } catch (failure) {
      this.setError(failure);
    } finally {
      this.loading = false;
    }
  }

  setError(failure) {
    this.error = true;
    this.message = failure?.body?.message || failure?.message || 'Carrier action failed.';
  }
}