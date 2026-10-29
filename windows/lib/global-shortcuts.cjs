'use strict';
const ACTIONS=['toggle','search','library','copyLatest','screenshot'];

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
  const rejected=[],swapped=new Set();
  // A reciprocal swap only uses two shortcuts already owned by this instance.
  // Release both together, then restore both on failure instead of rejecting
  // valid bindings merely because each is still held by its old action.
  if(!this.suspended&&!this.disposed)for(const action of ACTIONS){
   if(swapped.has(action))continue;
   const previous=this.registered.get(action),next=shortcuts[action]||'';
   if(!previous||!next||next===previous||!this.active.has(action))continue;
   const other=ACTIONS.find(candidate=>candidate!==action&&this.active.has(candidate)&&this.registered.get(candidate)===next&&(shortcuts[candidate]||'')===previous);
   if(!other)continue;
   const pair=[{action,previous,next},{action:other,previous:next,next:previous}],installed=[];
   let success=true;
   try{
    for(const item of pair){this.registry.unregister(item.previous);this.active.delete(item.action);this.epochs.delete(item.action);}
    for(const item of pair){if(!this.register(item.action,item.next)){success=false;break;}this.active.add(item.action);installed.push(item);}
   }catch{success=false;}
   if(success)for(const item of pair)this.registered.set(item.action,item.next);
   else{
    for(const item of installed){try{this.registry.unregister(item.next);}catch{}this.active.delete(item.action);this.epochs.delete(item.action);}
    for(const item of pair){
     if(this.active.has(item.action))continue;
     let restored=false;try{restored=this.register(item.action,item.previous);}catch{}
     if(restored)this.active.add(item.action);
     else{this.registered.delete(item.action);this.failed(new Error('A shortcut could not be restored after a failed swap.'));}
    }
    rejected.push(...pair.map(item=>({action:item.action,shortcut:item.next,previous:item.previous})));
   }
   swapped.add(action);swapped.add(other);
  }
  for(const action of ACTIONS){
   if(swapped.has(action))continue;
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
