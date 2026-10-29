'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const {EventEmitter}=require('node:events');
const fs=require('node:fs');
const os=require('node:os');
const path=require('node:path');
const {ClipTokenizer}=require('../lib/clip-tokenizer.cjs');
const {normalized,score,rankedMatches,imageRegions,imageTensors}=require('../lib/image-search-core.cjs');
const {ImageSearch}=require('../lib/image-search.cjs');
const tick=()=>new Promise(setImmediate);
const key='a'.repeat(64),other='b'.repeat(64),id='10000000-0000-4000-8000-000000000001',id2='10000000-0000-4000-8000-000000000002';

test('CLIP BPE uses ranked byte merges, Unicode bytes, context truncation and zero padding',()=>{
 const tokenizer=new ClipTokenizer({'hello</w>':17,'a</w>':9,'Ã':20,'©</w>':21},'#version\nh e\nhe l\nhel l\nhell o</w>\n');
 assert.deepEqual(tokenizer.encode(' HELLO\n a '),[49406,17,9,49407]);assert.deepEqual(tokenizer.encode('é'),[49406,20,21,49407]);
 const many=tokenizer.encode(Array(100).fill('a').join(' '));assert.equal(many.length,77);assert.equal(many[76],49407);assert.deepEqual([...tokenizer.tensor('a').slice(0,5)],[49406n,9n,49407n,0n,0n]);
});

test('visual ranking matches the Mac absolute, near-best and scoped population thresholds',()=>{
 const values=[{id:'a',score:.40},{id:'b',score:.36},{id:'c',score:.35},{id:'d',score:.21}];assert.deepEqual(rankedMatches(values).map(value=>value.id),['a','b']);
 assert.deepEqual(rankedMatches([{id:'b',score:.23},{id:'a',score:.23}]).map(value=>value.id),['a','b']);
 assert.deepEqual(rankedMatches(Array.from({length:8},(_,index)=>({id:String(index),score:.23}))),[]);
 assert.deepEqual(rankedMatches([{id:'a',score:.29},...Array.from({length:8},(_,index)=>({id:String(index),score:.20}))]).map(value=>value.id),['a']);
 assert.deepEqual(rankedMatches([{id:'bad',score:NaN},{id:'infinity',score:Infinity}]),[]);
});

test('512-vectors normalize and score the best tile; malformed or nonfinite vectors are rejected',()=>{
 const values=new Float32Array(512);values[0]=3;values[1]=4;const query=normalized(values);assert.ok(Math.abs(query[0]-.6)<1e-6);assert.ok(Math.abs(query[1]-.8)<1e-6);
 const negative=Float32Array.from(query,value=>-value);assert.ok(Math.abs(score(query,[negative,query])-1)<1e-6);
 assert.equal(normalized(new Float32Array(511)),null);assert.equal(normalized(new Float32Array(512)),null);values[7]=Infinity;assert.equal(normalized(values),null);assert.equal(score(query,[new Float32Array(2)]),null);
});

test('image preprocessing uses the same sliver limits, neutral letterbox and up to three long-axis crops',()=>{
 assert.deepEqual(imageRegions(1024,119),[]);assert.deepEqual(imageRegions(1024,120),[]);assert.equal(imageRegions(300,300).length,1);assert.equal(imageRegions(600,300).length,3);assert.equal(imageRegions(900,300).length,4);
 const bitmap=new Uint8Array(600*300*4);for(let index=0;index<bitmap.length;index+=4){bitmap[index]=0;bitmap[index+1]=0;bitmap[index+2]=255;bitmap[index+3]=255;}
 const tensors=imageTensors(bitmap,600,300);assert.equal(tensors.length,3);assert.equal(tensors[0].length,3*256*256);assert.ok(Math.abs(tensors[0][0]-128/255)<1e-6);assert.equal(tensors[0][128*256+128],1);assert.equal(tensors[0][256*256+128*256+128],0);assert.equal(tensors[1][0],1);
 assert.throws(()=>imageTensors(new Uint8Array(4),600,300),/pixels/);assert.throws(()=>imageRegions(5000,5000),/dimensions/);
});

class FakeWorker extends EventEmitter{
 constructor(){super();this.messages=[];this.response=null;queueMicrotask(()=>this.emit('message',{event:'ready',available:true}));}
 postMessage(message){this.messages.push(message);const reply=this.response?.(message);if(reply==='__hold__')return;queueMicrotask(()=>this.emit('message',{id:message.id,result:reply??(message.action==='search'?{ids:[],scores:[]}:true)}));}
 unref(){}async terminate(){this.terminated=true;}
}
function service(){const worker=new FakeWorker(),records=[{id,kind:'image',imageFile:key+'.png'}],changes=[];let reads=0;const search=new ImageSearch({modelDirectory:'unused',cacheDirectory:'unused',items:()=>records,readImage:()=>{reads++;return{bitmap:new Uint8Array(128*128*4),width:128,height:128};},changed:value=>changes.push(value),workerFactory:()=>worker});return{worker,records,search,changes,get reads(){return reads;}};}

test('derived indexing deduplicates content, reuses cached pixels, broadcasts revisions and excludes stale or deleted search identities',async()=>{
 const f=service();await f.search.ready;f.records.push({id:id2,kind:'image',imageFile:key+'.png'});f.search.refresh();for(let i=0;i<8;i++)await tick();
 assert.equal(f.worker.messages.filter(value=>value.action==='has').length,1);assert.equal(f.reads,0);assert.ok(f.search.state.revision>0);assert.equal(f.search.state.indexing,false);
 f.worker.response=message=>{if(message.action==='search'){assert.deepEqual(message.payload.entries.map(value=>value.id),[id]);f.records[0].renderedFile=other+'.png';return{ids:[id,id2],scores:[{id,score:.9},{id:id2,score:.95}]};}};
 assert.deepEqual(await f.search.search('a red circle',[id]),{ids:[],scores:[],available:true,indexing:false});await f.search.stop();assert.equal(f.worker.terminated,true);
});

test('indexing offloads only bounded pixels and never accepts old crop work after a rendered fingerprint changes',async()=>{
 const f=service();await f.search.ready;let release;f.worker.response=message=>message.action==='has'?false:undefined;f.search.readImage=async()=>{await new Promise(resolve=>{release=resolve;});return{bitmap:new Uint8Array(128*128*4),width:128,height:128};};f.search.refresh();for(let i=0;i<4;i++)await tick();
 f.records[0].renderedFile=other+'.png';release();for(let i=0;i<4;i++)await tick();assert.equal(f.worker.messages.filter(value=>value.action==='index').length,0);assert.equal(f.search.known.has(key),false);await f.search.stop();
});

test('search input bounds, secure ID parsing and worker failure do not touch canonical records',async()=>{
 const f=service();await f.search.ready;const before=structuredClone(f.records);await assert.rejects(()=>f.search.search('x'.repeat(2049),[id]),/2,048/);await assert.rejects(()=>f.search.search('query',['../private']),/Invalid item/);
 f.worker.emit('error',new Error('Synthetic model worker failure'));assert.equal(f.search.state.available,false);assert.deepEqual(f.records,before);assert.equal((await f.search.search('query',[id])).available,false);await f.search.stop();
});

test('missing bundled models fail closed in a real worker without creating an external request',async()=>{
 const directory=fs.mkdtempSync(path.join(os.tmpdir(),'clipboardline-no-model-'));const search=new ImageSearch({modelDirectory:directory,cacheDirectory:path.join(directory,'cache'),items:()=>[],readImage:()=>null});
 try{assert.equal(await search.ready,false);assert.deepEqual(await search.search('query',[]),{ids:[],scores:[],available:false,indexing:false});}finally{await search.stop();fs.rmSync(directory,{recursive:true,force:true});}
});
