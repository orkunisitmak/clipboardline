'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),os=require('node:os');
const {MediaJobScheduler,MediaJobs}=require('../lib/media.cjs');
function deferred(){let resolve,reject;const promise=new Promise((yes,no)=>{resolve=yes;reject=no;});return{promise,resolve,reject};}
const turn=()=>new Promise(resolve=>setImmediate(resolve));

test('a folder burst runs at most two jobs and queued work starts only after a slot is released',async()=>{
 const queue=new MediaJobScheduler(),gates=Array.from({length:8},deferred),started=[];let active=0,peak=0;
 const work=gates.map((gate,index)=>queue.schedule('Inspect',async()=>{started.push(index);active++;peak=Math.max(peak,active);try{await gate.promise;return index;}finally{active--;}}));
 await turn();assert.deepEqual(started,[0,1]);assert.equal(queue.activeCount,2);assert.equal(queue.pendingCount,6);
 gates[0].resolve();await turn();assert.deepEqual(started,[0,1,2]);assert.equal(queue.activeCount,2);
 for(const gate of gates)gate.resolve();assert.deepEqual(await Promise.all(work),[0,1,2,3,4,5,6,7]);await turn();assert.equal(peak,2);assert.equal(queue.activeCount,0);assert.equal(queue.pendingCount,0);
});
test('explicit trim goes ahead of queued inspections without interrupting active codecs or reordering equal-priority work',async()=>{
 const queue=new MediaJobScheduler({concurrency:1}),gate=deferred(),started=[];
 const first=queue.schedule('Inspect',async()=>{started.push('active');await gate.promise;}),inspectA=queue.schedule('Inspect',()=>started.push('inspect A')),trimA=queue.schedule('Trim',()=>started.push('trim A')),inspectB=queue.schedule('Inspect',()=>started.push('inspect B')),trimB=queue.schedule('Trim',()=>started.push('trim B'));
 await turn();assert.deepEqual(started,['active']);gate.resolve();await Promise.all([first,inspectA,trimA,inspectB,trimB]);assert.deepEqual(started,['active','trim A','trim B','inspect A','inspect B']);
});
test('64 pending jobs are bounded, overflow is explicit, and canceling queued work frees capacity without launching it',async()=>{
 const queue=new MediaJobScheduler({concurrency:1}),gate=deferred(),first=queue.schedule('Inspect',()=>gate.promise),controllers=Array.from({length:64},()=>new AbortController());let launched=0;
 const queued=controllers.map(controller=>queue.schedule('Inspect',()=>{launched++;},{signal:controller.signal}));
 const observed=queued.map(promise=>promise.then(()=>null,error=>error));assert.equal(queue.pendingCount,64);await assert.rejects(queue.schedule('Trim',()=>{throw new Error('Overflow must not launch');}),error=>error.code==='MEDIA_QUEUE_FULL');
 controllers[5].abort();await turn();assert.equal(queue.pendingCount,63);const extra=queue.schedule('Trim',()=>{launched++;});gate.resolve();await first;await extra;const results=await Promise.all(observed);assert.equal(results[5].name,'AbortError');assert.equal(launched,64);assert.equal(results.filter(Boolean).length,1);
});
test('queued cancellation and an already-aborted signal never execute callbacks or native launch hooks',async()=>{
 const queue=new MediaJobScheduler({concurrency:1}),gate=deferred(),first=queue.schedule('Inspect',()=>gate.promise),controller=new AbortController();let launched=0;
 const canceled=queue.schedule('Trim',()=>{launched++;},{signal:controller.signal});controller.abort();await assert.rejects(canceled,error=>error.name==='AbortError');await assert.rejects(queue.schedule('Inspect',()=>{launched++;},{signal:controller.signal}),error=>error.name==='AbortError');gate.resolve();await first;await turn();assert.equal(launched,0);assert.equal(queue.pendingCount,0);
});
test('dispose rejects queued jobs, aborts active operations, and refuses future work',async()=>{
 const queue=new MediaJobScheduler({concurrency:1}),started=deferred();let activeCanceled=false,queuedLaunched=false;
 const active=queue.schedule('Inspect',signal=>new Promise((resolve,reject)=>{signal.addEventListener('abort',()=>{activeCanceled=true;reject(new Error('Native child killed'));},{once:true});started.resolve();}));
 const queued=queue.schedule('Trim',()=>{queuedLaunched=true;});await started.promise;queue.dispose();queue.dispose();
 await assert.rejects(active,error=>error.name==='AbortError');await assert.rejects(queued,error=>error.name==='AbortError');await assert.rejects(queue.schedule('Inspect',()=>{}),error=>error.name==='AbortError');await turn();assert.equal(activeCanceled,true);assert.equal(queuedLaunched,false);assert.equal(queue.activeCount,0);assert.equal(queue.pendingCount,0);
});
test('a failed codec releases its slot so later user work is not stranded',async()=>{
 const queue=new MediaJobScheduler({concurrency:1}),gate=deferred();const failed=queue.schedule('Inspect',()=>gate.promise),next=queue.schedule('Trim',()=>42);gate.reject(new Error('Synthetic unsupported codec'));
 await assert.rejects(failed,/unsupported codec/);assert.equal(await next,42);await turn();assert.equal(queue.activeCount,0);
});
test('cancellation racing a completed native result discards its private temporary files',async()=>{
 const queue=new MediaJobScheduler(),controller=new AbortController(),result={jobDirectory:'Synthetic owned job'},discarded=[];
 const work=queue.schedule('Inspect',()=>{controller.abort();return result;},{signal:controller.signal,onDiscard:value=>discarded.push(value)});
 await assert.rejects(work,error=>error.name==='AbortError');assert.deepEqual(discarded,[result]);await turn();assert.equal(queue.activeCount,0);
});
test('MediaJobs actually uses the bounded priority queue and disposes active cancellation signals',async()=>{
 const directory=fs.mkdtempSync(path.join(os.tmpdir(),'clipboardline-media-schedule-'));
 try{
  const jobs=new MediaJobs({directory:path.join(directory,'jobs'),concurrency:1}),gate=deferred(),started=[];
  // Control the native boundary, leaving the shipped MediaJobs queue and
  // cancellation wiring intact. No OS or codec success is simulated here.
  jobs.execute=async(mode,source,{signal})=>{started.push(source);if(source==='active')await gate.promise;assert.equal(signal instanceof AbortSignal,true);return source;};
  const active=jobs.probe('active'),background=jobs.probe('background'),trim=jobs.trim('trim',{startMs:0,endMs:50});await turn();assert.deepEqual(started,['active']);gate.resolve();assert.deepEqual(await Promise.all([active,background,trim]),['active','background','trim']);assert.deepEqual(started,['active','trim','background']);jobs.dispose();await assert.rejects(jobs.probe('after-dispose'),error=>error.name==='AbortError');
 }finally{fs.rmSync(directory,{recursive:true,force:true});}
});
