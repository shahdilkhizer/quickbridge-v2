import { LightningElement, api } from 'lwc';

export default class QuickbridgeControlPlaneShell extends LightningElement {
  @api currentScreen;
  @api connectorLabel;
  @api showScheduler = false;

  navClass(screen) {
    return this.currentScreen === screen ? 'nav-item active' : 'nav-item';
  }
  get integrationsClass() { return this.navClass('integrations'); }
  get reportingClass() { return this.navClass('reporting'); }
  get errorsClass() { return this.navClass('errors'); }
  get mappingClass() { return this.navClass('mapping'); }
  get settingsClass() { return this.navClass('settings'); }
  get schedulerClass() { return this.navClass('scheduler'); }
  get hasConnector() { return Boolean(this.connectorLabel); }

  navigate(event) { this.dispatchEvent(new CustomEvent('navigate', { detail: event.currentTarget.dataset.screen })); }
  back() { this.dispatchEvent(new CustomEvent('back')); }
  logout() { this.dispatchEvent(new CustomEvent('logout')); }
}