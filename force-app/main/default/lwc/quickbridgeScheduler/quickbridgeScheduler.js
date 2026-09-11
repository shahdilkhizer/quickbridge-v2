import { LightningElement, api } from "lwc";
import LightningConfirm from "lightning/confirm";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import getScheduleWorkspace from "@salesforce/apex/QuickbridgeScheduleController.getScheduleWorkspace";
import saveSchedule from "@salesforce/apex/QuickbridgeScheduleController.saveSchedule";
import setScheduleState from "@salesforce/apex/QuickbridgeScheduleController.setScheduleState";
import deleteSchedule from "@salesforce/apex/QuickbridgeScheduleController.deleteSchedule";
import getRecentRuns from "@salesforce/apex/QuickbridgeScheduleController.getRecentRuns";
import previewSchedule from "@salesforce/apex/QuickbridgeScheduleController.previewSchedule";

export default class QuickbridgeScheduler extends LightningElement {
  @api sessionToken;
  @api connectorKey;
  workspace = { objects: [], directions: [], frequencies: [], schedules: [] };
  schedules = [];
  filteredSchedules = [];
  recentRuns = [];
  selectedScheduleId;
  loading = true;
  editing = false;
  searchTerm = "";
  statusFilter = "All";
  errorMessage;
  draft = {};
  previewRuns = [];
  statusOptions = [
    { label: "All", value: "All" },
    { label: "Active", value: "Active" },
    { label: "Paused", value: "Paused" }
  ];

  connectedCallback() {
    this.load();
  }
  get hasSchedules() {
    return this.filteredSchedules.length > 0;
  }
  get selectedSchedule() {
    return this.schedules.find((item) => item.id === this.selectedScheduleId);
  }
  get editorTitle() {
    return this.draft.scheduleId ? "Edit Schedule" : "New Schedule";
  }
  get saveDisabled() {
    return (
      !this.draft.sourceObject ||
      !this.draft.direction ||
      !this.draft.frequencyValue ||
      !this.draft.frequencyType ||
      this.loading
    );
  }
  get hasRecentRuns() {
    return this.recentRuns.length > 0;
  }
  get hasPreview() {
    return this.previewRuns.length > 0;
  }

  async load() {
    this.loading = true;
    this.errorMessage = undefined;
    try {
      this.workspace = await getScheduleWorkspace({
        sessionToken: this.sessionToken,
        connectorKey: this.connectorKey
      });
      this.schedules = (this.workspace.schedules || []).map((item) => ({
        ...item,
        pauseLabel: item.status === "Paused" ? "Resume" : "Pause",
        isPaused: item.status === "Paused"
      }));
      this.filter();
    } catch (error) {
      this.errorMessage = this.messageFrom(error);
    } finally {
      this.loading = false;
    }
  }
  filter() {
    const search = this.searchTerm.toLowerCase();
    this.filteredSchedules = this.schedules.filter(
      (item) =>
        (this.statusFilter === "All" ||
          (this.statusFilter === "Active"
            ? item.status !== "Paused"
            : item.status === "Paused")) &&
        (!search ||
          String(item.name).toLowerCase().includes(search) ||
          String(item.sourceObject).toLowerCase().includes(search))
    );
  }
  handleSearch(event) {
    this.searchTerm = event.target.value || "";
    this.filter();
  }
  handleStatus(event) {
    this.statusFilter = event.detail.value;
    this.filter();
  }
  newSchedule() {
    this.draft = {
      connectorKey: this.connectorKey,
      frequencyValue: 1,
      frequencyType: "Hours"
    };
    this.editing = true;
    this.recentRuns = [];
    this.loadPreview();
  }
  edit(event) {
    const row = this.schedules.find(
      (item) => item.id === event.currentTarget.dataset.id
    );
    this.draft = {
      scheduleId: row.id,
      connectorKey: this.connectorKey,
      sourceObject: row.sourceObject,
      direction: row.direction,
      frequencyValue: row.frequencyValue,
      frequencyType: row.frequencyType,
      schedulerName: row.name
    };
    this.editing = true;
    this.loadPreview();
  }
  cancel() {
    this.editing = false;
    this.draft = {};
  }
  change(event) {
    const field = event.currentTarget.dataset.field;
    this.draft = {
      ...this.draft,
      [field]: event.detail?.value ?? event.target.value
    };
    if (field === "frequencyValue" || field === "frequencyType")
      this.loadPreview();
  }
  async loadPreview() {
    if (!this.draft.frequencyValue || !this.draft.frequencyType) {
      this.previewRuns = [];
      return;
    }
    try {
      const result = await previewSchedule({
        sessionToken: this.sessionToken,
        frequencyValue: this.draft.frequencyValue,
        frequencyType: this.draft.frequencyType,
        fromTime: null
      });
      this.previewRuns = result.nextRuns || [];
    } catch {
      this.previewRuns = [];
    }
  }
  async save() {
    this.loading = true;
    try {
      await saveSchedule({
        sessionToken: this.sessionToken,
        requestJson: JSON.stringify(this.draft)
      });
      this.toast(
        "Schedule saved",
        "The logical schedule was saved without replacing its history.",
        "success"
      );
      this.editing = false;
      await this.load();
    } catch (error) {
      this.toast("Schedule not saved", this.messageFrom(error), "error");
      this.loading = false;
    }
  }
  async toggle(event) {
    const id = event.currentTarget.dataset.id;
    const row = this.schedules.find((item) => item.id === id);
    this.loading = true;
    try {
      await setScheduleState({
        sessionToken: this.sessionToken,
        scheduleId: id,
        requestedState: row.status === "Paused" ? "Ready" : "Paused"
      });
      await this.load();
    } catch (error) {
      this.toast(
        "Schedule state not changed",
        this.messageFrom(error),
        "error"
      );
      this.loading = false;
    }
  }
  async remove(event) {
    const id = event.currentTarget.dataset.id;
    const confirmed = await LightningConfirm.open({
      label: "Delete Schedule",
      message:
        "Delete this logical schedule? Existing work and run history will be preserved.",
      variant: "headerless"
    });
    if (!confirmed) return;
    this.loading = true;
    try {
      await deleteSchedule({ sessionToken: this.sessionToken, scheduleId: id });
      this.toast(
        "Schedule deleted",
        "The schedule was removed from heartbeat dispatch.",
        "success"
      );
      await this.load();
    } catch (error) {
      this.toast("Schedule not deleted", this.messageFrom(error), "error");
      this.loading = false;
    }
  }
  async select(event) {
    this.selectedScheduleId = event.currentTarget.dataset.id;
    this.recentRuns = await getRecentRuns({
      sessionToken: this.sessionToken,
      scheduleId: this.selectedScheduleId
    });
  }
  toast(title, message, variant) {
    this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
  }
  messageFrom(error) {
    return (
      error?.body?.message || error?.message || "The scheduler request failed."
    );
  }
}