import { LightningElement, api } from 'lwc';
import getWorkspace from '@salesforce/apex/CarrierMappingController.getWorkspace';
import getMappings from '@salesforce/apex/CarrierMappingController.getMappings';
import saveMappings from '@salesforce/apex/CarrierMappingController.saveMappings';

export default class CarrierOperationMapping extends LightningElement {
  @api connectorKey;
  operations = [];
  objectOptions = [];
  fieldOptions = [];
  selectedObject;
  selectedOperation;
  rows = [];
  loading = true;
  saving = false;
  error;

  connectedCallback() { this.load(); }
  async load() {
    this.loading = true; this.error = undefined;
    try {
      const workspace = await getWorkspace({ connectorKey: this.connectorKey, salesforceObject: this.selectedObject });
      this.operations = (workspace.operations || []).map((item) => ({ ...item, label: item.label, value: item.operationKey }));
      this.objectOptions = workspace.objects || [];
      this.fieldOptions = workspace.fields || [];
      this.selectedOperation ||= this.operations[0]?.value;
      if (this.selectedObject && this.selectedOperation) await this.refreshMappings();
    } catch (error) { this.error = error?.body?.message || error?.message || 'Carrier mappings could not be loaded.'; }
    finally { this.loading = false; }
  }
  async refreshMappings() {
    const rows = await getMappings({ connectorKey: this.connectorKey, operationKey: this.selectedOperation, salesforceObject: this.selectedObject });
    this.rows = (rows || []).map((row, index) => ({ ...row, key: `${index}-${row.salesforceField}-${row.externalPath}` }));
  }
  async changeObject(event) { this.selectedObject = event.detail.value; this.rows = []; await this.load(); }
  async changeOperation(event) { this.selectedOperation = event.detail.value; if (this.selectedObject) await this.refreshMappings(); }
  addRow() { this.rows = [...this.rows, { key: `new-${Date.now()}`, salesforceField: undefined, externalPath: undefined, direction: 'Outbound', active: true }]; }
  removeRow(event) { this.rows = this.rows.filter((row) => row.key !== event.currentTarget.dataset.key); }
  changeRow(event) { const { key, field } = event.currentTarget.dataset; const value = field === 'active' ? event.target.checked : event.detail?.value; this.rows = this.rows.map((row) => (row.key === key ? { ...row, [field]: value } : row)); }
  get disabled() { return this.loading || this.saving || !this.selectedObject || !this.selectedOperation; }
  get selectedDefinition() { return this.operations.find((item) => item.value === this.selectedOperation); }
  get requestPaths() { return this.selectedDefinition?.requiredRequestPaths || 'No source fields are required; this action uses the selected carrier shipment.'; }
  get responsePaths() { return this.selectedDefinition?.responsePaths || 'No response fields are required; the carrier record is updated automatically.'; }
  get directionOptions() { return [{ label: 'Salesforce to carrier', value: 'Outbound' }, { label: 'Carrier to Salesforce', value: 'Inbound' }, { label: 'Both', value: 'Both' }]; }
  async save() {
    this.saving = true; this.error = undefined;
    try {
      const mappings = this.rows.map((row) => {
        const mapped = { ...row };
        delete mapped.key;
        return mapped;
      });
      const response = await saveMappings({ requestJson: JSON.stringify({ connectorKey: this.connectorKey, operationKey: this.selectedOperation, salesforceObject: this.selectedObject, mappings }) });
      this.error = response?.deploymentId ? 'Mapping deployment queued. Refresh this page after the deployment completes.' : undefined;
    } catch (error) { this.error = error?.body?.message || error?.message || 'Carrier mappings could not be saved.'; }
    finally { this.saving = false; }
  }
}