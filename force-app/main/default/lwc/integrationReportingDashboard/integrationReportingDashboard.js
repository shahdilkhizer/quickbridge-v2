import { LightningElement, api } from 'lwc';
import getOperationalOverview from '@salesforce/apex/QuickbridgeReportingController.getOperationalOverview';

const emptyOverview = () => ({
  activeConnectorCount: 0,
  readyConnectorCount: 0,
  attentionConnectorCount: 0,
  completedWorkCount: 0,
  backlogCount: 0,
  failedWorkCount: 0,
  overdueScheduleCount: 0,
  lastSuccessfulWorkAt: null,
  connectors: []
});

const numericValue = (value) => {
  const numberValue = Number(value);
  return Number.isFinite(numberValue) ? numberValue : 0;
};

export default class IntegrationReportingDashboard extends LightningElement {
  @api sessionToken;
  @api connectorKey;
  overview = emptyOverview();
  loading = true;
  errorMessage;

  connectedCallback() {
    this.refresh();
  }

  @api
  async refresh() {
    this.loading = true;
    this.errorMessage = undefined;
    this.overview = emptyOverview();
    try {
      const response = await getOperationalOverview({
        sessionToken: this.sessionToken,
        connectorKey: this.connectorKey || null
      });
      this.overview = this.normalizedOverview(response);
    } catch (error) {
      this.errorMessage = this.messageFrom(error);
    } finally {
      this.loading = false;
    }
  }

  get hasConnectors() {
    return this.overview.connectors.length > 0;
  }

  get reportingScopeLabel() {
    return this.connectorKey
      ? 'Current health for the selected connector.'
      : 'Current health across enabled connectors.';
  }

  get kpis() {
    return [
      {
        key: 'ready',
        label: 'Ready connectors',
        value: `${this.overview.readyConnectorCount} / ${this.overview.activeConnectorCount}`,
        description: 'Active connectors ready to operate.',
        cssClass: 'kpi-card is-success'
      },
      {
        key: 'attention',
        label: 'Needs attention',
        value: this.overview.attentionConnectorCount,
        description: 'Active connectors not operationally ready.',
        cssClass: 'kpi-card is-warning'
      },
      {
        key: 'completed',
        label: 'Completed work',
        value: this.overview.completedWorkCount,
        description: 'Work items currently marked completed.',
        cssClass: 'kpi-card'
      },
      {
        key: 'backlog',
        label: 'Queue backlog',
        value: this.overview.backlogCount,
        description: 'Pending, processing, or retry work items.',
        cssClass: 'kpi-card'
      },
      {
        key: 'failed',
        label: 'Failed work',
        value: this.overview.failedWorkCount,
        description: 'Work items currently in a terminal failed state.',
        cssClass: 'kpi-card is-danger'
      },
      {
        key: 'overdue',
        label: 'Overdue schedules',
        value: this.overview.overdueScheduleCount,
        description: 'Non-paused schedules more than five minutes late.',
        cssClass: 'kpi-card is-warning'
      }
    ];
  }

  get hasLastSuccessfulWork() {
    return Boolean(this.overview.lastSuccessfulWorkAt);
  }

  normalizedOverview(response) {
    const source = response || {};
    return {
      activeConnectorCount: numericValue(source.activeConnectorCount),
      readyConnectorCount: numericValue(source.readyConnectorCount),
      attentionConnectorCount: numericValue(source.attentionConnectorCount),
      completedWorkCount: numericValue(source.completedWorkCount),
      backlogCount: numericValue(source.backlogCount),
      failedWorkCount: numericValue(source.failedWorkCount),
      overdueScheduleCount: numericValue(source.overdueScheduleCount),
      lastSuccessfulWorkAt: source.lastSuccessfulWorkAt || null,
      connectors: (source.connectors || []).map((row) => this.normalizedConnector(row))
    };
  }

  normalizedConnector(row) {
    const source = row || {};
    const active = source.active === true;
    const ready = source.ready === true;
    const statusLabel = !active ? 'Inactive' : ready ? 'Ready' : 'Needs attention';
    const statusClass = !active
      ? 'connector-status is-neutral'
      : ready
        ? 'connector-status is-success'
        : 'connector-status is-warning';
    const pendingWorkCount = numericValue(source.pendingWorkCount);
    const processingWorkCount = numericValue(source.processingWorkCount);
    const retryWorkCount = numericValue(source.retryWorkCount);
    return {
      connectorKey: source.connectorKey,
      label: source.label || source.connectorKey || 'Connector',
      active,
      ready,
      statusLabel,
      statusClass,
      health: source.health || 'Unknown',
      completedWorkCount: numericValue(source.completedWorkCount),
      backlogCount: pendingWorkCount + processingWorkCount + retryWorkCount,
      failedWorkCount: numericValue(source.failedWorkCount),
      overdueScheduleCount: numericValue(source.overdueScheduleCount),
      nextScheduledRunAt: source.nextScheduledRunAt || null,
      scheduleState: source.scheduleState || 'Not scheduled'
    };
  }

  messageFrom(error) {
    return error?.body?.message || error?.message || 'Operational reporting could not be loaded.';
  }
}