'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const {OcrQueue,createOcrQueue}=require('../lib/ocr-queue.cjs');

test('background OCR drains more than 64 accepted images to the worker in FIFO order',async()=>{
 const processed=[],scheduled=[];
 const {queue,queueOCR}=createOcrQueue({enabled:()=>true,closing:()=>false,schedule:work=>scheduled.push(work),process:async id=>processed.push(id)});
 const ids=Array.from({length:70},(_,index)=>`image-${index}`);
 for(const id of ids)assert.equal(queueOCR(id),true,id);
 assert.equal(queueOCR(ids[0]),false);
 assert.equal(queue.size,70);
 assert.equal(scheduled.length,1);
 await scheduled.shift()();
 assert.deepEqual(processed,ids);
 assert.equal(queue.size,0);
});

test('background OCR gates disabled work and permits a retry after dequeue',async()=>{
 const scheduled=[],processed=[];
 const disabled=new OcrQueue({enabled:()=>false,closing:()=>false,schedule:work=>scheduled.push(work),process:async id=>processed.push(id)});
 assert.equal(disabled.enqueue('disabled-image'),false);
 assert.equal(disabled.size,0);
 let queue,retryAccepted=false;
 queue=new OcrQueue({enabled:()=>true,closing:()=>false,schedule:work=>scheduled.push(work),process:async id=>{processed.push(id);if(processed.length===1)retryAccepted=queue.enqueue(id);}});
 assert.equal(queue.enqueue('image-a'),true);
 assert.equal(queue.enqueue('image-a'),false);
 await scheduled.shift()();
 assert.equal(retryAccepted,true);
 assert.deepEqual(processed,['image-a','image-a']);
 assert.equal(queue.dequeue(),undefined);
});

test('background OCR discards queued work when indexing is disabled before drain',async()=>{
 const scheduled=[],processed=[];let enabled=true;
 const queue=new OcrQueue({enabled:()=>enabled,closing:()=>false,schedule:work=>scheduled.push(work),process:async id=>processed.push(id)});
 for(const id of ['image-a','image-b','image-c'])assert.equal(queue.enqueue(id),true);
 enabled=false;
 await scheduled.shift()();
 assert.deepEqual(processed,[]);
 assert.equal(queue.size,0);
 assert.equal(scheduled.length,0);
 enabled=true;queue.drainSoon();
 assert.equal(scheduled.length,0);
});

test('background OCR stops after the active image when indexing is disabled',async()=>{
 const scheduled=[],processed=[];let enabled=true;
 const queue=new OcrQueue({enabled:()=>enabled,closing:()=>false,schedule:work=>scheduled.push(work),process:async id=>{processed.push(id);if(id==='image-a')enabled=false;}});
 for(const id of ['image-a','image-b','image-c'])assert.equal(queue.enqueue(id),true);
 await scheduled.shift()();
 assert.deepEqual(processed,['image-a']);
 assert.equal(queue.size,0);
 enabled=true;queue.drainSoon();
 assert.equal(scheduled.length,0);
});



test('discarding pending OCR on disable survives re-enable before the active image finishes',async()=>{
 const scheduled=[],processed=[];let enabled=true,finishActive,activeStarted;
 const started=new Promise(resolve=>{activeStarted=resolve;});
 const queue=new OcrQueue({enabled:()=>enabled,closing:()=>false,schedule:work=>scheduled.push(work),process:id=>{
  processed.push(id);
  if(id==='image-a')return new Promise(resolve=>{finishActive=resolve;activeStarted();});
 }});
 for(const id of ['image-a','image-b','image-c'])assert.equal(queue.enqueue(id),true);
 const drain=scheduled.shift()();
 await started;
 enabled=false;queue.discardPending();
 enabled=true;
 finishActive();
 await drain;
 assert.deepEqual(processed,['image-a']);
 assert.equal(queue.size,0);
 assert.equal(scheduled.length,0);
});
