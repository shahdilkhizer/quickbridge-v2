import { LightningElement, api } from 'lwc';
import { CloseActionScreenEvent } from 'lightning/actions';
import getActionContext from '@salesforce/apex/CarrierOperationController.getActionContext';
import prepareMutation from '@salesforce/apex/CarrierOperationController.prepareMutation';
import execute from '@salesforce/apex/CarrierOperationController.execute';
import applyValidatedAddress from '@salesforce/apex/CarrierOperationController.applyValidatedAddress';
import selectRateQuote from '@salesforce/apex/CarrierOperationController.selectRateQuote';

export default class QuickbridgeCarrierAction extends LightningElement {
  @api recordId;
  providers = [];
  definitions = [];
  shipments = [];
  provider;
  operation;
  shipmentId;
  loading = true;
  message;
  error = false;
  correctedAddress;
  rateQuotes = [];

  connectedCallback() {
    getActionContext({ sourceRecordId: this.recordId })
      .then((context) => {
        this.providers = (context?.providers || []).map((row) => ({ label: row.label, value: row.key }));
        this.definitions = context?.operations || [];
        this.shipments = context?.shipments || [];
        this.provider = this.providers[0]?.value;
        this.operation = this.operations[0]?.value;
      })
      .catch((failure) => this.setError(failure))
      .finally(() => { this.loading = false; });
  }

  get operations() {
    return this.definitions
      .filter((row) => row.connectorKey === this.provider)
      .map((row) => ({ label: row.label, value: row.operationKey }));
  }
  get selectedDefinition() {
    return this.definitions.find((row) => row.connectorKey === this.provider && row.operationKey === this.operation);
  }
  get shipmentOptions() {
    return this.shipments
      .filter((row) => !this.provider || row.label?.toLowerCase().startsWith(this.provider))
      .map((row) => ({ label: row.label, value: row.id }));
  }
  get requiresShipment() { return this.selectedDefinition?.requiresShipment === true; }
  get showConfirmation() { return Boolean(this.correctedAddress); }
  get correctedAddressText() { return this.correctedAddress ? JSON.stringify(this.correctedAddress, null, 2) : ''; }
  get showRates() { return this.rateQuotes.length > 0; }
  get disabled() { return this.loading || !this.provider || !this.operation || !this.recordId; }
  get messageClass() { return this.error ? 'slds-notify slds-notify_alert slds-alert_error slds-m-bottom_small' : 'slds-notify slds-notify_alert slds-theme_success slds-m-bottom_small'; }
  handleProvider(event) {
    this.provider = event.detail.value;
    this.operation = this.operations[0]?.value;
    this.shipmentId = undefined;
  }
  handleOperation(event) { this.operation = event.detail.value; }
  handleShipment(event) { this.shipmentId = event.detail.value; }
  close() { this.dispatchEvent(new CloseActionScreenEvent()); }

  async run() {
    this.loading = true;
    this.message = null;
    this.correctedAddress = undefined;
    this.rateQuotes = [];
    try {
      if (this.requiresShipment && !this.shipmentId) throw new Error('Select a carrier shipment before running this action.');
      let attemptId;
      if (this.selectedDefinition?.requiresIdempotency) {
        attemptId = await prepareMutation({
          connectorKey: this.provider, operationKey: this.operation,
          sourceRecordId: this.recordId, shipmentId: this.shipmentId
        });
      }
      const result = await execute({
        connectorKey: this.provider,
        operationKey: this.operation,
        sourceRecordId: this.recordId,
        shipmentId: this.shipmentId,
        attemptId
      });
      if (result?.success !== true) throw new Error(result?.errorSummary || result?.message || 'Carrier action failed.');
      if (this.operation === 'validateaddress' && result.correctedAddress) {
        this.correctedAddress = result.correctedAddress;
        return;
      }
      if (this.operation === 'quoterates' && result.rateQuotes?.length) {
        this.rateQuotes = result.rateQuotes;
        return;
      }
      this.error = false;
      this.message = result.message || 'Carrier action completed successfully.';
    } catch (failure) {
      this.setError(failure);
    } finally {
      this.loading = false;
    }
  }

  async confirmAddress() {
    this.loading = true;
    try {
      const result = await applyValidatedAddress({ connectorKey: this.provider, sourceRecordId: this.recordId, addressJson: JSON.stringify(this.correctedAddress) });
      if (result?.success !== true) throw new Error(result?.errorSummary || result?.message);
      this.message = result.message;
      this.error = false;
      this.correctedAddress = undefined;
    } catch (failure) { this.setError(failure); }
    finally { this.loading = false; }
  }

  discardAddress() { this.correctedAddress = undefined; this.message = 'Validated address discarded; no Salesforce fields were changed.'; this.error = false; }

  async chooseRate(event) {
    this.loading = true;
    try {
      const result = await selectRateQuote({ rateQuoteId: event.currentTarget.dataset.id, sourceRecordId: this.recordId });
      if (result?.success !== true) throw new Error(result?.errorSummary || result?.message);
      this.message = result.message;
      this.error = false;
      this.rateQuotes = [];
    } catch (failure) { this.setError(failure); }
    finally { this.loading = false; }
  }

  setError(failure) {
    this.error = true;
    this.message = failure?.body?.message || failure?.message || 'Carrier action failed.';
  }
}