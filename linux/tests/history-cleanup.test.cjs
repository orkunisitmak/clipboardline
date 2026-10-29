'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const os=require('node:os');
const path=require('node:path');
const {Store,saved}=require('../lib/model.cjs');
const contract=require('../../contracts/history-cleanup.json');
const png=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==','base64');
const clone=value=>JSON.parse(JSON.stringify(value));
function fixture(run){
 const folder=fs.mkdtempSync(path.join(os.tmpdir(),'clipboardline-history-cleanup-'));
 try{return run(new Store(folder,{clock:()=>1700000000000}),folder);}finally{fs.rmSync(folder,{recursive:true,force:true});}
}
for(const scenario of contract.scenarios)test('shared history cleanup: '+scenario.id,()=>fixture((store,folder)=>{
 const aliases=new Map(),images=new Map(),destination=store.modify('createFolder',{name:'Retained folder'});
 for(const input of contract.records){
  const value=store.insert(input.kind,input.kind==='image'?Buffer.concat([png,Buffer.from(input.id)]):input.kind==='link'?'https://example.com/'+input.id:'Synthetic '+input.id);
  aliases.set(input.id,value.id);
  if(input.kind==='image')images.set(store.mediaPath(value.id),fs.readFileSync(store.mediaPath(value.id)));
  if(input.save==='pin')store.modify('pin',{id:value.id,value:true});
  if(input.save==='unpin'){store.modify('pin',{id:value.id,value:true});store.modify('pin',{id:value.id,value:false});}
  if(input.save==='folder')store.modify('folder',{id:value.id,folderId:destination.id});
  if(input.save==='tag')store.modify('tag',{id:value.id,tags:['retained-tag']});
  if(input.save==='trash')store.modify('trash',{id:value.id});
 }
 const fileBefore=fs.readFileSync(store.file),snapshot=store.unsavedHistorySnapshot(scenario.kind);
 assert.deepEqual(snapshot.ids,[...scenario.captured.map(name=>aliases.get(name))].sort());
 assert.deepEqual(fs.readFileSync(store.file),fileBefore,'Reading candidates performs no persistence');
 for(const name of scenario.retainAfterSnapshot||[])store.modify('retain',{id:aliases.get(name)});
 for(const name of scenario.recopyAfterSnapshot||[]){const value=store.item(aliases.get(name));assert.equal(store.insert(value.kind,value.kind==='text'?value.text:value.url).id,value.id);}
 const later=scenario.newCopyAfterSnapshot?store.insert('text','Synthetic later copy'):null;
 const savedBefore=store.data.items.filter(saved).map(clone),beforeCancel=fs.readFileSync(store.file);
 const result=scenario.cancel?{ids:[]}:store.modify('clearUnsavedHistory',snapshot);
 assert.deepEqual([...result.ids].sort(),scenario.trashed.map(name=>aliases.get(name)).sort());
 if(scenario.cancel)assert.deepEqual(fs.readFileSync(store.file),beforeCancel);
 for(const value of savedBefore)assert.deepEqual(store.item(value.id),value,'Saved records stay unchanged');
 if(later)assert.equal(store.item(later.id).trashedAt,null);
 for(const id of result.ids){assert.ok(store.item(id).trashedAt);assert.equal(store.item(id).hiddenFromShelf,true);}
 for(const [file,bytes]of images)assert.deepEqual(fs.readFileSync(file),bytes);
 if(!scenario.cancel){
  const beforeRepeat=fs.readFileSync(store.file);assert.deepEqual(store.modify('clearUnsavedHistory',snapshot),{ids:[]});assert.deepEqual(fs.readFileSync(store.file),beforeRepeat);
  if(result.ids.length)store.modify('restore',{ids:result.ids});
 }
 const reopened=new Store(folder,{clock:()=>1700000000000});
 for(const id of result.ids){assert.equal(reopened.item(id).trashedAt,null);assert.deepEqual(reopened.item(id),store.item(id));}
 assert.deepEqual(reopened.item(aliases.get('folder-link')).folderIds,[destination.id]);
 assert.deepEqual(reopened.item(aliases.get('tagged-text')).tags,['retained-tag']);
}));
test('cleanup is atomic on persistence failure and rejects malformed snapshots',()=>fixture(store=>{
 const first=store.insert('text','First'),second=store.insert('link','https://example.com/second');
 const snapshot=store.unsavedHistorySnapshot(),before=clone(store.data),persist=store.persist;
 store.persist=()=>{throw new Error('Synthetic cleanup write failure');};
 assert.throws(()=>store.modify('clearUnsavedHistory',snapshot),/cleanup write failure/);assert.deepEqual(store.data,before);store.persist=persist;
 for(const payload of [{kind:'invalid',ids:[first.id]},{kind:'text',ids:['../escape']},{kind:'all',ids:null}]){
  assert.throws(()=>store.modify('clearUnsavedHistory',payload));assert.deepEqual(store.data,before);
 }
 const result=store.modify('clearUnsavedHistory',{...store.unsavedHistorySnapshot('text'),ids:[first.id,second.id,first.id]});
 assert.deepEqual(result.ids,[first.id]);assert.equal(store.item(second.id).trashedAt,null);
}));
test('one confirmation can clean more than the ordinary selection limit in one durable commit',()=>fixture(store=>{
 const source=store.insert('text','Synthetic seed');
 store.data.items=Array.from({length:10001},(_,index)=>({...clone(source),id:'10000000-0000-4000-8000-'+String(index).padStart(12,'0'),text:'Synthetic record '+index}));
 store.persist();const snapshot=store.unsavedHistorySnapshot();let writes=0;const persist=store.persist.bind(store);store.persist=()=>{writes++;persist();};
 assert.equal(snapshot.ids.length,10001);assert.equal(store.modify('clearUnsavedHistory',snapshot).ids.length,10001);
 assert.equal(writes,1);assert.ok(store.data.items.every(item=>item.trashedAt));
}));
test('a same-image recopy at an unchanged clock keeps its stable item identity outside an old confirmation',()=>fixture(store=>{
 const image=store.insert('image',png),snapshot=store.unsavedHistorySnapshot('image'),oldVersion=image.captureRevision;
 const recopy=store.insert('image',png);assert.equal(recopy.id,image.id);assert.notEqual(recopy.captureRevision,oldVersion);
 assert.deepEqual(store.modify('clearUnsavedHistory',snapshot),{ids:[]});assert.equal(store.item(image.id).trashedAt,null);
}));
test('copy-latest markCopied preserves a confirmed item even when the clock and updatedAt do not advance',()=>fixture(store=>{
 const value=store.insert('text','Synthetic copy latest'),snapshot=store.unsavedHistorySnapshot();store.markCopied([value.id]);
 assert.deepEqual(store.modify('clearUnsavedHistory',snapshot),{ids:[]});assert.equal(store.item(value.id).trashedAt,null);
}));
