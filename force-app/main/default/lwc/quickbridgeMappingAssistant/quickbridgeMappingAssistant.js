import { LightningElement, api } from 'lwc';

export default class QuickbridgeMappingAssistant extends LightningElement {
  @api workspace;
  suggestions = [];
  analyzed = false;

  get operations(){ return this.workspace?.operations || []; }
  get totalMappings(){ return this.operations.reduce((total,item)=>total+(item.mappings||[]).length,0); }
  get requiredMappings(){ return this.operations.reduce((total,item)=>total+(item.mappings||[]).filter((row)=>row.required).length,0); }
  get missingRequired(){ return this.operations.flatMap((item)=>(item.mappings||[]).filter((row)=>row.required&&!row.externalPath).map((row)=>`${item.label}: ${row.salesforceField}`)); }
  get missingCount(){ return this.missingRequired.length; }
  get healthScore(){ if(!this.totalMappings)return 0; return Math.max(0,Math.round(((this.totalMappings-this.missingCount)/this.totalMappings)*100)); }
  get healthLabel(){ return this.healthScore>=90?'Healthy':this.healthScore>=70?'Needs review':'Action required'; }
  get hasSuggestions(){ return this.suggestions.length>0; }
  get hasMissing(){ return this.missingRequired.length>0; }
  get fixPrompt(){ return `Review ${this.workspace?.connectorLabel || 'connector'} mappings. Resolve ${this.missingCount} required gaps and validate provider paths before activation.`; }

  analyze(){
    const suggestions=[];
    this.operations.forEach((operation)=>{
      const mapped=new Set((operation.mappings||[]).map((row)=>String(row.salesforceField).toLowerCase()));
      (operation.salesforceFields||[]).forEach((field)=>{
        const external=(operation.externalFields||[]).find((candidate)=>this.normalize(candidate.value)===this.normalize(field.value));
        if(!mapped.has(String(field.value).toLowerCase())&&external)suggestions.push({key:`${operation.workspaceKey}:${field.value}`,workspaceKey:operation.workspaceKey,salesforceField:field.value,externalPath:external.value,confidence:'High',selected:true});
      });
    });
    this.suggestions=suggestions;this.analyzed=true;
  }
  toggle(event){const key=event.currentTarget.dataset.key;this.suggestions=this.suggestions.map((item)=>(item.key===key?{...item,selected:event.target.checked}:item));}
  applySelected(){this.dispatchEvent(new CustomEvent('applysuggestions',{detail:this.suggestions.filter((item)=>item.selected)}));}
  applyHigh(){this.dispatchEvent(new CustomEvent('applysuggestions',{detail:this.suggestions.filter((item)=>item.confidence==='High')}));}
  normalize(value){return String(value||'').toLowerCase().replace(/[^a-z0-9]/g,'');}
}