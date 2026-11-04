'use strict';
const path=require('node:path');
const fs=require('node:fs');
const {Worker}=require('node:worker_threads');
const {ids}=require('./model.cjs');
const MODEL_CONFIG=require('../search-model-config.json');
function workerFile(){const file=path.join(__dirname,'image-search-worker.cjs'),unpacked=file.replace(/app[.]asar([\\/])/,'app.asar.unpacked$1');return unpacked!==file&&fs.existsSync(unpacked)?unpacked:file;}

// The canonical Library never stores model vectors. The worker owns the private
// derived index and all model inference; the main process only supplies bounded
// decoded pixels and rechecks each current record before accepting a result.
class ImageSearch{
 constructor({modelDirectory,cacheDirectory,items,readImage,changed=()=>{},workerFactory=options=>new Worker(workerFile(),options),runtimeDirectory=null,ortModule=null,idleTimeoutMs=15000}){
  this.items=items;this.readImage=readImage;this.changed=changed;this.sequence=0;this.requests=new Map();this.queue=[];this.known=new Set();this.failed=new Set();this.active=null;this.closed=false;this.state={available:false,indexing:false,pending:0,revision:0};
  this.workerFactory=workerFactory;this.workerOptions={modelDirectory,cacheDirectory,runtimeDirectory,ortModule,modelConfig:MODEL_CONFIG};this.idleTimeoutMs=idleTimeoutMs;this.idleTimer=null;this.heavyWorkDone=false;this.verified=false;this.prunedKeys=null;
  this.spawnWorker(true);
 }
 spawnWorker(initial=false){
  if(this.worker)return this.ready;
  const workerData=this.verified?{...this.workerOptions,verified:true}:this.workerOptions;
  const worker=this.workerFactory({workerData});this.worker=worker;this.heavyWorkDone=false;
  this.ready=new Promise(resolve=>{this.resolveReady=resolve;});
  worker.on('message',message=>{if(this.worker===worker)this.receive(message,initial);});
  worker.on('error',()=>{if(this.worker===worker)this.failure();});
  worker.on('exit',()=>{if(this.worker===worker&&!this.closed)this.failure();});
  worker.unref?.();
  return this.ready;
 }
 clearIdleTimer(){if(this.idleTimer){clearTimeout(this.idleTimer);this.idleTimer=null;}}
 scheduleIdleHibernate(){
  this.clearIdleTimer();
  if(this.closed||this.broken||!this.worker||!this.heavyWorkDone||this.draining||this.active||this.queue.length||this.requests.size||!(this.idleTimeoutMs>0))return;
  this.idleTimer=setTimeout(()=>this.hibernate(),this.idleTimeoutMs);this.idleTimer.unref?.();
 }
 hibernate(){
  this.clearIdleTimer();
  if(this.closed||this.broken||!this.worker||!this.heavyWorkDone||this.draining||this.active||this.queue.length||this.requests.size)return;
  const worker=this.worker;this.worker=null;this.heavyWorkDone=false;void worker.terminate();
 }
 receive(message,initial=false){
  if(!message||typeof message!=='object')return;
  if(message.event==='failed'){this.failure();return;}
  if(message.event==='ready'){
   const wasAvailable=this.state.available;this.state.available=message.available===true;
   if(this.state.available)this.verified=true;
   if(!this.state.available){this.queue=[];this.active=null;this.updateStatus();this.state.error='Offline image search is unavailable. Reinstall the official application to restore its bundled models.';}
   this.resolveReady(this.state.available);
   if(initial||wasAvailable!==this.state.available||!this.state.available)this.changed({...this.state});
   return;
  }
  const pending=this.requests.get(message.id);if(!pending)return;this.requests.delete(message.id);clearTimeout(pending.timer);
  if(message.error)pending.reject(new Error(String(message.error).slice(0,300)));else pending.resolve(message.result);
  this.scheduleIdleHibernate();
 }
 failure(){this.clearIdleTimer();if(this.closed||this.broken)return;this.broken=true;this.state.available=false;this.state.indexing=false;this.state.pending=0;this.queue=[];this.active=null;this.state.error='Offline image search stopped. Reopen ClipBoardLine to try again.';this.resolveReady(false);for(const pending of this.requests.values()){clearTimeout(pending.timer);pending.reject(new Error(this.state.error));}this.requests.clear();this.changed({...this.state});const worker=this.worker;this.worker=null;void worker?.terminate();}
 async request(action,payload,transfer=[]){
  if(this.closed||this.broken||!this.state.available&&this.state.error)throw new Error('Offline image search is unavailable.');
  this.clearIdleTimer();
  if(!this.worker){const ready=await this.spawnWorker(false);if(!ready||this.closed||this.broken||!this.state.available)throw new Error('Offline image search is unavailable.');}
  else if(!this.state.available){const ready=await this.ready;if(!ready||this.closed||this.broken||!this.state.available)throw new Error('Offline image search is unavailable.');}
  if(action==='index'||action==='search')this.heavyWorkDone=true;
  const worker=this.worker,id=++this.sequence;
  return new Promise((resolve,reject)=>{const timer=setTimeout(()=>{this.requests.delete(id);reject(new Error('Offline image search timed out.'));this.failure();void worker?.terminate();},120000);timer.unref?.();this.requests.set(id,{resolve,reject,timer});try{worker.postMessage({id,action,payload},transfer);}catch(error){this.requests.delete(id);clearTimeout(timer);reject(error);}});
 }
 key(value){const key=value?.kind==='image'&&!value.trashedAt?(value.renderedFile||value.imageFile):null;return typeof key==='string'&&/^[a-f0-9]{64}\.png$/.test(key)?key.slice(0,64):null;}
 current(id,key){return this.items().some(value=>value.id===id&&this.key(value)===key);}
 refresh(){
  if(this.closed||!this.state.available&&this.state.error)return;const values=this.items().filter(value=>this.key(value)),live=new Set(values.map(value=>this.key(value)));
  this.queue=this.queue.filter(job=>live.has(job.key));for(const key of this.known)if(!live.has(key))this.known.delete(key);for(const key of this.failed)if(!live.has(key))this.failed.delete(key);
  const queued=new Set(this.queue.map(job=>job.key));if(this.active)queued.add(this.active.key);
  for(const value of values){const key=this.key(value);if(!this.known.has(key)&&!this.failed.has(key)&&!queued.has(key)){this.queue.push({id:value.id,key});queued.add(key);}}
  this.updateStatus();void this.drain();
  const needsPrune=!this.prunedKeys||[...this.prunedKeys].some(key=>!live.has(key))||!!this.worker;
  if(needsPrune)void this.ready.then(available=>{if(available&&!this.closed){this.prunedKeys=new Set(live);return this.request('prune',{keys:[...live]}).catch(()=>{});}});
 }
 updateStatus(){const pending=this.queue.length+(this.active?1:0);if(pending!==this.state.pending||!!pending!==this.state.indexing){this.state.pending=pending;this.state.indexing=!!pending;this.changed({...this.state});}}
 async drain(){
  if(this.draining||this.closed)return;this.draining=true;this.clearIdleTimer();
  try{
   if(!await this.ready)return;
   while(this.queue.length&&!this.closed&&this.state.available){
    const job=this.queue.shift();this.active=job;this.updateStatus();
    try{
     if(!this.current(job.id,job.key))continue;
     // Cached vectors can be reused without decoding the image a second time.
     let indexed=await this.request('has',{key:job.key});
     if(!indexed){if(!this.current(job.id,job.key))continue;const image=await this.readImage(job.id);if(!image||!this.current(job.id,job.key))continue;const bitmap=new Uint8Array(image.bitmap);indexed=await this.request('index',{key:job.key,width:image.width,height:image.height,bitmap},[bitmap.buffer]);}
     if(indexed&&!this.current(job.id,job.key)){const keys=[...new Set(this.items().map(value=>this.key(value)).filter(Boolean))];this.prunedKeys=new Set(keys);await this.request('prune',{keys});}
     if(indexed&&this.current(job.id,job.key)){this.known.add(job.key);if(this.prunedKeys)this.prunedKeys.add(job.key);this.state.revision++;delete this.state.error;this.changed({...this.state});}
    }catch{if(this.current(job.id,job.key))this.failed.add(job.key);}
    finally{
     this.active=null;
     // If the record owning this shared fingerprint vanished mid-job, keep
     // indexing the same image through a surviving record rather than stalling.
     if(!this.closed&&this.state.available&&!this.current(job.id,job.key)&&!this.known.has(job.key)&&!this.failed.has(job.key)&&!this.queue.some(value=>value.key===job.key)){
      const replacement=this.items().find(value=>this.key(value)===job.key);
      if(replacement)this.queue.push({id:replacement.id,key:job.key});
     }
     this.updateStatus();
    }
   }
  }finally{this.draining=false;this.active=null;this.updateStatus();this.scheduleIdleHibernate();}
 }
 async search(query,eligibleIds){
  if(typeof query!=='string'||query.length>2048||query.includes('\0'))throw new Error('Search images with up to 2,048 characters.');
  if(!Array.isArray(eligibleIds)||eligibleIds.length>20000)throw new Error('Invalid image search scope.');const eligible=new Set([...ids(eligibleIds.slice(0,10000)),...ids(eligibleIds.slice(10000))]),phrase=query.trim();if(!phrase)return{ids:[],scores:[],available:this.state.available,indexing:this.state.indexing};
  this.refresh();if(!await this.ready||!this.state.available)return{ids:[],scores:[],available:false,indexing:false};
  const entries=this.items().filter(value=>eligible.has(value.id)&&this.key(value)).map(value=>({id:value.id,key:this.key(value)}));
  const result=await this.request('search',{query:phrase,entries});
  // Deletion, crop, annotation or an updated rendered PNG can invalidate an
  // embedding while inference runs. Never return a stale identity to the view.
  const fingerprints=new Map(entries.map(value=>[value.id,value.key])),scores=(result?.scores||[]).filter(value=>eligible.has(value.id)&&this.current(value.id,fingerprints.get(value.id))&&Number.isFinite(value.score));
  const allowed=new Set(scores.map(value=>value.id));return{ids:(result?.ids||[]).filter(id=>allowed.has(id)),scores,available:true,indexing:this.state.indexing};
 }
 async stop(){this.clearIdleTimer();if(this.closed)return;this.closed=true;this.resolveReady(false);for(const pending of this.requests.values()){clearTimeout(pending.timer);pending.reject(new Error('Image search closed.'));}this.requests.clear();this.queue=[];const worker=this.worker;this.worker=null;if(worker)await worker.terminate();}
}
function modelPaths({packaged,resourcesPath,sourceDirectory}){const modelDirectory=packaged?path.join(resourcesPath,'CLIP'):path.join(sourceDirectory,'assets','CLIP');return{modelDirectory,cacheAvailable:fs.existsSync(path.join(modelDirectory,'model-source.json'))};}
module.exports={ImageSearch,modelPaths};
