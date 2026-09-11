import { LightningElement, api } from "lwc";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import getPage from "@salesforce/apex/QuickbridgeErrorTriageController.getPage";
import retryErrors from "@salesforce/apex/QuickbridgeErrorTriageController.retry";

export default class ErrorLogTable extends LightningElement {
  @api sessionToken;
  @api connectorKey;
  rows = [];
  mode = "Retry";
  pageSize = 10;
  cursor;
  cursorStack = [];
  nextCursor;
  selectedIds = [];
  filters = {};
  loading = true;
  errorMessage;

  connectedCallback() {
    this.load();
  }
  get retryTabClass() {
    return this.mode === "Retry" ? "tab active" : "tab";
  }
  get pendingTabClass() {
    return this.mode === "Pending" ? "tab active" : "tab";
  }
  get hasRows() {
    return this.rows.length > 0;
  }
  get previousDisabled() {
    return this.cursorStack.length === 0 || this.loading;
  }
  get nextDisabled() {
    return !this.nextCursor || this.loading;
  }
  get pageLabel() {
    return `Page ${this.cursorStack.length + 1}`;
  }
  get bulkRetryDisabled() {
    return this.selectedIds.length === 0 || this.loading;
  }

  async load() {
    if (!this.connectorKey) {
      this.loading = false;
      return;
    }
    this.loading = true;
    this.errorMessage = undefined;
    try {
      const page = await getPage({
        sessionToken: this.sessionToken,
        connectorKey: this.connectorKey,
        filterJson: JSON.stringify(this.filters),
        cursor: this.cursor,
        pageSize: this.pageSize,
        mode: this.mode
      });
      this.rows = (page.rows || []).map((row) => ({
        ...row,
        retryDisabled: !row.retryable,
        retryTitle: row.retryDisabledReason || "Retry this failed work item",
        selected: false,
        showRoute: Boolean(row.routeScreen)
      }));
      this.nextCursor = page.nextCursor;
      this.selectedIds = [];
    } catch (error) {
      this.errorMessage = this.messageFrom(error);
    } finally {
      this.loading = false;
    }
  }
  switchMode(event) {
    this.mode = event.currentTarget.dataset.mode;
    this.resetPagination();
    this.load();
  }
  previous() {
    if (!this.previousDisabled) {
      this.cursor = this.cursorStack.pop();
      this.cursorStack = [...this.cursorStack];
      this.load();
    }
  }
  next() {
    if (!this.nextDisabled) {
      this.cursorStack = [...this.cursorStack, this.cursor];
      this.cursor = this.nextCursor;
      this.load();
    }
  }
  changeFilter(event) {
    const key = event.currentTarget.dataset.filter;
    this.filters = {
      ...this.filters,
      [key]: event.detail?.value || event.target.value || null
    };
    this.resetPagination();
    this.load();
  }
  resetPagination() {
    this.cursor = undefined;
    this.nextCursor = undefined;
    this.cursorStack = [];
  }
  selectRow(event) {
    const id = event.currentTarget.dataset.id;
    const selected = event.target.checked;
    this.rows = this.rows.map((row) =>
      (row.id === id ? { ...row, selected } : row)
    );
    this.selectedIds = this.rows
      .filter((row) => row.selected && row.retryable)
      .map((row) => row.id);
  }
  async retry(event) {
    this.loading = true;
    try {
      const id = event.currentTarget.dataset.id;
      await retryErrors({ sessionToken: this.sessionToken, errorLogIds: [id] });
      this.dispatchEvent(
        new ShowToastEvent({
          title: "Retry queued",
          message: "Only the failed work item was queued for replay.",
          variant: "success"
        })
      );
      await this.load();
    } catch (error) {
      this.dispatchEvent(
        new ShowToastEvent({
          title: "Retry not queued",
          message: this.messageFrom(error),
          variant: "error"
        })
      );
      this.loading = false;
    }
  }
  async bulkRetry() {
    this.loading = true;
    try {
      const results = await retryErrors({
        sessionToken: this.sessionToken,
        errorLogIds: this.selectedIds
      });
      const succeeded = (results || []).filter(
        (item) => item.successful
      ).length;
      const failed = (results || []).length - succeeded;
      this.dispatchEvent(
        new ShowToastEvent({
          title: "Bulk retry complete",
          message: `${succeeded} queued; ${failed} could not be queued.`,
          variant: failed ? "warning" : "success"
        })
      );
      await this.load();
    } catch (error) {
      this.dispatchEvent(
        new ShowToastEvent({
          title: "Retries not queued",
          message: this.messageFrom(error),
          variant: "error"
        })
      );
      this.loading = false;
    }
  }
  route(event) {
    this.dispatchEvent(
      new CustomEvent("navigate", {
        detail: {
          screen: event.currentTarget.dataset.screen,
          connectorKey: this.connectorKey,
          focusKey: event.currentTarget.dataset.focus
        },
        bubbles: true,
        composed: true
      })
    );
  }
  messageFrom(error) {
    return (
      error?.body?.message ||
      error?.message ||
      "Error history could not be loaded."
    );
  }
}