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
 constructor({modelDirectory,cacheDirectory,items,readImage,changed=()=>{},workerFactory=options=>new Worker(workerFile(),options),runtimeDirectory=null,ortModule=null}){
  this.items=items;this.readImage=readImage;this.changed=changed;this.sequence=0;this.requests=new Map();this.queue=[];this.known=new Set();this.failed=new Set();this.active=null;this.closed=false;this.state={available:false,indexing:false,pending:0,revision:0};
  this.worker=workerFactory({workerData:{modelDirectory,cacheDirectory,runtimeDirectory,ortModule,modelConfig:MODEL_CONFIG}});
  this.ready=new Promise(resolve=>{this.resolveReady=resolve;});
  this.worker.on('message',message=>this.receive(message));this.worker.on('error',()=>this.failure());this.worker.on('exit',code=>{if(!this.closed)this.failure();});
 }
 receive(message){
  if(!message||typeof message!=='object')return;
  if(message.event==='failed'){this.failure();return;}
  if(message.event==='ready'){this.worker.unref?.();this.state.available=message.available===true;if(!this.state.available){this.queue=[];this.active=null;this.updateStatus();}if(!this.state.available)this.state.error='Offline image search is unavailable. Reinstall the official application to restore its bundled models.';this.resolveReady(this.state.available);this.changed({...this.state});return;}
  const pending=this.requests.get(message.id);if(!pending)return;this.requests.delete(message.id);clearTimeout(pending.timer);if(message.error)pending.reject(new Error(String(message.error).slice(0,300)));else pending.resolve(message.result);
 }
 failure(){if(this.closed||this.broken)return;this.broken=true;this.worker.unref?.();this.state.available=false;this.state.indexing=false;this.state.pending=0;this.queue=[];this.active=null;this.state.error='Offline image search stopped. Reopen ClipBoardLine to try again.';this.resolveReady(false);for(const pending of this.requests.values()){clearTimeout(pending.timer);pending.reject(new Error(this.state.error));}this.requests.clear();this.changed({...this.state});void this.worker.terminate();}
 request(action,payload,transfer=[]){if(this.closed||!this.state.available)return Promise.reject(new Error('Offline image search is unavailable.'));const id=++this.sequence;return new Promise((resolve,reject)=>{const timer=setTimeout(()=>{this.requests.delete(id);reject(new Error('Offline image search timed out.'));this.failure();void this.worker.terminate();},120000);timer.unref?.();this.requests.set(id,{resolve,reject,timer});try{this.worker.postMessage({id,action,payload},transfer);}catch(error){this.requests.delete(id);clearTimeout(timer);reject(error);}});}
 key(value){const key=value?.kind==='image'&&!value.trashedAt?(value.renderedFile||value.imageFile):null;return typeof key==='string'&&/^[a-f0-9]{64}\.png$/.test(key)?key.slice(0,64):null;}
 current(id,key){return this.items().some(value=>value.id===id&&this.key(value)===key);}
 refresh(){
  if(this.closed||!this.state.available&&this.state.error)return;const values=this.items().filter(value=>this.key(value)),live=new Set(values.map(value=>this.key(value)));
  this.queue=this.queue.filter(job=>live.has(job.key));for(const key of this.known)if(!live.has(key))this.known.delete(key);for(const key of this.failed)if(!live.has(key))this.failed.delete(key);
  const queued=new Set(this.queue.map(job=>job.key));if(this.active)queued.add(this.active.key);
  for(const value of values){const key=this.key(value);if(!this.known.has(key)&&!this.failed.has(key)&&!queued.has(key)){this.queue.push({id:value.id,key});queued.add(key);}}
  this.updateStatus();void this.drain();
  void this.ready.then(available=>{if(available&&!this.closed)return this.request('prune',{keys:[...live]}).catch(()=>{});});
 }
 updateStatus(){const pending=this.queue.length+(this.active?1:0);if(pending!==this.state.pending||!!pending!==this.state.indexing){this.state.pending=pending;this.state.indexing=!!pending;this.changed({...this.state});}}
 async drain(){
  if(this.draining||this.closed)return;this.draining=true;
  try{
   if(!await this.ready)return;
   while(this.queue.length&&!this.closed&&this.state.available){
    const job=this.queue.shift();this.active=job;this.updateStatus();
    try{
     if(!this.current(job.id,job.key))continue;
     // Cached vectors can be reused without decoding the image a second time.
     let indexed=await this.request('has',{key:job.key});
     if(!indexed){const image=await this.readImage(job.id);if(!image||!this.current(job.id,job.key))continue;const bitmap=Uint8Array.from(image.bitmap);indexed=await this.request('index',{key:job.key,width:image.width,height:image.height,bitmap},[bitmap.buffer]);}
     if(indexed&&!this.current(job.id,job.key))await this.request('prune',{keys:[...new Set(this.items().map(value=>this.key(value)).filter(Boolean))]});
     if(indexed&&this.current(job.id,job.key)){this.known.add(job.key);this.state.revision++;delete this.state.error;this.changed({...this.state});}
    }catch{if(this.current(job.id,job.key))this.failed.add(job.key);}
    finally{this.active=null;this.updateStatus();}
   }
  }finally{this.draining=false;this.active=null;this.updateStatus();}
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
 async stop(){if(this.closed)return;this.closed=true;this.resolveReady(false);for(const pending of this.requests.values()){clearTimeout(pending.timer);pending.reject(new Error('Image search closed.'));}this.requests.clear();this.queue=[];await this.worker.terminate();}
}
function modelPaths({packaged,resourcesPath,sourceDirectory}){const modelDirectory=packaged?path.join(resourcesPath,'CLIP'):path.join(sourceDirectory,'assets','CLIP');return{modelDirectory,cacheAvailable:fs.existsSync(path.join(modelDirectory,'model-source.json'))};}
module.exports={ImageSearch,modelPaths};
