'use strict';
// Focus capture through the already running native monitor. Starting a new
// PowerShell for every shelf opening cost ~750 ms (process start and C#
// compilation) before the shelves could appear. The monitor has the same
// compiled helper loaded, so each capture is one line on its stdin. Query IDs
// bind replies to callers. Only native focus identity crosses this pipe,
// never names, values or clipboard content.
class FocusQueries{
 constructor(send,{timeout=4000}={}){this.send=send;this.timeout=timeout;this.next=0;this.pending=new Map();this.closed=false;this.ready=false;}
 // Requests are accepted only after the monitor reports its helper is ready;
 // until then the caller uses its one-shot fallback instead of queueing work
 // behind PowerShell start-up.
 available(){return this.ready&&!this.closed;}
 capture(){
  if(!this.available())return Promise.reject(new Error('Focus monitor is unavailable.'));
  const id=++this.next;
  return new Promise((resolve,reject)=>{
   const timer=setTimeout(()=>{this.pending.delete(id);reject(new Error('Focus monitor query timed out.'));},this.timeout);
   this.pending.set(id,{resolve,reject,timer});
   try{this.send('focus-capture:'+id+'\n');}catch(error){clearTimeout(timer);this.pending.delete(id);reject(error);}
  });
 }
 receive(value){
  if(!Number.isSafeInteger(value?.focusQuery)||typeof value.ok!=='boolean')return false;
  const pending=this.pending.get(value.focusQuery);if(!pending)return false;
  this.pending.delete(value.focusQuery);clearTimeout(pending.timer);
  if(!value.ok)pending.reject(new Error(typeof value.error==='string'&&value.error?value.error.slice(0,300):'Windows focus operation failed.'));
  else pending.resolve({focus:value.focus&&typeof value.focus==='object'&&!Array.isArray(value.focus)?value.focus:null,captureTrace:value.captureTrace??null});
  return true;
 }
 close(){this.closed=true;this.ready=false;for(const value of this.pending.values()){clearTimeout(value.timer);value.reject(new Error('Focus monitor stopped.'));}this.pending.clear();}
}
module.exports={FocusQueries};
