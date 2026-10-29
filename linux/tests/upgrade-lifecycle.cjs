'use strict';
// Test-only shutdown proof. A renderer/inspector disconnect alone does not
// establish that the owned application process exited naturally.
function quitPhaseMatches(phase,{pid,executable}){
 if(!phase||phase.pid!==pid||phase.executable!==executable||!Array.isArray(phase.events))return false;
 const expected=['before-quit','window-close','will-quit'];let previous=-1;
 for(const event of expected){const index=phase.events.findIndex(value=>value.event===event);if(index<=previous||phase.events[index]?.updateStatus!=='installing')return false;previous=index;}
 const started=phase.events.findIndex(value=>value.event==='debugger-detach-started'),detached=phase.events.findIndex(value=>value.event==='debugger-detached'),absent=phase.events.findIndex(value=>value.event==='debugger-not-attached');
 return started>previous&&detached>started||absent>previous;
}
function nativeQuitEvidence(phase,expected,processes){
 if(!quitPhaseMatches(phase,expected)||!Array.isArray(processes)||processes.some(value=>value.pid===expected.pid))return null;
 return{pid:expected.pid,executable:expected.executable,naturalWillQuitObserved:true,inspectorReleasedAfterWillQuit:true,ownedProcessGone:true,observedAt:new Date().toISOString(),events:phase.events};
}
module.exports={quitPhaseMatches,nativeQuitEvidence};
