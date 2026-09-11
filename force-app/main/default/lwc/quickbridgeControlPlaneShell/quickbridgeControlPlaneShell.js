import { LightningElement, api } from 'lwc';

const SIDEBAR_COLLAPSED_STORAGE_KEY = 'quickbridge.control-plane.sidebar-collapsed';
const SCREEN_LABELS = {
  integrations: 'Integrations',
  reporting: 'Reporting',
  errors: 'Error Log',
  mapping: 'Field Mapping',
  settings: 'Settings',
  scheduler: 'Scheduler'
};

export default class QuickbridgeControlPlaneShell extends LightningElement {
  @api currentScreen;
  @api connectorLabel;
  @api connectorStatus;
  @api connectorHealth;
  @api connectorLastRun;
  @api connectorNextRun;
  @api connectorScheduleState;
  @api showScheduler = false;
  @api showMapping = false;
  @api showSettings = false;
  @api showErrors = false;

  sidebarCollapsed = false;

  connectedCallback() {
    this.sidebarCollapsed = this.getStoredSidebarPreference();
  }

  get shellClass() { return this.sidebarCollapsed ? 'shell is-collapsed' : 'shell'; }
  get sidebarExpanded() { return String(!this.sidebarCollapsed); }
  get sidebarToggleIcon() { return this.sidebarCollapsed ? 'utility:chevronright' : 'utility:chevronleft'; }
  get sidebarToggleLabel() { return this.sidebarCollapsed ? 'Expand navigation' : 'Collapse navigation'; }
  get currentScreenLabel() { return SCREEN_LABELS[this.currentScreen] || 'Quickbridge'; }
  get hasConnector() { return Boolean(this.connectorLabel); }
  get connectorStatusLabel() { return this.connectorStatus || 'Unknown'; }
  get connectorHealthLabel() { return this.connectorHealth || 'Unknown'; }
  get connectorScheduleStateLabel() { return this.connectorScheduleState || 'Not scheduled'; }
  get hasLastRun() { return Boolean(this.connectorLastRun); }
  get hasNextRun() { return Boolean(this.connectorNextRun); }

  navClass(screen) {
    return this.currentScreen === screen ? 'nav-item active' : 'nav-item';
  }
  get integrationsClass() { return this.navClass('integrations'); }
  get reportingClass() { return this.navClass('reporting'); }
  get errorsClass() { return this.navClass('errors'); }
  get mappingClass() { return this.navClass('mapping'); }
  get settingsClass() { return this.navClass('settings'); }
  get schedulerClass() { return this.navClass('scheduler'); }

  getStoredSidebarPreference() {
    try {
      return window.localStorage.getItem(SIDEBAR_COLLAPSED_STORAGE_KEY) === 'true';
    } catch {
      return false;
    }
  }

  toggleSidebar() {
    this.sidebarCollapsed = !this.sidebarCollapsed;
    try {
      window.localStorage.setItem(SIDEBAR_COLLAPSED_STORAGE_KEY, String(this.sidebarCollapsed));
    } catch {
      // Storage can be unavailable in restrictive browser contexts; the current-view preference still applies.
    }
  }

  navigate(event) { this.dispatchEvent(new CustomEvent('navigate', { detail: { screen: event.currentTarget.dataset.screen }, bubbles: true, composed: true })); }
  back() { this.dispatchEvent(new CustomEvent('back')); }
  logout() { this.dispatchEvent(new CustomEvent('logout')); }
}