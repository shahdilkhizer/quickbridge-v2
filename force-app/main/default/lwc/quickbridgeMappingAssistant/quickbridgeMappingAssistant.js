import { LightningElement, api } from 'lwc';

export default class QuickbridgeMappingAssistant extends LightningElement {
  @api operation;
  @api connectorLabel;
  @api loading = false;
  @api errorMessage;
  @api allowApply = false;
  analysisValue;
  suggestions = [];
  showPrompt = false;

  @api
  get analysis() { return this.analysisValue; }
  set analysis(value) {
    this.analysisValue = value;
    this.showPrompt = false;
    this.suggestions = (value?.suggestions || []).map((item) => ({
      ...item, selected: false, disabled: item.canApply !== true,
      contextLabel: `${item.isLine ? 'Line item' : 'Parent'} · ${item.salesforceObject}`,
      confidenceClass: item.confidenceLabel === 'High' ? 'confidence high' : 'confidence medium'
    }));
  }
  get hasContext() { return Boolean(this.operation?.workspaceKey); }
  get displayConnectorLabel() { return this.connectorLabel || 'Mapping'; }
  get contextLabel() { const op = this.operation; return op ? `${op.label} · ${op.direction} · ${op.salesforceObject} → ${op.externalObject}` : ''; }
  get hasError() { return Boolean(this.errorMessage); }
  get isLoading() { return this.loading; }
  get hasAnalysis() { return Boolean(this.analysisValue) && !this.hasError && !this.loading; }
  get healthScore() { return this.analysisValue?.healthScore ?? '—'; }
  get statusText() { return this.hasError ? 'Analysis unavailable' : this.analysisValue?.status || 'Needs Context'; }
  get statusClass() { return `status-badge ${this.statusText.toLowerCase().replace(/\s+/g, '-')}`; }
  get requiredFieldsTotal() { return this.analysisValue?.requiredFieldsTotal || 0; }
  get requiredFieldsMapped() { return this.analysisValue?.requiredFieldsMapped || 0; }
  get missingRequiredFields() { return this.analysisValue?.missingRequiredFields || []; }
  get risks() { return this.analysisValue?.risks || []; }
  get hasMissingFields() { return this.missingRequiredFields.length > 0; }
  get hasRisks() { return this.risks.length > 0; }
  get hasSuggestions() { return this.suggestions.length > 0; }
  get limitedSchema() { return this.analysisValue?.limitedSchema; }
  get disableApply() { return !this.allowApply || !this.hasAnalysis || !this.suggestions.some((item) => item.canApply && item.confidence >= 80); }
  get disableApplySelected() { return !this.allowApply || !this.hasAnalysis || !this.suggestions.some((item) => item.selected && item.canApply); }
  get generatedPrompt() { return this.showPrompt ? this.analysisValue?.fixPrompt : ''; }
  handleRefresh() { this.dispatchEvent(new CustomEvent('review')); }
  handleSuggest() { this.handleRefresh(); }
  handleSuggestionToggle(event) {
    const key = event.currentTarget.dataset.key;
    this.suggestions = this.suggestions.map((item) => item.key === key && item.canApply ? { ...item, selected: event.currentTarget.checked } : item);
  }
  handleApplySelected() { this.emitSuggestions(this.suggestions.filter((item) => item.selected)); }
  handleApplyHighConfidence() { this.emitSuggestions(this.suggestions.filter((item) => item.confidence >= 80)); }
  emitSuggestions(suggestions) {
    if (!this.allowApply || !this.hasAnalysis) return;
    const applicable = suggestions.filter((item) => item.canApply);
    if (!applicable.length) return;
    this.dispatchEvent(new CustomEvent('applysuggestions', {
      detail: { workspaceKey: this.operation.workspaceKey, suggestions: applicable }
    }));
  }
  handleGeneratePrompt() { this.showPrompt = this.hasAnalysis; }
}