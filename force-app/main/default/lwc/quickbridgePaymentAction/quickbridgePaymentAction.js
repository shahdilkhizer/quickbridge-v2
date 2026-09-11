import { LightningElement, api } from 'lwc';
import { CloseActionScreenEvent } from 'lightning/actions';
import availableProviders from '@salesforce/apex/QuickbridgeCapabilityController.availableProviders';
import createHostedPayment from '@salesforce/apex/QuickbridgeCapabilityController.createHostedPayment';

export default class QuickbridgePaymentAction extends LightningElement {
  @api recordId;
  providers = [];
  provider;
  loading = true;
  message;
  error = false;

  connectedCallback() {
    availableProviders({ capabilityKey: 'payment.hosted' })
      .then((rows) => {
        this.providers = (rows || []).map((row) => ({ label: row.label, value: row.key }));
        this.provider = this.providers[0]?.value;
      })
      .catch((failure) => this.setError(failure))
      .finally(() => { this.loading = false; });
  }

  get disabled() { return this.loading || !this.provider || !this.recordId; }
  get messageClass() { return this.error ? 'slds-notify slds-notify_alert slds-alert_error slds-m-bottom_small' : 'slds-notify slds-notify_alert slds-theme_success slds-m-bottom_small'; }
  handleProvider(event) { this.provider = event.detail.value; }
  close() { this.dispatchEvent(new CloseActionScreenEvent()); }

  async initialize() {
    this.loading = true;
    this.message = null;
    try {
      const result = await createHostedPayment({
        connectorKey: this.provider,
        sourceRecordId: this.recordId
      });
      if (!result?.successful) throw new Error(result?.errorSummary || 'Hosted payment could not be created.');
      this.error = false;
      if (result.launchMode === 'POST_FORM') {
        this.postHostedToken(result.hostedUrl, result.formToken);
      } else if (result.hostedUrl) {
        window.open(result.hostedUrl, '_blank', 'noopener,noreferrer');
      } else {
        throw new Error('The provider did not return a hosted payment URL.');
      }
      this.message = result.reusedExisting
        ? `Existing hosted payment ${result.providerReference || ''} opened.`
        : `Hosted payment ${result.providerReference || ''} created.`;
    } catch (failure) {
      this.setError(failure);
    } finally {
      this.loading = false;
    }
  }

  postHostedToken(url, token) {
    if (!url || !token) throw new Error('The hosted form token is unavailable.');
    const form = document.createElement('form');
    form.method = 'POST';
    form.action = url;
    form.target = '_blank';
    const input = document.createElement('input');
    input.type = 'hidden';
    input.name = 'token';
    input.value = token;
    form.appendChild(input);
    this.template.appendChild(form);
    form.submit();
    form.remove();
  }

  setError(failure) {
    this.error = true;
    this.message = failure?.body?.message || failure?.message || 'Payment setup failed.';
  }
}