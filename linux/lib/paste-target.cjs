'use strict';

// Only native focus metadata is retained. Never copy names, field values,
// selections or arbitrary provider properties into the application process.
function snapshot(value, ownPID) {
  if(!value||typeof value!=='object'||!Number.isInteger(value.processId)||value.processId<=0||value.processId===ownPID||
      typeof value.handle!=='string'||!/^\d{1,20}$/.test(value.handle)||value.handle==='0'||
      typeof value.runtime!=='string'||value.runtime.length>512||!/^$|^-?\d+(?:\.-?\d+)*$/.test(value.runtime)||
      typeof value.editable!=='boolean'||typeof value.secure!=='boolean')return null;
  return Object.freeze({handle:value.handle,processId:value.processId,runtime:value.runtime,
    editable:value.editable&&!value.secure&&value.runtime.length>0,secure:value.secure});
}
class PasteTargetTracker {
  constructor(ownPID){this.ownPID=ownPID;this.external=null;}
  observe(value){
    // Own-window events arrive after an external editor blurs. Preserve the
    // last external identity for a mouse return to an already visible Library.
    if(value?.processId===this.ownPID)return;
    this.external=snapshot(value,this.ownPID);
  }
  capture(value){if(value?.processId!==this.ownPID)this.external=snapshot(value,this.ownPID);return this.external;}
  reenter(){return this.external;}
  resolve(captured){
    // A visible Library can regain native foreground without another Electron
    // focus callback. At a new paste command, use the exact observed external
    // field, while preserving an explicitly missing/invalid capture as a veto.
    // The returned immutable identity stays fixed throughout native validation.
    return snapshot(captured,this.ownPID)?this.external:null;
  }
  clear(){this.external=null;}
}
module.exports={PasteTargetTracker};
