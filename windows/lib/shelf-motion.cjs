'use strict';
// One compositor layer moves the retained shelf tree. Native window bounds and
// row layout stay fixed for the entire transition.
(function(scope){
 const OPEN_MS=420,CLOSE_MS=220,OPEN_CURVE='cubic-bezier(0.2,1.12,0.3,1)',CLOSE_CURVE='cubic-bezier(0.4,0,1,1)';
 class MotionBridge{
  constructor(send,{schedule=setTimeout,cancel=clearTimeout}={}){this.send=send;this.schedule=schedule;this.cancelTimer=cancel;this.serial=0;this.pending=null;}
  cancel(){if(!this.pending)return;const pending=this.pending;this.pending=null;this.cancelTimer(pending.timer);pending.resolve({completed:false});}
  request(phase,details={}){
   this.cancel();const token=++this.serial;
   return new Promise(resolve=>{const pending={token,phase,resolve,timer:null};this.pending=pending;pending.timer=this.schedule(()=>{if(this.pending!==pending)return;this.pending=null;resolve({completed:true,timedOut:true});},(phase==='open'?OPEN_MS:phase==='close'?CLOSE_MS:0)+1000);this.send({token,phase,...details});});
  }
  acknowledge(value){if(!value||!this.pending||value.token!==this.pending.token||value.phase!==this.pending.phase||typeof value.completed!=='boolean')return false;const pending=this.pending;this.pending=null;this.cancelTimer(pending.timer);pending.resolve({completed:value.completed});return true;}
 }
 class ShelfMotion{
  constructor({body,computed,height,motion}){this.body=body;this.computed=computed;this.height=height;this.motion=motion;this.animation=null;this.pending=null;this.serial=0;this.phase='idle';this.motion?.addEventListener?.('change',()=>{if(this.motion.matches&&this.pending)this.finish(this.pending);});}
  offscreen(){return 'translate3d(0,'+(-Math.max(0,this.height())-12)+'px,0)';}
  freeze(){const value=this.animation?this.computed(this.body).transform:this.body.style.transform||'none';this.animation?.cancel();this.animation=null;this.body.style.transform=value;return value;}
  cancel(){this.freeze();if(this.pending){const pending=this.pending;this.pending=null;pending.resolve({completed:false});}}
  finish(pending){if(this.pending!==pending)return;this.pending=null;this.body.style.transform=pending.target;this.animation?.cancel();this.animation=null;this.body.style.willChange='';this.phase=pending.phase==='open'?'shown':'hidden';if(pending.phase==='open')delete this.body.dataset.shelfMotion;else this.body.dataset.shelfMotion='hidden';pending.resolve({completed:true});}
  run(value){
   if(!value||!['prepare','open','close','reset'].includes(value.phase))return Promise.resolve({completed:false});
   this.cancel();const serial=++this.serial,phase=value.phase;
   if(phase==='reset'){this.body.style.transform='';this.body.style.willChange='';delete this.body.dataset.shelfMotion;this.phase='idle';return Promise.resolve({completed:true});}
   if(phase==='prepare'){if(value.hidden)this.body.style.transform=this.offscreen();this.body.dataset.shelfMotion='prepared';this.body.style.willChange='transform';this.phase='prepared';return Promise.resolve({completed:true});}
   const from=this.body.style.transform||'none',target=phase==='open'?'translate3d(0,0,0)':this.offscreen();
   this.body.dataset.shelfMotion=phase==='open'?'opening':'closing';this.body.style.willChange='transform';this.phase=phase;
   return new Promise(resolve=>{
    const pending={serial,phase,target,resolve};this.pending=pending;
    if(this.motion?.matches||!this.body.animate){this.finish(pending);return;}
    this.body.style.transform=target;
    this.animation=this.body.animate([{transform:from},{transform:target}],{duration:phase==='open'?OPEN_MS:CLOSE_MS,easing:phase==='open'?OPEN_CURVE:CLOSE_CURVE,fill:'both'});
    this.animation.finished.then(()=>this.finish(pending),()=>this.finish(pending));
   });
  }
 }
 const exports={MotionBridge,ShelfMotion,OPEN_MS,CLOSE_MS,OPEN_CURVE,CLOSE_CURVE};
 if(typeof module==='object'&&module.exports)module.exports=exports;else scope.clipboardLineShelfMotion=exports;
})(typeof window==='object'?window:globalThis);
