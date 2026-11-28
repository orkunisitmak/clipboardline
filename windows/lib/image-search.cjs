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
 /**
  * @param {object} options
  * @param {string} options.modelDirectory Folder holding the pinned ONNX models.
  * @param {string} options.cacheDirectory Private folder for derived `.bin` vectors.
  * @param {() => object[]} options.items Current Library records.
  * @param {(id: string) => Promise<{bitmap:Uint8Array,width:number,height:number}|null>} options.readImage Decodes a record's pixels.
  * @param {(state: object) => void} [options.changed] Receives public state updates.
  * @param {(options: object) => Worker} [options.workerFactory] Creates the inference worker.
  * @param {string|null} [options.runtimeDirectory] Local ONNX Runtime WASM folder.
  * @param {string|null} [options.ortModule] ONNX Runtime module path.
  * @param {object} [options.modelConfig] Pinned model sizes and SHA-256 hashes.
  * @param {number} [options.idleTimeoutMs] Idle time before the worker is terminated; 0 disables it.
  */
 constructor({modelDirectory,cacheDirectory,items,readImage,changed=()=>{},workerFactory=options=>new Worker(workerFile(),options),runtimeDirectory=null,ortModule=null,modelConfig=MODEL_CONFIG,idleTimeoutMs=15000}){
  this.items=items;this.readImage=readImage;this.changed=changed;this.sequence=0;this.requests=new Map();this.queue=[];this.known=new Set();this.failed=new Set();this.active=null;this.closed=false;this.state={available:false,indexing:false,pending:0,revision:0};
  this.workerFactory=workerFactory;this.workerOptions={modelDirectory,cacheDirectory,runtimeDirectory,ortModule,modelConfig};this.idleTimeoutMs=idleTimeoutMs;this.idleTimer=null;this.heavyWorkDone=false;this.prunedKeys=null;
  this.spawnWorker(true);
 }
 /**
  * Starts a worker unless one is running. Events from a replaced worker are ignored.
  * @param {boolean} [initial] True only for the first worker, whose ready event is always published.
  * @returns {Promise<boolean>} Resolves with model availability.
  */
 spawnWorker(initial=false){
  if(this.worker)return this.ready;
  const worker=this.workerFactory({workerData:this.workerOptions});this.worker=worker;this.heavyWorkDone=false;
  this.ready=new Promise(resolve=>{this.resolveReady=resolve;});
  worker.on('message',message=>{if(this.worker===worker)this.receive(message,initial);});
  worker.on('error',()=>{if(this.worker===worker)this.failure();});
  worker.on('exit',()=>{if(this.worker===worker&&!this.closed)this.failure();});
  worker.unref?.();
  return this.ready;
 }
 /** Cancels a pending idle hibernation, if any. */
 clearIdleTimer(){if(this.idleTimer){clearTimeout(this.idleTimer);this.idleTimer=null;}}
 /**
  * Restarts the idle timer after model work. Nothing is scheduled while work
  * is queued or pending, before any index/search ran, or when disabled.
  */
 scheduleIdleHibernate(){
  this.clearIdleTimer();
  if(this.closed||this.broken||!this.worker||!this.heavyWorkDone||this.draining||this.active||this.queue.length||this.requests.size||!(this.idleTimeoutMs>0))return;
  this.idleTimer=setTimeout(()=>this.hibernate(),this.idleTimeoutMs);this.idleTimer.unref?.();
 }
 /**
  * Terminates an idle worker so its WASM memory returns to the OS. Known
  * fingerprints and availability are kept; the next request respawns it.
  */
 hibernate(){
  this.clearIdleTimer();
  if(this.closed||this.broken||!this.worker||!this.heavyWorkDone||this.draining||this.active||this.queue.length||this.requests.size)return;
  const worker=this.worker;this.worker=null;this.heavyWorkDone=false;void worker.terminate();
 }
 /**
  * Handles a worker message: `failed` and `ready` events, or a request reply.
  * A respawned worker's ready event is only published when availability changes.
  * @param {object} message Worker message.
  * @param {boolean} [initial] Whether it came from the first worker.
  */
 receive(message,initial=false){
  if(!message||typeof message!=='object')return;
  if(message.event==='failed'){this.failure();return;}
  if(message.event==='ready'){
   const wasAvailable=this.state.available;this.state.available=message.available===true;
   if(!this.state.available){this.queue=[];this.active=null;this.updateStatus();this.state.error='Offline image search is unavailable. Reinstall the official application to restore its bundled models.';}
   this.resolveReady(this.state.available);
   if(initial||wasAvailable!==this.state.available||!this.state.available)this.changed({...this.state});
   return;
  }
  const pending=this.requests.get(message.id);if(!pending)return;this.requests.delete(message.id);clearTimeout(pending.timer);
  if(message.error)pending.reject(new Error(String(message.error).slice(0,300)));else pending.resolve(message.result);
  this.scheduleIdleHibernate();
 }
 /** Marks search permanently unavailable, rejects pending requests and terminates the worker. */
 failure(){this.clearIdleTimer();if(this.closed||this.broken)return;this.broken=true;this.state.available=false;this.state.indexing=false;this.state.pending=0;this.queue=[];this.active=null;this.state.error='Offline image search stopped. Reopen ClipBoardLine to try again.';this.resolveReady(false);for(const pending of this.requests.values()){clearTimeout(pending.timer);pending.reject(new Error(this.state.error));}this.requests.clear();this.changed({...this.state});const worker=this.worker;this.worker=null;void worker?.terminate();}
 /**
  * Sends one request to the worker, respawning a hibernated worker first.
  * Every request waits for the current worker's ready event before posting,
  * so a respawn's model verification never counts against the timeout.
  * A request that times out after 120 seconds marks search as failed.
  * @param {'has'|'prune'|'index'|'search'} action Worker operation.
  * @param {object} payload Operation input.
  * @param {Transferable[]} [transfer] Buffers moved to the worker.
  * @returns {Promise<any>} The worker result.
  * @throws When search is closed, failed or unavailable.
  */
 async request(action,payload,transfer=[]){
  if(this.closed||this.broken||!this.state.available&&this.state.error)throw new Error('Offline image search is unavailable.');
  this.clearIdleTimer();
  if(!this.worker){const ready=await this.spawnWorker(false);if(!ready||this.closed||this.broken||!this.state.available)throw new Error('Offline image search is unavailable.');}
  else{const ready=await this.ready;if(!ready||this.closed||this.broken||!this.state.available)throw new Error('Offline image search is unavailable.');}
  if(action==='index'||action==='search')this.heavyWorkDone=true;
  const worker=this.worker,id=++this.sequence;
  return new Promise((resolve,reject)=>{const timer=setTimeout(()=>{this.requests.delete(id);reject(new Error('Offline image search timed out.'));this.failure();void worker?.terminate();},120000);timer.unref?.();this.requests.set(id,{resolve,reject,timer});try{worker.postMessage({id,action,payload},transfer);}catch(error){this.requests.delete(id);clearTimeout(timer);reject(error);}});
 }
 key(value){const key=value?.kind==='image'&&!value.trashedAt?(value.renderedFile||value.imageFile):null;return typeof key==='string'&&/^[a-f0-9]{64}\.png$/.test(key)?key.slice(0,64):null;}
 current(id,key){return this.items().some(value=>value.id===id&&this.key(value)===key);}
 /**
  * Syncs the queue with current Library images and starts indexing. The cache
  * is pruned only when a previously pruned key is no longer live.
  */
 refresh(){
  if(this.closed||!this.state.available&&this.state.error)return;const values=this.items().filter(value=>this.key(value)),live=new Set(values.map(value=>this.key(value)));
  this.queue=this.queue.filter(job=>live.has(job.key));for(const key of this.known)if(!live.has(key))this.known.delete(key);for(const key of this.failed)if(!live.has(key))this.failed.delete(key);
  const queued=new Set(this.queue.map(job=>job.key));if(this.active)queued.add(this.active.key);
  for(const value of values){const key=this.key(value);if(!this.known.has(key)&&!this.failed.has(key)&&!queued.has(key)){this.queue.push({id:value.id,key});queued.add(key);}}
  this.updateStatus();void this.drain();
  const needsPrune=!this.prunedKeys||[...this.prunedKeys].some(key=>!live.has(key));
  if(needsPrune)void this.ready.then(available=>{if(available&&!this.closed)return this.request('prune',{keys:[...live]}).then(()=>{this.prunedKeys=new Set(live);},()=>{this.prunedKeys=null;});});
 }
 updateStatus(){const pending=this.queue.length+(this.active?1:0);if(pending!==this.state.pending||!!pending!==this.state.indexing){this.state.pending=pending;this.state.indexing=!!pending;this.changed({...this.state});}}
 /**
  * Indexes queued images one at a time, reusing cached vectors when present
  * and rechecking each record before accepting a result. Schedules idle
  * hibernation when the queue is empty.
  */
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
     if(!indexed){if(!this.current(job.id,job.key))continue;const image=await this.readImage(job.id);if(!image||!this.current(job.id,job.key))continue;const source=image.bitmap,bitmap=source instanceof Uint8Array&&!Buffer.isBuffer(source)&&source.buffer instanceof ArrayBuffer&&source.byteOffset===0&&source.byteLength===source.buffer.byteLength?source:new Uint8Array(source);indexed=await this.request('index',{key:job.key,width:image.width,height:image.height,bitmap},[bitmap.buffer]);}
     if(indexed&&!this.current(job.id,job.key)){const keys=[...new Set(this.items().map(value=>this.key(value)).filter(Boolean))];this.prunedKeys=null;await this.request('prune',{keys});this.prunedKeys=new Set(keys);}
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
 /** Closes search permanently, rejects pending requests and terminates any running worker. */
 async stop(){this.clearIdleTimer();if(this.closed)return;this.closed=true;this.resolveReady(false);for(const pending of this.requests.values()){clearTimeout(pending.timer);pending.reject(new Error('Image search closed.'));}this.requests.clear();this.queue=[];const worker=this.worker;this.worker=null;if(worker)await worker.terminate();}
}
function modelPaths({packaged,resourcesPath,sourceDirectory}){const modelDirectory=packaged?path.join(resourcesPath,'CLIP'):path.join(sourceDirectory,'assets','CLIP');return{modelDirectory,cacheAvailable:fs.existsSync(path.join(modelDirectory,'model-source.json'))};}
module.exports={ImageSearch,modelPaths};
