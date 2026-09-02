import { LightningElement, api } from 'lwc';
import getReport from '@salesforce/apex/QuickbridgeReportingController.getReport';

export default class IntegrationReportingDashboard extends LightningElement {
  @api sessionToken;
  @api connectorKey;
  products = [];
  loading = true;
  errorMessage;

  connectedCallback() { this.refresh(); }
  @api async refresh() {
    this.loading = true; this.errorMessage = undefined;
    try {
      const report = await getReport({ sessionToken: this.sessionToken, connectorKey: this.connectorKey || null });
      this.products = (report.products || []).map((item) => ({ ...item, subscriptionLabel: item.subscriptionStatus || 'Available', lastUpdatedLabel: item.lastUpdated || report.refreshedAt }));
    } catch (error) { this.errorMessage = this.messageFrom(error); }
    finally { this.loading = false; }
  }
  get hasProducts() { return this.products.length > 0; }
  messageFrom(error) { return error?.body?.message || error?.message || 'Reporting data could not be loaded.'; }
}