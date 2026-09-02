import { LightningElement, api } from 'lwc';
import { CloseActionScreenEvent } from 'lightning/actions';
import availableProviders from '@salesforce/apex/QuickbridgeCapabilityController.availableProviders';
import submitPayment from '@salesforce/apex/QuickbridgeCapabilityController.submitPayment';

export default class QuickbridgePaymentAction extends LightningElement {
  @api recordId;
  providers = [];
  provider;
  amount;
  currency = 'USD';
  loading = true;
  message;
  error = false;

  connectedCallback() {
    availableProviders({ capabilityKey: 'payment.checkout' })
      .then((rows) => {
        this.providers = (rows || []).map((row) => ({ label: row.label, value: row.key }));
        this.provider = this.providers[0]?.value;
      })
      .catch((failure) => this.setError(failure))
      .finally(() => { this.loading = false; });
  }

  get disabled() { return this.loading || !this.provider || !this.recordId || !(Number(this.amount) > 0); }
  get messageClass() { return this.error ? 'slds-notify slds-notify_alert slds-alert_error slds-m-bottom_small' : 'slds-notify slds-notify_alert slds-theme_success slds-m-bottom_small'; }
  handleProvider(event) { this.provider = event.detail.value; }
  handleAmount(event) { this.amount = event.detail.value; }
  handleCurrency(event) { this.currency = event.detail.value; }
  close() { this.dispatchEvent(new CloseActionScreenEvent()); }

  async initialize() {
    this.loading = true;
    this.message = null;
    try {
      const result = await submitPayment({
        connectorKey: this.provider,
        sourceRecordId: this.recordId,
        amount: Number(this.amount),
        currencyCode: this.currency,
        providerToken: null,
        idempotencyKey: `${this.provider}:${this.recordId}:${this.amount}:${this.currency}`,
        attributesJson: '{}',
        action: 'initialize'
      });
      if (!result?.successful) throw new Error(result?.errorSummary || 'Secure checkout could not be initialized.');
      this.error = false;
      this.message = result.requiresAction
        ? 'The provider requires an additional secure browser step.'
        : `Payment session ${result.providerReference || ''} initialized.`;
    } catch (failure) {
      this.setError(failure);
    } finally {
      this.loading = false;
    }
  }

  setError(failure) {
    this.error = true;
    this.message = failure?.body?.message || failure?.message || 'Payment setup failed.';
  }
}