'use strict';
// Capability-only request/response channel to the existing native monitor.
// Query IDs bind responses to callers; no clipboard content crosses this pipe.
class ClipboardSequenceQueries{
 constructor(send,{timeout=2000}={}){this.send=send;this.timeout=timeout;this.next=0;this.pending=new Map();this.closed=false;}
 read(){
  if(this.closed)return Promise.reject(new Error('Clipboard sequence monitor is unavailable.'));
  const id=++this.next;
  return new Promise((resolve,reject)=>{
   const timer=setTimeout(()=>{this.pending.delete(id);reject(new Error('Clipboard sequence query timed out.'));},this.timeout);
   this.pending.set(id,{resolve,reject,timer});
   try{this.send('clipboard-sequence:'+id+'\n');}catch(error){clearTimeout(timer);this.pending.delete(id);reject(error);}
  });
 }
 receive(value){
  if(!Number.isSafeInteger(value?.clipboardQuery)||!Number.isInteger(value?.sequence)||value.sequence<=0||value.sequence>0xffffffff)return false;
  const pending=this.pending.get(value.clipboardQuery);if(!pending)return false;
  this.pending.delete(value.clipboardQuery);clearTimeout(pending.timer);pending.resolve(value.sequence);return true;
 }
 close(){this.closed=true;for(const value of this.pending.values()){clearTimeout(value.timer);value.reject(new Error('Clipboard sequence monitor stopped.'));}this.pending.clear();}
}
module.exports={ClipboardSequenceQueries};
