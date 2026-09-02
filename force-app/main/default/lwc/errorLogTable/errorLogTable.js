import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getErrors from '@salesforce/apex/QuickbridgeErrorController.getErrors';
import replayError from '@salesforce/apex/QuickbridgeErrorController.replayError';

export default class ErrorLogTable extends LightningElement {
  @api sessionToken;
  @api connectorKey;
  rows = [];
  mode = 'Retry';
  pageNumber = 1;
  pageSize = 10;
  totalCount = 0;
  loading = true;
  errorMessage;

  connectedCallback() { this.load(); }
  get retryTabClass() { return this.mode === 'Retry' ? 'tab active' : 'tab'; }
  get pendingTabClass() { return this.mode === 'Pending' ? 'tab active' : 'tab'; }
  get hasRows() { return this.rows.length > 0; }
  get previousDisabled() { return this.pageNumber <= 1 || this.loading; }
  get nextDisabled() { return this.pageNumber * this.pageSize >= this.totalCount || this.loading; }
  get pageLabel() { return `Page ${this.pageNumber}`; }

  async load() {
    if (!this.connectorKey) { this.loading = false; return; }
    this.loading = true; this.errorMessage = undefined;
    try {
      const page = await getErrors({ sessionToken: this.sessionToken, connectorKey: this.connectorKey, pageNumber: this.pageNumber, pageSize: this.pageSize, mode: this.mode });
      this.rows = (page.rows || []).map((row) => ({ ...row, retryDisabled: !row.retryable, retryTitle: row.retryDisabledReason || 'Retry this failed work item' }));
      this.totalCount = page.totalCount || 0;
    } catch (error) { this.errorMessage = this.messageFrom(error); }
    finally { this.loading = false; }
  }
  switchMode(event) { this.mode = event.currentTarget.dataset.mode; this.pageNumber = 1; this.load(); }
  previous() { if (this.pageNumber > 1) { this.pageNumber -= 1; this.load(); } }
  next() { if (!this.nextDisabled) { this.pageNumber += 1; this.load(); } }
  async retry(event) {
    this.loading = true;
    try {
      await replayError({ sessionToken: this.sessionToken, errorLogId: event.currentTarget.dataset.id });
      this.dispatchEvent(new ShowToastEvent({ title: 'Retry queued', message: 'Only the failed work item was queued for replay.', variant: 'success' }));
      await this.load();
    } catch (error) { this.dispatchEvent(new ShowToastEvent({ title: 'Retry not queued', message: this.messageFrom(error), variant: 'error' })); this.loading = false; }
  }
  messageFrom(error) { return error?.body?.message || error?.message || 'Error history could not be loaded.'; }
}