'use strict';
const fs=require('node:fs');
const path=require('node:path');
const crypto=require('node:crypto');
const {parentPort,workerData}=require('node:worker_threads');
const {pathToFileURL}=require('node:url');
const {ClipTokenizer}=require('./clip-tokenizer.cjs');
const {DIMENSIONS,normalized,score,rankedMatches,imageTensors}=require('./image-search-core.cjs');

const keyPattern=/^[a-f0-9]{64}$/,MAX_CACHE_BYTES=256*1024*1024,MAX_CACHE_RECORDS=20000;
let modelID,tokenizer,ort,imageSession,textSession,available=false,serial=Promise.resolve();
const queryCache=new Map(),vectors=new Map();
const localFetch=globalThis.fetch;
if(localFetch)globalThis.fetch=(input,...options)=>{const url=typeof input==='string'?input:input?.url||input?.href||'';if(!String(url).startsWith('file:'))return Promise.reject(new Error('Offline image search does not allow network requests.'));return localFetch(input,...options);};
function safeFile(directory,name,maximum){const destination=path.join(directory,name),stat=fs.lstatSync(destination);if(!stat.isFile()||stat.isSymbolicLink()||stat.size>maximum||stat.size===0)throw new Error('Offline image search assets are invalid.');return destination;}
function verifyModels(){const config=workerData.modelConfig;if(config?.schemaVersion!==1||!config.files||typeof config.version!=='string')throw new Error('Offline image model configuration is invalid.');
 for(const [name,expected]of Object.entries(config.files)){if(!/^[a-zA-Z0-9_.-]+$/.test(name)||!Number.isSafeInteger(expected.bytes)||expected.bytes<=0||expected.bytes>600*1024*1024||!/^[a-f0-9]{64}$/.test(expected.sha256))throw new Error('Invalid pinned model asset.');const file=safeFile(workerData.modelDirectory,name,expected.bytes),stat=fs.statSync(file);if(stat.size!==expected.bytes)throw new Error('Offline image model size differs.');const hash=crypto.createHash('sha256'),block=Buffer.allocUnsafe(1024*1024);let descriptor;try{descriptor=fs.openSync(file,'r');for(let read;(read=fs.readSync(descriptor,block,0,block.length,null))>0;)hash.update(block.subarray(0,read));}finally{if(descriptor!==undefined)fs.closeSync(descriptor);}if(hash.digest('hex')!==expected.sha256)throw new Error('Offline image model integrity differs.');}
}
function validVectors(value){return Array.isArray(value)&&value.length<=4&&value.every(vector=>Array.isArray(vector)&&vector.length===DIMENSIONS&&vector.every(Number.isFinite)&&Math.abs(vector.reduce((sum,value)=>sum+value*value,0)-1)<.02);}
function load(key){
 if(!keyPattern.test(key))throw new Error('Invalid image search identity.');if(vectors.has(key))return vectors.get(key);
 try{
  const file=safeFile(workerData.cacheDirectory,key+'.bin',76+4*DIMENSIONS*4),record=fs.readFileSync(file);
  if(record.length<76||record.subarray(0,8).toString()!=='CLIPIDX1'||record.subarray(8,40).toString('hex')!==modelID||record.subarray(40,72).toString('hex')!==key)return null;
  const count=record.readUInt32LE(72);if(count>4||record.length!==76+count*DIMENSIONS*4)return null;
  const raw=Array.from({length:count},(_,view)=>Array.from({length:DIMENSIONS},(_,index)=>record.readFloatLE(76+(view*DIMENSIONS+index)*4)));
  if(!validVectors(raw))return null;const value=raw.map(vector=>Float32Array.from(vector));vectors.set(key,value);if(vectors.size>256)vectors.delete(vectors.keys().next().value);return value;
 }catch{return null;}
}
function save(key,value){
 const file=path.join(workerData.cacheDirectory,key+'.bin'),temporary=file+'.tmp-'+crypto.randomUUID();if(fs.existsSync(file)&&fs.lstatSync(file).isSymbolicLink())throw new Error('Unsafe image search cache.');
 const record=Buffer.alloc(76+value.length*DIMENSIONS*4);record.write('CLIPIDX1',0);Buffer.from(modelID,'hex').copy(record,8);Buffer.from(key,'hex').copy(record,40);record.writeUInt32LE(value.length,72);value.forEach((vector,view)=>vector.forEach((entry,index)=>record.writeFloatLE(entry,76+(view*DIMENSIONS+index)*4)));
 try{fs.writeFileSync(temporary,record,{flag:'wx',mode:0o600});fs.renameSync(temporary,file);}finally{if(fs.existsSync(temporary))fs.unlinkSync(temporary);}
 vectors.set(key,value);if(vectors.size>256)vectors.delete(vectors.keys().next().value);
}
function prune(keys){
 if(!Array.isArray(keys)||keys.length>100000||keys.some(key=>!keyPattern.test(key)))throw new Error('Invalid image index cleanup.');const live=new Set(keys),records=[];
 for(const name of fs.readdirSync(workerData.cacheDirectory)){if(!/^[a-f0-9]{64}\.bin$/.test(name))continue;const file=path.join(workerData.cacheDirectory,name),stat=fs.lstatSync(file);if(stat.isSymbolicLink()||!stat.isFile())continue;const key=name.slice(0,64);if(!live.has(key)){fs.unlinkSync(file);vectors.delete(key);}else records.push({file,key,size:stat.size,time:stat.mtimeMs});}
 records.sort((a,b)=>b.time-a.time);let bytes=0;for(let index=0;index<records.length;index++){const record=records[index];bytes+=record.size;if(index>=MAX_CACHE_RECORDS||bytes>MAX_CACHE_BYTES){fs.unlinkSync(record.file);vectors.delete(record.key);}}
 return true;
}
async function sessions(){
 if(imageSession&&textSession)return;
 ort=require(workerData.ortModule||'onnxruntime-web/wasm');ort.env.logLevel='error';ort.env.wasm.numThreads=1;ort.env.wasm.proxy=false;
 // Every WASM/JS asset is packaged locally. ORT receives no network model URL.
 if(workerData.runtimeDirectory)ort.env.wasm.wasmPaths=pathToFileURL(workerData.runtimeDirectory+path.sep).href;
 const options={executionProviders:['wasm'],graphOptimizationLevel:'all',enableCpuMemArena:true};
 try{
  imageSession=await ort.InferenceSession.create(fs.readFileSync(safeFile(workerData.modelDirectory,'mobileclip-s2-image.onnx',400*1024*1024)),options);
  textSession=await ort.InferenceSession.create(fs.readFileSync(safeFile(workerData.modelDirectory,'mobileclip-s2-text.onnx',600*1024*1024)),options);
 }catch(error){available=false;parentPort.postMessage({event:'failed'});throw error;}
}
async function infer(session,name,tensor){const output=await session.run({[name]:tensor}),first=output.embedding||output.final_emb_1||output[session.outputNames[0]],vector=normalized(first?.data);if(!vector)throw new Error('The offline model returned an invalid embedding.');return vector;}
async function handle(action,payload){
 if(action==='has')return load(payload.key)!==null;
 if(action==='prune')return prune(payload.keys);
 if(action==='index'){
  const {key,bitmap,width,height}=payload;if(!keyPattern.test(key))throw new Error('Invalid image search identity.');
  const views=imageTensors(bitmap,width,height),embeddings=[];if(views.length){await sessions();for(const pixels of views)embeddings.push(await infer(imageSession,'image',new ort.Tensor('float32',pixels,[1,3,256,256])));}
  save(key,embeddings);return true;
 }
 if(action==='search'){
  if(typeof payload.query!=='string'||payload.query.length>2048||!Array.isArray(payload.entries)||payload.entries.length>20000||payload.entries.some(value=>!value||typeof value.id!=='string'||!keyPattern.test(value.key)))throw new Error('Invalid image search query.');
  await sessions();let query=queryCache.get(payload.query);if(!query){query=await infer(textSession,'text',new ort.Tensor('int64',tokenizer.tensor(payload.query),[1,77]));queryCache.set(payload.query,query);if(queryCache.size>16)queryCache.delete(queryCache.keys().next().value);}
  const scores=payload.entries.flatMap(value=>{const vector=load(value.key);if(!vector?.length)return[];const result=score(query,vector);return result===null?[]:[{id:value.id,score:result}];});return{ids:rankedMatches(scores).map(value=>value.id),scores};
 }
 throw new Error('Unknown image search operation.');
}
try{
 if(fs.lstatSync(workerData.modelDirectory).isSymbolicLink())throw new Error('Unsafe image search models.');
 fs.mkdirSync(workerData.cacheDirectory,{recursive:true,mode:0o700});if(fs.lstatSync(workerData.cacheDirectory).isSymbolicLink())throw new Error('Unsafe image search cache.');
 verifyModels();
 const metadata=fs.readFileSync(safeFile(workerData.modelDirectory,'model-source.json',1024*1024));modelID=crypto.createHash('sha256').update(metadata).digest('hex');
 for(const file of ['mobileclip-s2-image.onnx','mobileclip-s2-text.onnx','clip-vocab.json','clip-merges.txt'])safeFile(workerData.modelDirectory,file,600*1024*1024);
 tokenizer=ClipTokenizer.fromFiles(path.join(workerData.modelDirectory,'clip-vocab.json'),path.join(workerData.modelDirectory,'clip-merges.txt'));available=true;
}catch{}
parentPort.postMessage({event:'ready',available});
parentPort.on('message',message=>{serial=serial.then(async()=>{if(!available)return parentPort.postMessage({id:message.id,error:'Offline image search assets are unavailable.'});try{const result=await handle(message.action,message.payload||{});parentPort.postMessage({id:message.id,result});}catch(error){parentPort.postMessage({id:message.id,error:String(error.message||error).slice(0,300)});}});});
