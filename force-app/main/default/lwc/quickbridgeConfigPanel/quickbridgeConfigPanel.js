import { LightningElement } from 'lwc';
import LightningConfirm from 'lightning/confirm';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import authenticateAdmin from '@salesforce/apex/QuickbridgeControlPanelController.authenticateAdmin';
import recoverPin from '@salesforce/apex/QuickbridgeControlPanelController.recoverPin';
import revokeAdminSession from '@salesforce/apex/QuickbridgeControlPanelController.revokeAdminSession';
import getPanelBootstrap from '@salesforce/apex/QuickbridgeControlPanelController.getPanelBootstrap';
import refreshLicenses from '@salesforce/apex/QuickbridgeControlPanelController.refreshLicenses';
import updateAvailableProductsVisible from '@salesforce/apex/QuickbridgeControlPanelController.updateAvailableProductsVisible';
import sendRenewalRequest from '@salesforce/apex/QuickbridgeControlPanelController.sendRenewalRequest';
import checkIntegrationExpiry from '@salesforce/apex/QuickbridgeControlPanelController.checkIntegrationExpiry';
import getConnectorConfiguration from '@salesforce/apex/QuickbridgeControlPanelController.getConnectorConfiguration';
import saveConnectorConfiguration from '@salesforce/apex/QuickbridgeControlPanelController.saveConnectorConfiguration';
import resetConnectorConfiguration from '@salesforce/apex/QuickbridgeControlPanelController.resetConnectorConfiguration';
import runHealthProbe from '@salesforce/apex/QuickbridgeControlPanelController.runHealthProbe';
import setConnectorOperationalState from '@salesforce/apex/QuickbridgeControlPanelController.setConnectorOperationalState';
import runConnector from '@salesforce/apex/QuickbridgeControlPanelController.runConnector';
import getMappingWorkspace from '@salesforce/apex/QuickbridgeMappingFacade.getMappingWorkspace';
import saveMappings from '@salesforce/apex/QuickbridgeMappingFacade.saveMappings';
import clearMappings from '@salesforce/apex/QuickbridgeMappingFacade.clearMappings';
import getDeploymentStatus from '@salesforce/apex/QuickbridgeMappingFacade.getDeploymentStatus';
import reviewMappingOperation from '@salesforce/apex/QuickbridgeMappingFacade.reviewMappingOperation';
import canManageMappings from '@salesforce/customPermission/Manage_QuickBridge';
import QuickBridgeLogo from '@salesforce/resourceUrl/QuickBridge_Logo';

const SESSION_ERROR_MARKERS = ['session is required', 'session is invalid', 'session expired', 'log in again'];

export default class QuickbridgeConfigPanel extends LightningElement {
  currentScreen = 'login';
  userId = '';
  pin = '';
  username;
  sessionToken;
  sessionExpiresAt;
  loginLoading = false;
  loginMessage;
  loading = false;
  connectors = [];
  availableProductsVisible = true;
  selectedConnectorKey;
  expiryAlert;
  renewalOpen = false;
  renewalChoices = [];
  configLoading = false;
  configSaving = false;
  configEditing = false;
  configError;
  connectorConfiguration = {};
  configFields = [];
  mappingWorkspace;
  selectedMappingOperationKey;
  mappingLoading = false;
  mappingSaving = false;
  mappingError;
  mappingAnalysis;
  mappingAnalysisLoading = false;
  mappingAnalysisError;
  analysisSignature;
  analysisGeneration = 0;
  analysisTimer;

  get assistantOperation() { return this.selectedMappingOperation; }
  get assistantCanApply() { return Boolean(canManageMappings) && !this.mappingSaving && !this.mappingPending && !this.mappingAnalysisLoading; }
  analysisRequest() {
    const operation = this.selectedMappingOperation;
    if (!this.isMapping || !operation || !this.mappingWorkspace || !this.sessionToken) return null;
    return { connectorKey: this.mappingWorkspace.connectorKey, operationKey: operation.operationKey,
      operationDirection: operation.direction, rows: operation.mappings.map((row) => ({
        salesforceField: row.salesforceField, externalPath: row.externalPath, direction: row.direction,
        active: row.active, isLine: row.isLine, salesforceObject: row.salesforceObject
      })) };
  }
  renderedCallback() {
    const request = this.analysisRequest();
    const signature = request ? JSON.stringify(request) : null;
    if (signature === this.analysisSignature) return;
    this.analysisSignature = signature;
    this.analysisGeneration += 1;
    clearTimeout(this.analysisTimer);
    this.mappingAnalysis = undefined;
    this.mappingAnalysisError = undefined;
    this.mappingAnalysisLoading = Boolean(request);
    if (request) {
      // eslint-disable-next-line @lwc/lwc/no-async-operation
      this.analysisTimer = setTimeout(() => this.refreshMappingAnalysis(), 300);
    }
  }
  disconnectedCallback() { clearTimeout(this.analysisTimer); this.analysisGeneration += 1; }
  async refreshMappingAnalysis() {
    clearTimeout(this.analysisTimer);
    const request = this.analysisRequest();
    if (!request) return;
    const signature = JSON.stringify(request);
    const generation = ++this.analysisGeneration;
    this.mappingAnalysisLoading = true;
    this.mappingAnalysisError = undefined;
    try {
      const result = await reviewMappingOperation({ sessionToken: this.sessionToken, requestJson: signature });
      if (generation !== this.analysisGeneration || signature !== JSON.stringify(this.analysisRequest())) return;
      this.mappingAnalysis = result;
    } catch (error) {
      if (generation !== this.analysisGeneration) return;
      this.mappingAnalysis = undefined;
      this.mappingAnalysisError = this.messageFrom(error);
      this.handleSessionError(error);
    } finally {
      if (generation === this.analysisGeneration) this.mappingAnalysisLoading = false;
    }
  }

  get mappingDirty() {
    return Boolean(this.selectedMappingOperation?._mappingDirty || this.selectedMappingOperation?._settingDirty);
  }
  set mappingDirty(value) {
    const operation = this.selectedMappingOperation;
    if (operation) this.replaceOperation({ ...operation, _mappingDirty: value });
  }
  quickBridgeLogo = QuickBridgeLogo;

  get isLogin() { return this.currentScreen === 'login'; }
  get isIntegrations() { return this.currentScreen === 'integrations'; }
  get isReporting() { return this.currentScreen === 'reporting'; }
  get isErrors() { return this.currentScreen === 'errors'; }
  get isMapping() { return this.currentScreen === 'mapping'; }
  get isSettings() { return this.currentScreen === 'settings'; }
  get isScheduler() { return this.currentScreen === 'scheduler'; }
  get subscribedConnectors() { return this.connectors.filter((item) => item.subscribed); }
  get availableConnectors() { return this.connectors.filter((item) => !item.subscribed); }
  get hasSubscribed() { return this.subscribedConnectors.length > 0; }
  get hasAvailable() { return this.availableProductsVisible && this.availableConnectors.length > 0; }
  get availableToggleLabel() { return this.availableProductsVisible ? 'Hide Available Products' : 'Show Available Products'; }
  get selectedConnector() { return this.connectors.find((item) => item.key === this.selectedConnectorKey); }
  get selectedConnectorLabel() { return this.selectedConnector?.label; }
  get showSchedulerNavigation() { return this.selectedConnector?.hasScheduler === true; }
  get needsConnector() { return ['errors', 'mapping', 'settings', 'scheduler'].includes(this.currentScreen) && !this.selectedConnector; }
  get loginDisabled() { return this.loginLoading || !this.userId || !/^[0-9]{4}$/.test(this.pin); }
  get hasConfigFields() { return this.configFields.length > 0; }
  get configSaveDisabled() { return this.configSaving || !this.configEditing; }
  get configEditDisabled() { return this.configLoading || this.configSaving; }
  get operationalStateLabel() { return this.selectedConnector?.active ? 'Pause' : 'Reactivate'; }
  get runDisabled() { return !this.selectedConnector?.ready || this.loading; }
  get hasExpiryAlert() { return this.expiryAlert?.shouldAlert === true; }
  get expiryAlertClass() { return `expiry-alert ${this.expiryAlert?.variant || 'warning'}`; }
  get hasMappingWorkspace() { return Boolean(this.mappingWorkspace); }
  get isPaymentMapping() { return this.selectedConnector?.hasPayment === true; }
  get isCarrierMapping() { return this.selectedConnector?.hasCarrier === true; }
  get hasMappingOperations() { return (this.mappingWorkspace?.operations || []).length > 0; }
  get selectedMappingOperation() { return (this.mappingWorkspace?.operations || []).find((item) => item.workspaceKey === this.selectedMappingOperationKey) || this.mappingWorkspace?.operations?.[0]; }
  get mappingOperationOptions() { return (this.mappingWorkspace?.operations || []).map((item) => ({ label: `${item.label} — ${item.direction}`, value: item.workspaceKey })); }
  get mappingRows() { return this.selectedMappingOperation?.mappings || []; }
  get hasLineItems() { return this.selectedMappingOperation?.hasLineItems === true; }
  get headerSectionLabel() { return `${this.selectedMappingOperation?.salesforceObjectLabel || this.selectedMappingOperation?.salesforceObject || 'Header'} Mappings`; }
  get lineSectionLabel() { return `${this.selectedMappingOperation?.childObjectLabel || 'Line Item'} Mappings`; }
  get lineObjectLabel() { return this.selectedMappingOperation?.childObjectLabel || 'Line Item'; }
  get headerMappingRows() { return (this.selectedMappingOperation?.mappings || []).filter((row) => !row.isLine); }
  get lineMappingRows() { return (this.selectedMappingOperation?.mappings || []).filter((row) => row.isLine); }
  get mappingFieldOptions() { return this.selectedMappingOperation?.salesforceFields || []; }
  get lineFieldOptions() { return this.selectedMappingOperation?.lineFields || []; }
  get mappingExternalFieldOptions() { return this.selectedMappingOperation?.externalFields || []; }
  get mappingSaveDisabled() { return this.mappingSaving || this.mappingPending || !this.mappingDirty; }
  get mappingPending() { return Boolean(this.selectedMappingOperation?._pendingDeployment); }
  get mappingResetDisabled() { return this.mappingSaving || this.mappingPending; }
  get showRecordSaveSetting() { return ['qbo', 'shopify', 'klaviyo'].includes(this.mappingWorkspace?.connectorKey); }
  get recordSaveDisabled() { return this.mappingSaving || this.mappingPending || !this.selectedMappingOperation?.supportsRunOnRecordSave; }
  get recordSaveUnavailable() { return !this.selectedMappingOperation?.supportsRunOnRecordSave; }
  handleRecordSaveChange(event) {
    const operation = this.selectedMappingOperation;
    if (!operation || this.recordSaveDisabled) return;
    const checked = event.target.checked;
    this.replaceOperation({ ...operation, runOnRecordSave: checked,
      _settingDirty: checked !== operation._savedRunOnRecordSave });
  }
  get mappingPresentationLabel() {
    if (this.selectedConnector?.hasCarrier) return 'Carrier Operation Mapping';
    if (this.selectedConnector?.hasPayment) return 'Payment Record Mapping';
    if (this.selectedConnectorKey === 'qbo') return 'QuickBooks Parent and Line Mapping';
    if (this.selectedConnectorKey === 'shopify') return 'Shopify Object Mapping';
    return 'Generic Record Mapping';
  }
  get renewalRenewals() { return this.renewalChoices.filter((item) => item.group === 'renewal'); }
  get renewalAdditions() { return this.renewalChoices.filter((item) => item.group === 'additional'); }

  handleUserId(event) { this.userId = event.target.value.trim(); }
  handlePin(event) { this.pin = event.target.value.replace(/\D/g, '').slice(0, 4); }

  async login() {
    if (this.loginDisabled) return;
    this.loginLoading = true; this.loginMessage = undefined;
    try {
      const response = await authenticateAdmin({ userId: this.userId, pin: this.pin });
      if (!response.successful) { this.loginMessage = response.message; return; }
      this.sessionToken = response.sessionToken;
      this.sessionExpiresAt = response.sessionExpiresAt;
      this.username = response.username;
      this.pin = '';
      await this.refreshEntitlements(false);
      await this.loadBootstrap();
      this.selectedConnectorKey = undefined;
      this.currentScreen = 'reporting';
    } catch (error) { this.loginMessage = this.messageFrom(error); }
    finally { this.loginLoading = false; }
  }

  async requestPinRecovery() {
    if (!this.userId) { this.loginMessage = 'Enter your User ID first.'; return; }
    this.loginLoading = true;
    try { const response = await recoverPin({ userId: this.userId }); this.loginMessage = response.message; }
    catch (error) { this.loginMessage = this.messageFrom(error); }
    finally { this.loginLoading = false; }
  }

  async logout() {
    try { if (this.sessionToken) await revokeAdminSession({ sessionToken: this.sessionToken }); } catch { /* local cleanup must continue */ }
    this.clearSession();
  }

  clearSession(message) {
    this.sessionToken = undefined; this.sessionExpiresAt = undefined; this.username = undefined; this.connectors = [];
    this.selectedConnectorKey = undefined; this.currentScreen = 'login'; this.loginMessage = message; this.mappingWorkspace = undefined;
  }

  async loadBootstrap() {
    this.loading = true;
    try {
      const response = await getPanelBootstrap({ sessionToken: this.sessionToken });
      this.username = response.username; this.sessionExpiresAt = response.sessionExpiresAt; this.availableProductsVisible = response.availableProductsVisible;
      this.connectors = (response.connectors || []).map((item) => this.decorateConnector(item));
    } catch (error) { this.handleError(error, 'Quickbridge could not be loaded.'); }
    finally { this.loading = false; }
  }

  decorateConnector(item) {
    const logo = item.logoResourceName || 'QuickBridge_Logo';
    return {
      ...item,
      logoUrl: `/resource/${logo}`,
      statusLabel: item.active ? 'Active' : item.subscribed ? 'Subscribed' : 'Available',
      tileClass: item.active ? 'product-tile active' : item.subscribed ? 'product-tile subscribed' : 'product-tile available',
      readinessClass: item.ready ? 'readiness ready' : 'readiness blocked',
      actionLabel: item.subscribed ? 'Open' : 'Setup Now'
    };
  }

  async navigate(event) {
    const screen = event.detail;
    if (screen === 'scheduler' && !this.showSchedulerNavigation) return;
    this.currentScreen = screen;
    if (screen === 'settings' && this.selectedConnector) await this.loadConfiguration();
    if (screen === 'mapping' && this.selectedConnector) await this.loadMappings();
  }

  backToIntegrations() { this.selectedConnectorKey = undefined; this.expiryAlert = undefined; this.mappingWorkspace = undefined; this.currentScreen = 'integrations'; }
  goToIntegrations() { this.currentScreen = 'integrations'; }

  async openConnector(event) {
    this.selectedConnectorKey = event.currentTarget.dataset.key;
    await this.checkExpiry();
    if (this.selectedConnector?.subscribed) this.currentScreen = 'reporting';
    else { this.currentScreen = 'settings'; await this.loadConfiguration(); }
  }

  async setupConnector(event) { this.selectedConnectorKey = event.currentTarget.dataset.key; await this.checkExpiry(); this.currentScreen = 'settings'; await this.loadConfiguration(); }

  async checkExpiry() {
    this.expiryAlert = undefined;
    try { this.expiryAlert = await checkIntegrationExpiry({ sessionToken: this.sessionToken, connectorKey: this.selectedConnectorKey }); }
    catch (error) { this.handleError(error, 'Expiry status could not be checked.', false); }
  }

  async refreshEntitlements(showToast = true) {
    try {
      const response = await refreshLicenses({ sessionToken: this.sessionToken });
      if (showToast) this.toast(response.successful ? 'Licenses refreshed' : 'License refresh incomplete', response.message, response.successful ? 'success' : 'warning');
      if (showToast) await this.loadBootstrap();
    } catch (error) { if (showToast) this.handleError(error, 'Licenses could not be refreshed.'); }
  }

  async toggleAvailableProducts() {
    const nextValue = !this.availableProductsVisible;
    try { await updateAvailableProductsVisible({ sessionToken: this.sessionToken, visible: nextValue }); this.availableProductsVisible = nextValue; }
    catch (error) { this.handleError(error, 'Display preference could not be saved.'); }
  }

  openRenewal() {
    this.renewalChoices = [
      ...this.subscribedConnectors.map((item) => ({ ...item, group: 'renewal', selected: false })),
      ...this.availableConnectors.map((item) => ({ ...item, group: 'additional', selected: false }))
    ];
    this.renewalOpen = true;
  }
  closeRenewal() { this.renewalOpen = false; }
  changeRenewalChoice(event) { const key = event.currentTarget.dataset.key; const group = event.currentTarget.dataset.group; this.renewalChoices = this.renewalChoices.map((item) => (item.key === key && item.group === group ? { ...item, selected: event.target.checked } : item)); }
  async submitRenewal() {
    const renewals = this.renewalChoices.filter((item) => item.group === 'renewal' && item.selected).map((item) => item.key);
    const additions = this.renewalChoices.filter((item) => item.group === 'additional' && item.selected).map((item) => item.key);
    try { const response = await sendRenewalRequest({ sessionToken: this.sessionToken, renewalConnectorKeys: renewals, additionalConnectorKeys: additions }); this.toast(response.successful ? 'Request sent' : 'Request not sent', response.message, response.successful ? 'success' : 'warning'); if (response.successful) this.renewalOpen = false; }
    catch (error) { this.handleError(error, 'Renewal request could not be sent.'); }
  }

  async loadConfiguration() {
    this.configLoading = true; this.configError = undefined; this.configEditing = false;
    try { this.applyConfiguration(await getConnectorConfiguration({ sessionToken: this.sessionToken, connectorKey: this.selectedConnectorKey })); }
    catch (error) { this.configError = this.messageFrom(error); this.handleSessionError(error); }
    finally { this.configLoading = false; }
  }
  applyConfiguration(configuration) {
    this.connectorConfiguration = configuration || {};
    this.configFields = (configuration?.fields || []).map((field) => { const type = String(field.dataType || 'Text').toLowerCase(); const isBoolean = type === 'boolean'; return { ...field, isBoolean, checked: isBoolean && String(field.value).toLowerCase() === 'true', value: field.value || '', inputType: type === 'date' ? 'date' : type === 'number' ? 'number' : 'text', disabled: true }; });
  }
  editConfiguration() { this.configEditing = true; this.configFields = this.configFields.map((field) => ({ ...field, disabled: false })); }
  cancelConfiguration() { this.applyConfiguration(this.connectorConfiguration); this.configEditing = false; }
  handleConfigChange(event) { const key = event.currentTarget.dataset.key; this.configFields = this.configFields.map((field) => (field.key === key ? { ...field, value: field.isBoolean ? String(event.target.checked) : event.target.value, checked: field.isBoolean ? event.target.checked : field.checked } : field)); }
  async saveConfiguration() {
    const invalid = [...this.template.querySelectorAll('.config-form lightning-input')].find((input) => !input.reportValidity()); if (invalid) return;
    this.configSaving = true;
    try { const values = Object.fromEntries(this.configFields.map((field) => [field.key, field.isBoolean ? String(field.checked) : field.value])); const response = await saveConnectorConfiguration({ sessionToken: this.sessionToken, connectorKey: this.selectedConnectorKey, valuesJson: JSON.stringify(values) }); this.applyConfiguration(response); this.configEditing = false; this.toast('Configuration saved', 'A readiness probe will determine whether this connector can run.', 'success'); await this.probeConnection(false); await this.loadBootstrap(); }
    catch (error) { this.handleError(error, 'Configuration could not be saved.'); }
    finally { this.configSaving = false; }
  }
  async resetConfiguration() {
    const confirmed = await LightningConfirm.open({ label: 'Delete Configuration', message: 'Clear non-secret settings and pause this connector? Credentials, mappings, work, errors, and audit history will be preserved.', variant: 'headerless' }); if (!confirmed) return;
    try { const response = await resetConnectorConfiguration({ sessionToken: this.sessionToken, connectorKey: this.selectedConnectorKey }); this.toast('Configuration reset', response.message, 'success'); await this.loadBootstrap(); await this.loadConfiguration(); }
    catch (error) { this.handleError(error, 'Configuration could not be reset.'); }
  }
  async probeConnection(showToast = true) { try { const response = await runHealthProbe({ sessionToken: this.sessionToken, connectorKey: this.selectedConnectorKey }); if (showToast) this.toast(response.successful ? 'Connection ready' : 'Connection not ready', response.message || response.status, response.successful ? 'success' : 'warning'); return response; } catch (error) { if (showToast) this.handleError(error, 'Connection validation failed.'); return null; } }
  async runNow() { try { await runConnector({ sessionToken: this.sessionToken, connectorKey: this.selectedConnectorKey }); this.toast('Run queued', `${this.selectedConnectorLabel} was queued for the shared heartbeat.`, 'success'); } catch (error) { this.handleError(error, 'The integration could not be queued.'); } }
  async toggleOperationalState() { try { const state = this.selectedConnector?.active ? 'Paused' : 'Active'; await setConnectorOperationalState({ sessionToken: this.sessionToken, connectorKey: this.selectedConnectorKey, requestedState: state }); this.toast('Connector updated', `${this.selectedConnectorLabel} is ${state.toLowerCase()}.`, 'success'); await this.loadBootstrap(); } catch (error) { this.handleError(error, 'Connector state could not be changed.'); } }

  async loadMappings(refreshedKey) {
    this.mappingLoading = true; this.mappingError = undefined;
    if (this.isPaymentMapping || this.isCarrierMapping) {
      this.mappingWorkspace = undefined;
      this.mappingLoading = false;
      return true;
    }
    const oldWorkspace = this.mappingWorkspace;
    const selectedKey = this.selectedMappingOperationKey;
    try {
      const workspace = await getMappingWorkspace({ sessionToken: this.sessionToken, connectorKey: this.selectedConnectorKey });
      const previous = oldWorkspace?.connectorKey === workspace.connectorKey
        ? new Map((oldWorkspace.operations || []).map((operation) => [operation.workspaceKey, operation]))
        : new Map();
      this.mappingWorkspace = { ...workspace, operations: (workspace.operations || []).map((operation) => {
        const draft = previous.get(operation.workspaceKey);
        if (operation.workspaceKey !== refreshedKey && draft &&
            (draft._mappingDirty || draft._settingDirty || draft._pendingDeployment)) return draft;
        return { ...operation, runOnRecordSave: operation.runOnRecordSave === true,
          _savedRunOnRecordSave: operation.runOnRecordSave === true,
          _mappingDirty: false, _settingDirty: false, _pendingDeployment: null,
          mappings: (operation.mappings || []).map((row, index) => this.decorateMappingRow(row, index)) };
      }) };
      this.selectedMappingOperationKey = this.mappingWorkspace.operations.some((operation) => operation.workspaceKey === selectedKey)
        ? selectedKey : this.mappingWorkspace.operations?.[0]?.workspaceKey;
      return true;
    } catch (error) { this.mappingError = this.messageFrom(error); return false; }
    finally { this.mappingLoading = false; }
  }
  decorateMappingRow(row, index) {
    const source = row.source || 'New';
    const isLine = row.isLine === true;
    const prefix = isLine ? 'line' : 'header';
    return {
      ...row,
      key: row.developerName || `${prefix}-${source}-${index}-${row.salesforceField || 'new'}`,
      source,
      isLine,
      salesforceObject: row.salesforceObject || '',
      active: row.active !== false,
      dirty: source === 'New',
      required: row.required === true
    };
  }
  changeMappingOperation(event) { this.selectedMappingOperationKey = event.detail.value; }
  addMapping() { this.addHeaderMapping(); }
  addHeaderMapping() {
    const operation = this.selectedMappingOperation;
    if (!operation) return;
    const newRow = this.decorateMappingRow({
      salesforceField: '',
      externalPath: '',
      direction: operation.direction,
      active: true,
      source: 'New',
      isLine: false,
      salesforceObject: operation.salesforceObject
    }, operation.mappings.length);
    this.replaceOperation({ ...operation, mappings: [...operation.mappings, newRow] });
    this.mappingDirty = true;
  }
  addLineMapping() {
    const operation = this.selectedMappingOperation;
    if (!operation) return;
    const existingLineRow = operation.mappings.find((m) => m.isLine);
    const newRow = this.decorateMappingRow({
      salesforceField: '',
      externalPath: '',
      direction: operation.direction,
      active: true,
      source: 'New',
      isLine: true,
      salesforceObject: existingLineRow?.salesforceObject || '',
      collectionPath: operation.collectionPath
    }, operation.mappings.length);
    this.replaceOperation({ ...operation, mappings: [...operation.mappings, newRow] });
    this.mappingDirty = true;
  }
  changeMappingByKey(event) {
    const key = event.currentTarget.dataset.key;
    const field = event.currentTarget.dataset.field;
    const value = field === 'active' ? event.target.checked : event.detail?.value ?? event.target.value;
    const operation = this.selectedMappingOperation;
    if (!operation) return;
    this.replaceOperation({
      ...operation,
      mappings: operation.mappings.map((row) => (row.key === key ? { ...row, [field]: value, dirty: true } : row))
    });
    this.mappingDirty = true;
  }
  removeMappingByKey(event) {
    const key = event.currentTarget.dataset.key;
    const operation = this.selectedMappingOperation;
    if (!operation) return;
    this.replaceOperation({
      ...operation,
      mappings: operation.mappings.filter((row) => row.key !== key)
    });
    this.mappingDirty = true;
  }
  changeMapping(event) { const index = Number(event.currentTarget.dataset.index); const field = event.currentTarget.dataset.field; const value = field === 'active' ? event.target.checked : event.detail?.value ?? event.target.value; const operation = this.selectedMappingOperation; this.replaceOperation({ ...operation, mappings: operation.mappings.map((row, rowIndex) => (rowIndex === index ? { ...row, [field]: value, dirty: true } : row)) }); this.mappingDirty = true; }
  removeMapping(event) { const index = Number(event.currentTarget.dataset.index); const operation = this.selectedMappingOperation; this.replaceOperation({ ...operation, mappings: operation.mappings.filter((row, rowIndex) => rowIndex !== index) }); this.mappingDirty = true; }
  replaceOperation(replacement) { this.mappingWorkspace = { ...this.mappingWorkspace, operations: this.mappingWorkspace.operations.map((item) => (item.workspaceKey === replacement.workspaceKey ? replacement : item)) }; }
  applySuggestions(event) {
    const operation = this.selectedMappingOperation;
    const detail = event.detail;
    if (!operation || !this.assistantCanApply || detail?.workspaceKey !== operation.workspaceKey ||
        this.mappingAnalysis?.workspaceKey !== operation.workspaceKey ||
        this.mappingAnalysis?.connectorKey !== this.mappingWorkspace.connectorKey) return;
    const offered = new Map((this.mappingAnalysis.suggestions || []).filter((item) => item.canApply).map((item) => [item.key, item]));
    const additions = [];
    const occupied = [...operation.mappings];
    for (const selected of detail.suggestions || []) {
      const item = offered.get(selected.key);
      if (!item || item.workspaceKey !== operation.workspaceKey) continue;
      const normalized = (value) => String(value || '').toLowerCase();
      const duplicate = occupied.some((row) =>
        normalized(row.salesforceObject || operation.salesforceObject) === normalized(item.salesforceObject) &&
        (row.direction === item.direction || ['Both', 'Bidirectional'].includes(row.direction) || ['Both', 'Bidirectional'].includes(item.direction)) &&
        (normalized(row.salesforceField) === normalized(item.salesforceField) || normalized(row.externalPath) === normalized(item.externalPath)));
      if (duplicate) continue;
      const row = this.decorateMappingRow({ salesforceField: item.salesforceField, externalPath: item.externalPath,
        direction: operation.direction, active: true, source: 'New', isLine: item.isLine === true,
        salesforceObject: item.salesforceObject, collectionPath: item.collectionPath
      }, operation.mappings.length + additions.length);
      occupied.push(row); additions.push(row);
    }
    if (!additions.length) return;
    this.replaceOperation({ ...operation, _mappingDirty: true, mappings: [...operation.mappings, ...additions] });
    this.toast('Suggestions applied', 'Review the draft, then use Save Mappings to persist it.', 'info');
  }
  async saveMappingWorkspace() {
    const operation = this.selectedMappingOperation;
    if (!operation || this.mappingSaveDisabled) return;
    this.mappingSaving = true;
    const key = operation.workspaceKey;
    try {
      const request = {
        connectorKey: this.mappingWorkspace.connectorKey, operationKey: operation.operationKey,
        operationDirection: operation.direction, salesforceObject: operation.salesforceObject,
        externalObject: operation.externalObject
      };
      if (operation._settingDirty) request.runOnRecordSave = operation.runOnRecordSave;
      if (operation._mappingDirty) request.rows = operation.mappings.map((row) => ({
        salesforceField: row.salesforceField, externalPath: row.externalPath,
        direction: row.direction, active: row.active, isLine: row.isLine === true,
        salesforceObject: row.salesforceObject
      }));
      const response = await saveMappings({ sessionToken: this.sessionToken, requestJson: JSON.stringify(request) });
      await this.pollDeployment(response.deploymentId, key);
    } catch (error) { this.handleError(error, 'Mappings could not be saved.'); }
    finally { this.mappingSaving = false; }
  }
  async resetMappings() {
    const operation = this.selectedMappingOperation;
    if (!operation || this.mappingResetDisabled) return;
    this.mappingSaving = true;
    try {
      const response = await clearMappings({ sessionToken: this.sessionToken, connectorKey: this.mappingWorkspace.connectorKey,
        operationKey: operation.operationKey, salesforceObject: operation.salesforceObject,
        externalObject: operation.externalObject, direction: operation.direction });
      await this.pollDeployment(response.deploymentId, operation.workspaceKey);
    } catch (error) { this.handleError(error, 'Mappings could not be reset.'); }
    finally { this.mappingSaving = false; }
  }
  setMappingPending(workspaceKey, deploymentId) {
    const operation = this.mappingWorkspace?.operations.find((item) => item.workspaceKey === workspaceKey);
    if (operation) this.replaceOperation({ ...operation, _pendingDeployment: deploymentId });
  }
  async checkMappingDeployment() {
    const operation = this.selectedMappingOperation;
    if (!operation?._pendingDeployment || this.mappingSaving) return;
    this.mappingSaving = true;
    try { await this.pollDeployment(operation._pendingDeployment, operation.workspaceKey); }
    catch (error) { this.handleError(error, 'Mapping deployment could not be checked.'); }
    finally { this.mappingSaving = false; }
  }
  async pollDeployment(deploymentId, workspaceKey) {
    if (!deploymentId) { await this.loadMappings(workspaceKey); return; }
    this.setMappingPending(workspaceKey, deploymentId);
    /* eslint-disable no-await-in-loop */
    for (let attempt = 0; attempt < 5; attempt += 1) {
      const status = await getDeploymentStatus({ sessionToken: this.sessionToken, deploymentId });
      if (status.status === 'Succeeded') {
        if (!await this.loadMappings(workspaceKey)) {
          this.toast('Refresh required', 'Deployment succeeded, but the saved settings could not be reloaded. Check deployment status to retry.', 'warning');
          return;
        }
        this.toast('Mappings saved', 'Mappings and record-save settings were refreshed.', 'success');
        return;
      }
      if (status.status === 'Failed') {
        this.setMappingPending(workspaceKey, null);
        throw new Error(status.message || 'Mapping deployment failed. The saved settings were not changed.');
      }
      await new Promise((resolve) => {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(resolve, 1500);
      });
    }
    /* eslint-enable no-await-in-loop */
    this.toast('Mapping deployment pending', 'The record-save setting takes effect only after deployment succeeds. Check deployment status to refresh.', 'info');
  }

  handleError(error, fallback, toast = true) { const message = this.messageFrom(error) || fallback; if (this.handleSessionError(error)) return; if (toast) this.toast('Quickbridge', message, 'error'); }
  handleSessionError(error) { const message = this.messageFrom(error).toLowerCase(); if (SESSION_ERROR_MARKERS.some((marker) => message.includes(marker))) { this.clearSession('Your administrator session ended. Please log in again.'); return true; } return false; }
  messageFrom(error) { return error?.body?.message || error?.message || 'The request could not be completed.'; }
  toast(title, message, variant) { this.dispatchEvent(new ShowToastEvent({ title, message, variant })); }
}