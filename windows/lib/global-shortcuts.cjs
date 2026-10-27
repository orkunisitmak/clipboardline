'use strict';
const ACTIONS=['toggle','search','library','copyLatest','uploadLatest','screenshot'];

// Only registrations owned by this instance are released. A recording lease
// suspends OS interception itself, so an existing combination reaches its field.
class GlobalShortcuts{
 constructor(registry,handlers,{failed=()=>{}}={}){this.registry=registry;this.handlers=handlers;this.failed=failed;this.registered=new Map();this.active=new Set();this.epochs=new Map();this.leases=new Set();this.disposed=false;}
 get suspended(){return this.leases.size>0;}
 register(action,key){
  const epoch=Symbol(action);const success=this.registry.register(key,()=>{
   if(this.disposed||this.suspended||this.registered.get(action)!==key||!this.active.has(action)||this.epochs.get(action)!==epoch)return;
   try{Promise.resolve(this.handlers[action]?.()).catch(this.failed);}catch(error){this.failed(error);}
  });if(success)this.epochs.set(action,epoch);return success;
 }
 suspend(){
  if(this.disposed)throw new Error('Shortcut registrations are closed.');
  const token=Symbol('recorder');this.leases.add(token);
  const resume=()=>{
   if(!this.leases.delete(token)||this.suspended||this.disposed)return;
   for(const[action,key]of this.registered){if(this.active.has(action))continue;let success=false;try{success=this.register(action,key);}catch{}
    if(success)this.active.add(action);else{this.registered.delete(action);this.failed(new Error('A shortcut could not be restored after recording. Choose another combination in Settings.'));}}
  };
  try{if(this.leases.size===1)for(const[action,key]of this.registered){if(this.active.has(action)){this.registry.unregister(key);this.active.delete(action);this.epochs.delete(action);}}}
  catch(error){resume();throw error;}
  return resume;
 }
 update(shortcuts){
  const rejected=[];
  for(const action of ACTIONS){
   const next=shortcuts[action]||'',previous=this.registered.get(action)||'';
   if(next===previous)continue;
   if(this.suspended||this.disposed){rejected.push({action,shortcut:next,previous});continue;}
   if(!next){if(previous&&this.active.has(action))this.registry.unregister(previous);this.active.delete(action);this.epochs.delete(action);this.registered.delete(action);continue;}
   let success=false;try{success=this.register(action,next);}catch{}
   if(success){if(previous&&this.active.has(action))this.registry.unregister(previous);this.registered.set(action,next);this.active.add(action);}
   else rejected.push({action,shortcut:next,previous});
  }
  return rejected;
 }
 dispose(){this.disposed=true;this.leases.clear();for(const[action,key]of this.registered){if(this.active.has(action)){try{this.registry.unregister(key);}catch{}}}this.active.clear();this.epochs.clear();this.registered.clear();}
}
module.exports={GlobalShortcuts,ACTIONS};
