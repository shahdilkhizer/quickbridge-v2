import { LightningElement, api, track } from "lwc";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import getGatewayMappingConfig from "@salesforce/apex/QuickbridgeMappingFacade.getPaymentMappingConfig";
import getEligibleSourceObjects from "@salesforce/apex/QuickbridgeMappingFacade.getPaymentSourceObjects";
import getCreateableObjects from "@salesforce/apex/QuickbridgeMappingFacade.getPaymentTargetObjects";
import getObjectsWithLookupTo from "@salesforce/apex/QuickbridgeMappingFacade.getPaymentObjectsWithLookupTo";
import getObjectFields from "@salesforce/apex/QuickbridgeMappingFacade.getPaymentObjectFields";
import getLookupFields from "@salesforce/apex/QuickbridgeMappingFacade.getPaymentLookupFields";
import getEmailFields from "@salesforce/apex/QuickbridgeMappingFacade.getPaymentEmailFields";
import getPaymentGatewaySchema from "@salesforce/apex/QuickbridgeMappingFacade.getPaymentGatewaySchema";
import saveGatewayMappingConfig from "@salesforce/apex/QuickbridgeMappingFacade.savePaymentMappings";
import reviewPaymentMappings from "@salesforce/apex/QuickbridgeMappingFacade.reviewPaymentMappings";
import getDeploymentStatus from "@salesforce/apex/QuickbridgeMappingFacade.getDeploymentStatus";

const DEFAULT_SOURCE_OBJECT = "Order";
const DEFAULT_INVOICE_OBJECT = "Invoice__c";
const DEFAULT_TRANSACTION_OBJECT = "Portal_Payment_Transaction__c";
const NUMBER_TYPES = new Set([
  "CURRENCY",
  "DOUBLE",
  "INTEGER",
  "LONG",
  "PERCENT",
  "DECIMAL"
]);
const TEXT_TYPES = new Set([
  "STRING",
  "TEXTAREA",
  "LONGTEXTAREA",
  "HTML",
  "URL",
  "EMAIL",
  "PHONE",
  "PICKLIST",
  "ENCRYPTEDSTRING"
]);
export default class InvoiceMappingTool extends LightningElement {
  @api gateway = "stripe";
  @api sessionToken;

  @track config = {
    gateway: "stripe",
    sourceObject: DEFAULT_SOURCE_OBJECT,
    sourceCustomerLookupField: "",
    sourceCustomerTargetObject: "",
    sourceEmailField: "",
    invoiceObject: DEFAULT_INVOICE_OBJECT,
    invoiceSourceLookupField: "",
    transactionObject: DEFAULT_TRANSACTION_OBJECT,
    transactionSourceLookupField: "",
    sourceMappings: [],
    invoiceMappings: [],
    transactionMappings: []
  };
  @track sourceObjectOptions = [];
  @track targetObjectOptions = [];
  @track invoiceObjectOptions = [];
  @track transactionObjectOptions = [];
  @track customerLookupOptions = [];
  @track customerEmailOptions = [];
  @track sourceFieldOptions = [];
  @track invoiceLookupOptions = [];
  @track invoiceFieldOptions = [];
  @track transactionLookupOptions = [];
  @track transactionFieldOptions = [];
  @track invoiceRequestFieldOptions = [];
  @track gatewayTransactionFieldOptions = [];
  @track paymentSchema = {
    requestFields: [],
    invoiceResultFields: [],
    transactionFields: []
  };
  @track isLoading = false;
  @track isSaving = false;
  @track mappingAnalysis;
  @track mappingAnalysisLoading = false;
  @track mappingAnalysisError;
  @track sourceRows = [];
  @track invoiceRows = [];
  @track transactionRows = [];
  @track openSections = {
    source: true,
    invoice: false,
    transaction: false
  };
  savedMappingSignature;
  saveReviewOpen = false;

  useCustomSource = false;
  useCustomInvoice = false;
  useCustomTransaction = false;
  defaultSourceObject = DEFAULT_SOURCE_OBJECT;
  defaultInvoiceObject = DEFAULT_INVOICE_OBJECT;
  defaultTransactionObject = DEFAULT_TRANSACTION_OBJECT;
  analysisTimer;
  analysisGeneration = 0;

  connectedCallback() {
    this.loadInitialState();
  }

  disconnectedCallback() {
    clearTimeout(this.analysisTimer);
    this.analysisGeneration += 1;
  }

  get assistantOperation() {
    return {
      workspaceKey: "PaymentInvoice",
      label: "Hosted payment invoice",
      direction: "Source, Invoice, Transaction",
      salesforceObject: this.config.sourceObject || "Source",
      externalObject: `${this.gatewayLabel} hosted payment`
    };
  }

  get assistantCanApply() {
    return !this.isBusy && !this.mappingAnalysisLoading;
  }

  get mappingDirty() {
    return (
      Boolean(this.savedMappingSignature) &&
      this.currentMappingSignature() !== this.savedMappingSignature
    );
  }

  get requiredMapped() {
    return Number(this.mappingAnalysis?.requiredFieldsMapped || 0);
  }
  get requiredTotal() {
    return Number(this.mappingAnalysis?.requiredFieldsTotal || 0);
  }
  get mappingProgress() {
    return this.requiredTotal
      ? Math.round((this.requiredMapped * 100) / this.requiredTotal)
      : 0;
  }
  get blockerCount() {
    return (this.mappingAnalysis?.missingRequiredFields || []).length;
  }
  get warningCount() {
    return (this.mappingAnalysis?.risks || []).length;
  }
  get reviewSaveDisabled() {
    return (
      !this.mappingAnalysis ||
      Boolean(this.mappingAnalysisError) ||
      this.blockerCount > 0
    );
  }
  get sourceStepClass() {
    return this.isSourceComplete
      ? "guided-step complete"
      : "guided-step current";
  }
  get invoiceStepClass() {
    return this.isInvoiceLocked
      ? "guided-step locked"
      : this.invoiceRows.every((row) => row.sourceField && row.targetField)
        ? "guided-step complete"
        : "guided-step current";
  }
  get transactionStepClass() {
    return this.isTransactionLocked
      ? "guided-step locked"
      : this.transactionRows.every((row) => row.sourceField && row.targetField)
        ? "guided-step complete"
        : "guided-step current";
  }

  get gatewayLabel() {
    if (this.gateway === "authorizenet") return "Authorize.Net";
    if (this.gateway === "paypal") return "PayPal";
    return this.gateway === "stripe" ? "Stripe" : this.gateway;
  }

  get isAuthNet() {
    return this.gateway === "authorizenet";
  }

  get isPayPal() {
    return this.gateway === "paypal";
  }

  get saveButtonLabel() {
    return `Save ${this.gatewayLabel} Mappings`;
  }

  get invoiceRequiredRows() {
    return this.toRequiredRows(this.paymentSchema.invoiceResultFields);
  }

  get transactionRequiredRows() {
    return this.toRequiredRows(this.paymentSchema.transactionFields);
  }

  get sourceObjectValue() {
    return this.config.sourceObject;
  }

  get invoiceObjectValue() {
    return this.config.invoiceObject;
  }

  get transactionObjectValue() {
    return this.config.transactionObject;
  }

  get isSourceObjectDisabled() {
    return !this.useCustomSource;
  }

  get isInvoiceObjectDisabled() {
    return !this.useCustomInvoice;
  }

  get isTransactionObjectDisabled() {
    return !this.useCustomTransaction;
  }

  get isBusy() {
    return this.isLoading || this.isSaving;
  }

  get saveDisabled() {
    return (
      this.isBusy ||
      !this.config.sourceObject ||
      !this.config.sourceCustomerLookupField ||
      !this.config.sourceEmailField ||
      !this.config.invoiceObject ||
      !this.config.invoiceSourceLookupField ||
      !this.config.transactionObject ||
      !this.config.transactionSourceLookupField ||
      this.hasIncompleteRows(this.sourceRows) ||
      this.hasIncompleteRows(this.invoiceRows) ||
      this.hasIncompleteRows(this.transactionRows)
    );
  }

  get standardSourceChecked() {
    return !this.useCustomSource;
  }

  get standardInvoiceChecked() {
    return !this.useCustomInvoice;
  }

  get standardTransactionChecked() {
    return !this.useCustomTransaction;
  }

  get invoiceRecordSourceFieldOptions() {
    return this.paymentSchema.invoiceResultFields || [];
  }

  get sourceRowsWithOptions() {
    return (this.sourceRows || []).map((row) => ({
      ...row,
      filteredSourceOptions: this.sourceFieldOptions
    }));
  }

  get invoiceRowsWithOptions() {
    return (this.invoiceRows || []).map((row) => ({
      ...row,
      filteredTargetOptions: this.filterCompatibleOptions(
        this.invoiceFieldOptions,
        this.findOptionType(
          this.invoiceRecordSourceFieldOptions,
          row.sourceField
        )
      ),
      isPinned: row.isRequired,
      isTargetDisabled: row.lockTarget || (!row.lockSource && !row.sourceField)
    }));
  }

  get transactionRowsWithOptions() {
    return (this.transactionRows || []).map((row) => ({
      ...row,
      filteredTargetOptions: this.filterCompatibleOptions(
        this.transactionFieldOptions,
        this.findOptionType(
          this.gatewayTransactionFieldOptions,
          row.sourceField
        )
      ),
      isPinned: row.isRequired,
      isTargetDisabled: row.lockTarget || (!row.lockSource && !row.sourceField)
    }));
  }

  get sourceObjectUiOptions() {
    if (this.useCustomSource) return this.sourceObjectOptions;
    return [
      { label: "Order (Order)", value: this.defaultSourceObject },
      ...(this.sourceObjectOptions || [])
    ];
  }

  get hasNoCustomInvoiceObjects() {
    return (
      this.useCustomInvoice &&
      this.config.sourceObject &&
      this.invoiceObjectOptions.length === 0
    );
  }

  get hasNoCustomTransactionObjects() {
    return (
      this.useCustomTransaction &&
      this.config.sourceObject &&
      this.transactionObjectOptions.length === 0
    );
  }

  get isSourceComplete() {
    return Boolean(
      this.config.sourceObject &&
      this.config.sourceCustomerLookupField &&
      this.config.sourceEmailField &&
      this.requiredRowsComplete(this.sourceRows) &&
      !this.hasIncompleteRows(this.sourceRows)
    );
  }

  get isInvoiceLocked() {
    return !this.isSourceComplete;
  }

  get isTransactionLocked() {
    return !this.isSourceComplete;
  }

  get showSourceBody() {
    return this.openSections.source;
  }

  get showInvoiceBody() {
    return this.openSections.invoice && !this.isInvoiceLocked;
  }

  get showTransactionBody() {
    return this.openSections.transaction && !this.isTransactionLocked;
  }

  get sourceToggleIcon() {
    return this.showSourceBody ? "utility:chevrondown" : "utility:chevronright";
  }

  get invoiceToggleIcon() {
    return this.showInvoiceBody
      ? "utility:chevrondown"
      : "utility:chevronright";
  }

  get transactionToggleIcon() {
    return this.showTransactionBody
      ? "utility:chevrondown"
      : "utility:chevronright";
  }

  get invoiceSectionClass() {
    return this.isInvoiceLocked
      ? "mapping-section section-locked"
      : "mapping-section";
  }

  get transactionSectionClass() {
    return this.isTransactionLocked
      ? "mapping-section section-locked"
      : "mapping-section";
  }

  emptyConfig() {
    return {
      gateway: this.gateway || "stripe",
      sourceObject: DEFAULT_SOURCE_OBJECT,
      sourceCustomerLookupField: "",
      sourceCustomerTargetObject: "",
      sourceEmailField: "",
      invoiceObject: DEFAULT_INVOICE_OBJECT,
      invoiceSourceLookupField: "",
      transactionObject: DEFAULT_TRANSACTION_OBJECT,
      transactionSourceLookupField: "",
      sourceMappings: [],
      invoiceMappings: [],
      transactionMappings: []
    };
  }

  async loadInitialState() {
    this.isLoading = true;
    try {
      const [savedConfig, sourceObjects, targetObjects, schema] =
        await Promise.all([
          getGatewayMappingConfig({
            sessionToken: this.sessionToken,
            connectorKey: this.gateway
          }),
          getEligibleSourceObjects({ sessionToken: this.sessionToken }),
          getCreateableObjects({ sessionToken: this.sessionToken }),
          getPaymentGatewaySchema({
            sessionToken: this.sessionToken,
            connectorKey: this.gateway
          })
        ]);

      this.paymentSchema = schema || this.paymentSchema;
      this.config = { ...this.emptyConfig(), ...(savedConfig || {}) };
      this.sourceObjectOptions = sourceObjects || [];
      this.targetObjectOptions = targetObjects || [];
      this.defaultSourceObject = DEFAULT_SOURCE_OBJECT;
      this.defaultInvoiceObject = this.findDefaultObjectValue(
        this.targetObjectOptions,
        DEFAULT_INVOICE_OBJECT,
        "__Invoice__c"
      );
      this.defaultTransactionObject = this.findDefaultObjectValue(
        this.targetObjectOptions,
        DEFAULT_TRANSACTION_OBJECT,
        "__Portal_Payment_Transaction__c"
      );
      this.useCustomSource = !this.isDefaultSourceObject(
        this.config.sourceObject
      );
      this.useCustomInvoice = !this.isDefaultInvoiceObject(
        this.config.invoiceObject
      );
      this.useCustomTransaction = !this.isDefaultTransactionObject(
        this.config.transactionObject
      );
      this.invoiceRequestFieldOptions = this.paymentSchema.requestFields || [];
      this.gatewayTransactionFieldOptions =
        this.paymentSchema.transactionFields || [];
      this.sourceRows = this.withClientIds(this.config.sourceMappings);
      this.invoiceRows = this.withClientIds(this.config.invoiceMappings);
      this.transactionRows = this.withClientIds(
        this.config.transactionMappings
      );
      this.applyRequiredRows();

      await this.refreshDependentOptions();
      if (this.isSourceComplete) {
        this.openSections = { ...this.openSections, invoice: true };
      } else {
        this.syncLockedSections();
      }
      this.savedMappingSignature = this.currentMappingSignature();
    } catch (error) {
      this.showToast(
        "Error",
        this.getErrorMessage(error, "Failed to load invoice mapping setup."),
        "error"
      );
    } finally {
      this.isLoading = false;
      this.notifyMappingContextChange();
    }
  }

  async refreshDependentOptions() {
    await this.refreshSourceOptions();
    await this.refreshTargetObjectOptions();
    await this.refreshInvoiceOptions();
    await this.refreshTransactionOptions();
  }

  async refreshSourceOptions() {
    if (!this.config.sourceObject) return;
    const [sourceFields, customerLookups] = await Promise.all([
      getObjectFields({
        sessionToken: this.sessionToken,
        objectApiName: this.config.sourceObject
      }),
      getLookupFields({
        sessionToken: this.sessionToken,
        objectApiName: this.config.sourceObject,
        targetObjectApiName: null
      })
    ]);
    this.sourceFieldOptions = sourceFields || [];
    this.customerLookupOptions = customerLookups || [];
    await this.refreshCustomerEmailOptions();
  }

  async refreshCustomerEmailOptions() {
    if (!this.config.sourceObject) return;
    this.customerEmailOptions =
      (await getEmailFields({
        sessionToken: this.sessionToken,
        objectApiName: this.config.sourceObject,
        customerLookupField: this.config.sourceCustomerLookupField
      })) || [];
    if (!this.config.sourceEmailField) {
      const preferred = this.customerEmailOptions.find((option) =>
        (option.value || "").endsWith(".Email")
      );
      this.config = {
        ...this.config,
        sourceEmailField: preferred?.value || ""
      };
    }
  }

  async refreshTargetObjectOptions() {
    if (!this.config.sourceObject) {
      this.invoiceObjectOptions = [];
      this.transactionObjectOptions = [];
      return;
    }

    const objectsWithLookup = await getObjectsWithLookupTo({
      sessionToken: this.sessionToken,
      targetObjectApiName: this.config.sourceObject
    });
    const options = objectsWithLookup || [];
    this.invoiceObjectOptions = options;
    this.transactionObjectOptions = options;

    if (
      this.useCustomInvoice &&
      this.config.invoiceObject &&
      !this.hasOption(this.invoiceObjectOptions, this.config.invoiceObject)
    ) {
      this.config = {
        ...this.config,
        invoiceObject: "",
        invoiceSourceLookupField: ""
      };
      this.invoiceLookupOptions = [];
      this.invoiceFieldOptions = [];
    }
    if (
      this.useCustomTransaction &&
      this.config.transactionObject &&
      !this.hasOption(
        this.transactionObjectOptions,
        this.config.transactionObject
      )
    ) {
      this.config = {
        ...this.config,
        transactionObject: "",
        transactionSourceLookupField: ""
      };
      this.transactionLookupOptions = [];
      this.transactionFieldOptions = [];
    }
  }

  async refreshInvoiceOptions() {
    if (!this.config.invoiceObject || !this.config.sourceObject) return;
    const [invoiceFields, invoiceLookups] = await Promise.all([
      getObjectFields({
        sessionToken: this.sessionToken,
        objectApiName: this.config.invoiceObject
      }),
      getLookupFields({
        sessionToken: this.sessionToken,
        objectApiName: this.config.invoiceObject,
        targetObjectApiName: this.config.sourceObject
      })
    ]);
    this.invoiceFieldOptions = invoiceFields || [];
    this.invoiceLookupOptions = invoiceLookups || [];
    this.invoiceRows = this.normalizeRequiredTargets(
      this.invoiceRows,
      this.invoiceRequiredRows,
      this.invoiceFieldOptions,
      this.useCustomInvoice
    );
    if (
      !this.config.invoiceSourceLookupField &&
      this.invoiceLookupOptions.length === 1
    ) {
      this.config = {
        ...this.config,
        invoiceSourceLookupField: this.invoiceLookupOptions[0].value
      };
    }
  }

  async refreshTransactionOptions() {
    if (!this.config.transactionObject || !this.config.sourceObject) return;
    const [transactionFields, transactionLookups] = await Promise.all([
      getObjectFields({
        sessionToken: this.sessionToken,
        objectApiName: this.config.transactionObject
      }),
      getLookupFields({
        sessionToken: this.sessionToken,
        objectApiName: this.config.transactionObject,
        targetObjectApiName: this.config.sourceObject
      })
    ]);
    this.transactionFieldOptions = transactionFields || [];
    this.transactionLookupOptions = transactionLookups || [];
    this.transactionRows = this.normalizeRequiredTargets(
      this.transactionRows,
      this.transactionRequiredRows,
      this.transactionFieldOptions,
      this.useCustomTransaction
    );
    if (
      !this.config.transactionSourceLookupField &&
      this.transactionLookupOptions.length === 1
    ) {
      this.config = {
        ...this.config,
        transactionSourceLookupField: this.transactionLookupOptions[0].value
      };
    }
  }

  handleToggleSection(event) {
    const section = event.currentTarget.dataset.section;
    if (
      (section === "invoice" || section === "transaction") &&
      !this.isSourceComplete
    ) {
      this.showSourceLockToast();
      this.syncLockedSections();
      return;
    }

    this.openSections = {
      ...this.openSections,
      [section]: !this.openSections[section]
    };
  }

  async handleSourceModeChange(event) {
    this.useCustomSource = !event.target.checked;
    this.config = {
      ...this.config,
      sourceObject: this.useCustomSource ? "" : this.defaultSourceObject,
      sourceCustomerLookupField: "",
      sourceCustomerTargetObject: "",
      sourceEmailField: "",
      invoiceSourceLookupField: "",
      transactionSourceLookupField: ""
    };
    this.customerLookupOptions = [];
    this.invoiceLookupOptions = [];
    this.transactionLookupOptions = [];
    if (this.config.sourceObject) {
      await this.refreshDependentOptions();
    }
    this.syncLockedSections();
  }

  async handleInvoiceModeChange(event) {
    if (this.isInvoiceLocked) {
      this.showSourceLockToast();
      return;
    }
    this.useCustomInvoice = !event.target.checked;
    this.config = {
      ...this.config,
      invoiceObject: this.useCustomInvoice ? "" : this.defaultInvoiceObject,
      invoiceSourceLookupField: ""
    };
    this.invoiceLookupOptions = [];
    this.invoiceFieldOptions = [];
    if (this.useCustomInvoice) {
      await this.refreshTargetObjectOptions();
    }
    if (this.config.invoiceObject) {
      await this.refreshInvoiceOptions();
    }
  }

  async handleTransactionModeChange(event) {
    if (this.isTransactionLocked) {
      this.showSourceLockToast();
      return;
    }
    this.useCustomTransaction = !event.target.checked;
    this.config = {
      ...this.config,
      transactionObject: this.useCustomTransaction
        ? ""
        : this.defaultTransactionObject,
      transactionSourceLookupField: ""
    };
    this.transactionLookupOptions = [];
    this.transactionFieldOptions = [];
    if (this.useCustomTransaction) {
      await this.refreshTargetObjectOptions();
    }
    if (this.config.transactionObject) {
      await this.refreshTransactionOptions();
    }
  }

  async handleSourceObjectChange(event) {
    this.config = {
      ...this.config,
      sourceObject: event.detail.value,
      sourceCustomerLookupField: "",
      sourceCustomerTargetObject: "",
      invoiceSourceLookupField: "",
      transactionSourceLookupField: ""
    };
    this.config = {
      ...this.config,
      invoiceObject: this.useCustomInvoice ? "" : this.defaultInvoiceObject,
      transactionObject: this.useCustomTransaction
        ? ""
        : this.defaultTransactionObject
    };
    await this.refreshDependentOptions();
    this.syncLockedSections();
    this.notifyMappingContextChange();
  }

  async handleCustomerLookupChange(event) {
    const selected = this.customerLookupOptions.find(
      (option) => option.value === event.detail.value
    );
    this.config = {
      ...this.config,
      sourceCustomerLookupField: event.detail.value,
      sourceCustomerTargetObject: selected?.referenceTo || ""
    };
    await this.refreshCustomerEmailOptions();
    this.syncLockedSections();
    this.notifyMappingContextChange();
  }

  handleCustomerEmailChange(event) {
    this.config = {
      ...this.config,
      sourceEmailField: event.detail.value
    };
    this.syncLockedSections();
    this.notifyMappingContextChange();
  }

  async handleInvoiceObjectChange(event) {
    if (this.isInvoiceLocked) {
      this.showSourceLockToast();
      return;
    }
    this.config = {
      ...this.config,
      invoiceObject: event.detail.value,
      invoiceSourceLookupField: ""
    };
    await this.refreshInvoiceOptions();
    this.notifyMappingContextChange();
  }

  handleInvoiceLookupChange(event) {
    if (this.isInvoiceLocked) {
      this.showSourceLockToast();
      return;
    }
    this.config = {
      ...this.config,
      invoiceSourceLookupField: event.detail.value
    };
    this.notifyMappingContextChange();
  }

  async handleTransactionObjectChange(event) {
    if (this.isTransactionLocked) {
      this.showSourceLockToast();
      return;
    }
    this.config = {
      ...this.config,
      transactionObject: event.detail.value,
      transactionSourceLookupField: ""
    };
    await this.refreshTransactionOptions();
    this.notifyMappingContextChange();
  }

  handleTransactionLookupChange(event) {
    if (this.isTransactionLocked) {
      this.showSourceLockToast();
      return;
    }
    this.config = {
      ...this.config,
      transactionSourceLookupField: event.detail.value
    };
    this.notifyMappingContextChange();
  }

  addSourceRow() {
    this.sourceRows = [...this.sourceRows, this.newRow(false, "source")];
    this.syncLockedSections();
    this.notifyMappingContextChange();
  }

  addInvoiceRow() {
    if (this.isInvoiceLocked) {
      this.showSourceLockToast();
      return;
    }
    this.invoiceRows = [...this.invoiceRows, this.newRow(false, "invoice")];
    this.notifyMappingContextChange();
  }

  addTransactionRow() {
    if (this.isTransactionLocked) {
      this.showSourceLockToast();
      return;
    }
    this.transactionRows = [
      ...this.transactionRows,
      this.newRow(false, "transaction")
    ];
    this.notifyMappingContextChange();
  }

  removeSourceRow(event) {
    this.sourceRows = this.removeRow(
      this.sourceRows,
      event.currentTarget.dataset.id,
      "source"
    );
    this.syncLockedSections();
    this.notifyMappingContextChange();
  }

  removeInvoiceRow(event) {
    if (this.isInvoiceLocked) {
      this.showSourceLockToast();
      return;
    }
    this.invoiceRows = this.removeRow(
      this.invoiceRows,
      event.currentTarget.dataset.id,
      "invoice"
    );
    this.notifyMappingContextChange();
  }

  removeTransactionRow(event) {
    if (this.isTransactionLocked) {
      this.showSourceLockToast();
      return;
    }
    this.transactionRows = this.removeRow(
      this.transactionRows,
      event.currentTarget.dataset.id,
      "transaction"
    );
    this.notifyMappingContextChange();
  }

  handleSourceRowChange(event) {
    this.sourceRows = this.updateRow(this.sourceRows, event);
    this.syncLockedSections();
    this.notifyMappingContextChange();
  }

  handleInvoiceRowChange(event) {
    if (this.isInvoiceLocked) {
      this.showSourceLockToast();
      return;
    }
    this.invoiceRows = this.updateRow(
      this.invoiceRows,
      event,
      this.invoiceRecordSourceFieldOptions,
      this.invoiceFieldOptions
    );
    this.notifyMappingContextChange();
  }

  handleTransactionRowChange(event) {
    if (this.isTransactionLocked) {
      this.showSourceLockToast();
      return;
    }
    this.transactionRows = this.updateRow(
      this.transactionRows,
      event,
      this.gatewayTransactionFieldOptions,
      this.transactionFieldOptions
    );
    this.notifyMappingContextChange();
  }

  async handleSave() {
    const duplicateMessage =
      this.findDuplicateMessage(this.sourceRows, "source invoice request") ||
      this.findDuplicateMessage(this.invoiceRows, "invoice record") ||
      this.findDuplicateMessage(this.transactionRows, "payment transaction");

    if (duplicateMessage) {
      this.showToast("Duplicate Mapping", duplicateMessage, "error");
      return;
    }

    await this.handleReviewPaymentMappings();
    this.saveReviewOpen = true;
  }

  closeSaveReview() {
    this.saveReviewOpen = false;
  }

  async confirmSave() {
    if (this.reviewSaveDisabled) return;
    this.saveReviewOpen = false;

    this.isSaving = true;
    try {
      const payload = {
        ...this.config,
        gateway: this.gateway,
        sourceMappings: this.cleanRows(this.sourceRows),
        invoiceMappings: this.cleanRows(this.invoiceRows),
        transactionMappings: this.cleanRows(this.transactionRows)
      };
      const response = await saveGatewayMappingConfig({
        sessionToken: this.sessionToken,
        requestJson: JSON.stringify(payload)
      });
      await this.pollPaymentDeployment(response?.deploymentId);
    } catch (error) {
      this.showToast(
        "Save Failed",
        this.getErrorMessage(
          error,
          `Could not save ${this.gatewayLabel} invoice mappings.`
        ),
        "error"
      );
    } finally {
      this.isSaving = false;
    }
  }

  withClientIds(rows = []) {
    return (rows || []).map((row) => ({
      ...row,
      id: row.developerName || this.rowId(),
      isRequired: row.isRequired === true
    }));
  }

  newRow(isRequired = false, sectionName = "") {
    return {
      id: this.rowId(),
      sourceField: "",
      targetField: "",
      isRequired,
      sectionName
    };
  }

  rowId() {
    return String(Date.now()) + "-" + String(Math.random()).slice(2);
  }

  updateRow(rows, event, sourceOptions = [], targetOptions = []) {
    const id = event.currentTarget.dataset.id;
    const field = event.currentTarget.dataset.field;
    const value = event.detail.value;
    return rows.map((row) => {
      if (row.id !== id) return row;
      if (field === "sourceField" && row.lockSource) return row;
      if (field === "targetField" && row.lockTarget) return row;
      const updatedRow = { ...row, [field]: value };
      if (
        field === "sourceField" &&
        updatedRow.targetField &&
        !this.isTargetCompatible(
          value,
          updatedRow.targetField,
          sourceOptions,
          targetOptions
        )
      ) {
        updatedRow.targetField = "";
      }
      return updatedRow;
    });
  }

  removeRow(rows, id, sectionName) {
    const rowToRemove = rows.find((candidate) => candidate.id === id);
    if (rowToRemove?.isRequired) return rows;
    const filtered = rows.filter((candidate) => candidate.id !== id);
    return filtered.length ? filtered : [this.newRow(false, sectionName)];
  }

  cleanRows(rows) {
    return (rows || [])
      .filter((row) => row.sourceField && row.targetField)
      .map((row) => ({
        sourceField: row.sourceField,
        targetField: row.targetField,
        isRequired: row.isRequired === true
      }));
  }

  hasIncompleteRows(rows) {
    return (rows || []).some((row) => {
      if (row.isOptional) return false;
      return (
        (row.sourceField && !row.targetField) ||
        (!row.sourceField && row.targetField)
      );
    });
  }

  requiredRowsComplete(rows) {
    return (rows || [])
      .filter((row) => row.isRequired)
      .every((row) => row.sourceField && row.targetField);
  }

  syncLockedSections() {
    if (this.isSourceComplete) return;
    this.openSections = {
      ...this.openSections,
      invoice: false,
      transaction: false
    };
  }

  showSourceLockToast() {
    this.showToast(
      "Complete Source Setup",
      "Complete the source object, customer lookup, and required invoice request mapping before configuring invoice or payment transaction objects.",
      "warning"
    );
  }

  findDuplicateMessage(rows, label) {
    const sources = new Set();
    const targets = new Set();
    for (const row of rows || []) {
      if (!row.sourceField || !row.targetField) continue;
      if (sources.has(row.sourceField))
        return `Each ${label} source field can only be mapped once.`;
      if (targets.has(row.targetField))
        return `Each ${label} target field can only be mapped once.`;
      sources.add(row.sourceField);
      targets.add(row.targetField);
    }
    return "";
  }

  findOptionType(options, value) {
    return (options || []).find((option) => option.value === value)?.type || "";
  }

  filterCompatibleOptions(options, sourceType) {
    if (!sourceType) return options || [];
    return (options || []).filter((option) =>
      this.areTypesCompatible(sourceType, option.type)
    );
  }

  isTargetCompatible(sourceField, targetField, sourceOptions, targetOptions) {
    const sourceType = this.findOptionType(sourceOptions, sourceField);
    const targetType = this.findOptionType(targetOptions, targetField);
    if (!sourceType || !targetType) return true;
    return this.areTypesCompatible(sourceType, targetType);
  }

  areTypesCompatible(sourceType, targetType) {
    const normalizedSource = this.normalizeFieldType(sourceType);
    const normalizedTarget = this.normalizeFieldType(targetType);
    if (!normalizedSource || !normalizedTarget) return true;
    if (NUMBER_TYPES.has(normalizedSource)) {
      return NUMBER_TYPES.has(normalizedTarget);
    }
    if (TEXT_TYPES.has(normalizedSource)) {
      return TEXT_TYPES.has(normalizedTarget);
    }
    if (normalizedSource === "BOOLEAN") {
      return normalizedTarget === "BOOLEAN";
    }
    if (normalizedSource === "DATE" || normalizedSource === "DATETIME") {
      return normalizedTarget === normalizedSource;
    }
    return normalizedSource === normalizedTarget;
  }

  normalizeFieldType(type) {
    return (type || "").replace(/\s+/g, "").toUpperCase();
  }

  isDefaultSourceObject(objectApiName) {
    return objectApiName === DEFAULT_SOURCE_OBJECT;
  }

  isDefaultInvoiceObject(objectApiName) {
    return (
      objectApiName === DEFAULT_INVOICE_OBJECT ||
      (objectApiName || "").endsWith("__Invoice__c")
    );
  }

  isDefaultTransactionObject(objectApiName) {
    return (
      objectApiName === DEFAULT_TRANSACTION_OBJECT ||
      (objectApiName || "").endsWith("__Portal_Payment_Transaction__c")
    );
  }

  findDefaultObjectValue(options, plainName, namespacedSuffix) {
    const direct = (options || []).find((option) => option.value === plainName);
    if (direct) return direct.value;
    const namespaced = (options || []).find((option) =>
      (option.value || "").endsWith(namespacedSuffix)
    );
    return namespaced?.value || plainName;
  }

  applyRequiredRows() {
    this.sourceRows = this.mergeRequiredRows(
      this.sourceRows,
      this.toSourceRows(this.paymentSchema.requestFields),
      "source"
    );
    this.invoiceRows = this.mergeRequiredRows(
      this.invoiceRows,
      this.invoiceRequiredRows,
      "invoice"
    );
    this.transactionRows = this.mergeRequiredRows(
      this.transactionRows,
      this.transactionRequiredRows,
      "transaction"
    );
  }

  toSourceRows(fields = []) {
    return (fields || []).map((field) => ({
      sourceField: "",
      targetField: field.value,
      targetLabel: field.label,
      requiredSide: "target",
      isOptional: field.required !== true
    }));
  }

  toRequiredRows(fields = []) {
    return (fields || []).map((field) => ({
      sourceField: field.value,
      targetField: field.defaultTargetField || "",
      sourceLabel: field.label,
      isOptional: field.required !== true
    }));
  }

  mergeRequiredRows(existingRows, requiredDefinitions, sectionName) {
    const rows = [...(existingRows || [])];
    const merged = [];

    requiredDefinitions.forEach((definition) => {
      const isOptional = definition.isOptional === true;
      const savedRow = rows.find((row) => {
        if (definition.requiredSide === "target")
          return row.targetField === definition.targetField;
        return row.sourceField === definition.sourceField;
      });
      if (savedRow) {
        merged.push({
          ...savedRow,
          id: savedRow.id || this.rowId(),
          isRequired: !isOptional,
          isOptional,
          requiredSide: definition.requiredSide || "source",
          lockSource: definition.requiredSide !== "target",
          lockTarget: definition.requiredSide === "target",
          sourceLabel: definition.sourceLabel,
          targetLabel: definition.targetLabel,
          sourceField:
            definition.requiredSide === "target"
              ? savedRow.sourceField
              : definition.sourceField,
          targetField: this.resolveDefaultField(
            savedRow.targetField || definition.targetField
          )
        });
      } else {
        merged.push({
          id: this.rowId(),
          sourceField: definition.sourceField,
          targetField: this.resolveDefaultField(definition.targetField),
          isRequired: !isOptional,
          isOptional,
          sectionName,
          requiredSide: definition.requiredSide || "source",
          lockSource: definition.requiredSide !== "target",
          lockTarget: definition.requiredSide === "target",
          sourceLabel: definition.sourceLabel,
          targetLabel: definition.targetLabel
        });
      }
    });

    rows.forEach((row) => {
      const isRequiredDuplicate = requiredDefinitions.some((definition) => {
        if (definition.requiredSide === "target")
          return row.targetField === definition.targetField;
        return row.sourceField === definition.sourceField;
      });
      if (!isRequiredDuplicate) {
        merged.push({
          ...row,
          id: row.id || this.rowId(),
          isRequired: false,
          sectionName
        });
      }
    });

    return merged;
  }

  normalizeRequiredTargets(rows, definitions, options, isCustomObject) {
    return (rows || []).map((row) => {
      if (!row.isRequired || row.lockTarget) return row;
      const definition = definitions.find(
        (candidate) => candidate.sourceField === row.sourceField
      );
      if (!definition) return row;
      const resolvedField = this.resolveFieldFromOptions(
        row.targetField || definition.targetField,
        options
      );
      if (resolvedField) {
        return { ...row, targetField: resolvedField };
      }
      if (isCustomObject) {
        return { ...row, targetField: "" };
      }
      return row;
    });
  }

  resolveDefaultField(fieldName) {
    if (!fieldName) return fieldName;
    const options = [
      ...(this.invoiceFieldOptions || []),
      ...(this.transactionFieldOptions || [])
    ];
    const direct = options.find((option) => option.value === fieldName);
    if (direct) return direct.value;
    const namespaced = options.find((option) =>
      (option.value || "").endsWith("__" + fieldName)
    );
    return namespaced?.value || fieldName;
  }

  resolveFieldFromOptions(fieldName, options) {
    if (!fieldName) return "";
    const direct = (options || []).find((option) => option.value === fieldName);
    if (direct) return direct.value;
    const namespaced = (options || []).find((option) =>
      (option.value || "").endsWith("__" + fieldName)
    );
    return namespaced?.value || "";
  }

  hasOption(options, value) {
    return (options || []).some((option) => option.value === value);
  }

  getErrorMessage(error, fallback) {
    if (error?.body?.message) return error.body.message;
    if (Array.isArray(error?.body) && error.body.length) {
      return error.body
        .map((item) => item.message)
        .filter(Boolean)
        .join(" ");
    }
    return error?.message || fallback;
  }

  showToast(title, message, variant) {
    this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
  }

  notifyMappingContextChange() {
    const mappings = [
      ...this.sourceRows.map((row) => ({
        sfField: row.sourceField,
        externalField: row.targetField,
        syncDirection: "Source",
        isMandatory: row.isRequired
      })),
      ...this.invoiceRows.map((row) => ({
        sfField: row.sourceField,
        externalField: row.targetField,
        syncDirection: "Invoice",
        isMandatory: row.isRequired
      })),
      ...this.transactionRows.map((row) => ({
        sfField: row.sourceField,
        externalField: row.targetField,
        syncDirection: "Transaction",
        isMandatory: row.isRequired
      }))
    ];
    this.dispatchEvent(
      new CustomEvent("mappingcontextchange", {
        bubbles: true,
        composed: true,
        detail: {
          connectorKey: this.gateway,
          connectorLabel: this.gatewayLabel,
          salesforceObject: this.config.sourceObject,
          externalObject: "paymentInvoice",
          syncDirection: null,
          allowApply: false,
          mappings
        }
      })
    );
    this.dispatchEvent(
      new CustomEvent("mappingdirtychange", {
        bubbles: true,
        composed: true,
        detail: { dirty: this.mappingDirty }
      })
    );
    this.schedulePaymentReview();
  }

  currentMappingSignature() {
    return JSON.stringify(this.paymentReviewRequest());
  }

  paymentReviewRequest() {
    return {
      ...this.config,
      gateway: this.gateway,
      sourceMappings: (this.sourceRows || []).map((row) => ({
        sourceField: row.sourceField || "",
        targetField: row.targetField || "",
        isRequired: row.isRequired === true
      })),
      invoiceMappings: (this.invoiceRows || []).map((row) => ({
        sourceField: row.sourceField || "",
        targetField: row.targetField || "",
        isRequired: row.isRequired === true
      })),
      transactionMappings: (this.transactionRows || []).map((row) => ({
        sourceField: row.sourceField || "",
        targetField: row.targetField || "",
        isRequired: row.isRequired === true
      }))
    };
  }

  async pollPaymentDeployment(deploymentId) {
    if (!deploymentId) {
      await this.loadInitialState();
      return;
    }
    /* eslint-disable no-await-in-loop */
    for (let attempt = 0; attempt < 5; attempt += 1) {
      const status = await getDeploymentStatus({
        sessionToken: this.sessionToken,
        deploymentId
      });
      if (status.status === "Succeeded") {
        await this.loadInitialState();
        this.showToast(
          "Mappings Saved",
          `${this.gatewayLabel} payment mappings were deployed and reloaded.`,
          "success"
        );
        return;
      }
      if (status.status === "Failed") {
        throw new Error(status.message || "Payment mapping deployment failed.");
      }
      await new Promise((resolve) => {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(resolve, 1500);
      });
    }
    /* eslint-enable no-await-in-loop */
    this.showToast(
      "Mapping Deployment Pending",
      "The mapping deployment is still running. Refresh the mapping screen to read back its status.",
      "info"
    );
  }

  schedulePaymentReview(delay = 300) {
    clearTimeout(this.analysisTimer);
    if (!this.sessionToken || this.isLoading) return;
    this.mappingAnalysisLoading = true;
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    this.analysisTimer = setTimeout(
      () => this.handleReviewPaymentMappings(),
      delay
    );
  }

  async handleReviewPaymentMappings() {
    clearTimeout(this.analysisTimer);
    if (!this.sessionToken) return;
    const requestJson = JSON.stringify(this.paymentReviewRequest());
    const generation = ++this.analysisGeneration;
    this.mappingAnalysisLoading = true;
    this.mappingAnalysisError = undefined;
    try {
      const result = await reviewPaymentMappings({
        sessionToken: this.sessionToken,
        requestJson
      });
      if (generation !== this.analysisGeneration) return;
      this.mappingAnalysis = result;
    } catch (error) {
      if (generation !== this.analysisGeneration) return;
      this.mappingAnalysis = undefined;
      this.mappingAnalysisError = this.getErrorMessage(
        error,
        "Payment mapping analysis is unavailable."
      );
    } finally {
      if (generation === this.analysisGeneration) {
        this.mappingAnalysisLoading = false;
      }
    }
  }

  handleApplyPaymentSuggestions(event) {
    const suggestions = event.detail?.suggestions || [];
    let sourceRows = [...this.sourceRows];
    let invoiceRows = [...this.invoiceRows];
    let transactionRows = [...this.transactionRows];
    suggestions.forEach((suggestion) => {
      const section = (suggestion.workspaceKey || "").split("|")[1];
      if (section === "Source") {
        sourceRows = sourceRows.map((row) => {
          return row.targetField === suggestion.externalPath
            ? { ...row, sourceField: suggestion.salesforceField }
            : row;
        });
      } else if (section === "Invoice") {
        invoiceRows = invoiceRows.map((row) => {
          return row.sourceField === suggestion.externalPath
            ? { ...row, targetField: suggestion.salesforceField }
            : row;
        });
      } else if (section === "Transaction") {
        transactionRows = transactionRows.map((row) => {
          return row.sourceField === suggestion.externalPath
            ? { ...row, targetField: suggestion.salesforceField }
            : row;
        });
      }
    });
    this.sourceRows = sourceRows;
    this.invoiceRows = invoiceRows;
    this.transactionRows = transactionRows;
    this.syncLockedSections();
    this.showToast(
      "Draft Updated",
      "Suggestions were applied to the draft. Click Save Mappings to deploy them.",
      "info"
    );
    this.notifyMappingContextChange();
  }
}