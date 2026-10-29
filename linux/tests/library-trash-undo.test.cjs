'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {Store}=require('../lib/model.cjs');
const png=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==','base64');
const clone=value=>JSON.parse(JSON.stringify(value));
function fixture(run){const directory=fs.mkdtempSync(path.join(os.tmpdir(),'clipboardline-library-trash-'));let now=1000;try{return run(new Store(directory,{clock:()=>now}),value=>{now=value;},directory);}finally{fs.rmSync(directory,{recursive:true,force:true});}}
function content(value){const {trashedAt,trashRevision,hiddenFromShelf,updatedAt,...body}=value;return body;}

test('Library Trash is one durable mixed batch; Undo restores original shelf flags without rewriting content or organization',()=>fixture((store,time,directory)=>{
 const a=store.insert('text','Synthetic saved note'),b=store.insert('image',png),c=store.insert('link','https://example.com/library-keyboard');
 const folder=store.modify('createFolder',{name:'Synthetic folder'});store.modify('folder',{id:a.id,folderId:folder.id,pinning:false});store.modify('tag',{id:c.id,tags:['synthetic-tag']});store.modify('name',{id:b.id,name:'Synthetic image'});store.modify('remove',{id:b.id});
 const before=new Map([a,b,c].map(value=>[value.id,clone(value)])),file=store.mediaPath(b.id),bytes=fs.readFileSync(file),persist=store.persist.bind(store);let saves=0;store.persist=()=>{saves++;persist();};
 time(2000);const moved=store.modify('trashUndoably',{ids:[c.id,b.id,a.id,a.id]});assert.deepEqual(moved.ids,[c.id,b.id,a.id]);assert.equal(saves,1);assert.equal(store.publicState().canUndoTrash,true);
 for(const id of moved.ids){const value=store.item(id);assert.equal(value.trashedAt,2000);assert.equal(value.hiddenFromShelf,true);assert.match(value.trashRevision,/^[a-f0-9-]{36}$/);assert.deepEqual(content(value),content(before.get(id)));}
 const loaded=new Store(directory,{clock:()=>2000});assert.equal(loaded.publicState().canUndoTrash,false,'Undo journal is session-local; Trash remains durable');assert.ok(loaded.item(a.id).trashedAt);
 time(3000);const result=store.modify('undoTrash');assert.deepEqual(result.ids,moved.ids);assert.equal(saves,2);assert.equal(store.publicState().canUndoTrash,false);
 for(const id of moved.ids){const value=store.item(id);assert.equal(value.trashedAt,null);assert.equal(value.trashRevision,null);assert.equal(value.hiddenFromShelf,before.get(id).hiddenFromShelf);assert.equal(value.updatedAt,3000);assert.deepEqual(content(value),content(before.get(id)));}
 assert.deepEqual(fs.readFileSync(file),bytes);
}));

test('Trash ignores missing and already trashed IDs, deduplicates in input order, and empty Undo never writes',()=>fixture(store=>{
 const a=store.insert('text','First note'),b=store.insert('text','Already trashed');store.modify('trash',{id:b.id});const count=store.trashUndoStack.length;
 const result=store.modify('trashUndoably',{ids:['00000000-0000-4000-8000-000000000099',a.id,b.id,a.id]});assert.deepEqual(result.ids,[a.id]);assert.equal(store.trashUndoStack.length,count+1);
 assert.throws(()=>store.modify('trashUndoably',{ids:['../private']}),/Invalid item selection/);
 store.modify('undoTrash');store.modify('undoTrash');const before=fs.readFileSync(store.file);assert.deepEqual(store.modify('undoTrash'),{ids:[]});assert.deepEqual(fs.readFileSync(store.file),before);
}));

for(const mutation of ['edit','copy','pin','folder','restore','delete'])test('same-clock '+mutation+' invalidates only changed Trash records; untouched peers undo safely',()=>fixture(store=>{
 const a=store.insert('text','Changed version'),b=store.insert('text','Untouched peer');store.modify('trashUndoably',{ids:[a.id,b.id]});
 if(mutation==='edit')store.modify('details',{id:a.id,note:'Later organization note'});
 if(mutation==='copy')store.markCopied([a.id]);
 if(mutation==='pin')store.modify('pin',{id:a.id,value:true});
 if(mutation==='folder'){const folder=store.modify('createFolder',{name:'Later folder'});store.modify('folder',{id:a.id,folderId:folder.id});}
 if(mutation==='restore')store.modify('restore',{id:a.id});
 if(mutation==='delete')store.modify('delete',{id:a.id});
 const changed=store.data.items.find(value=>value.id===a.id),before=changed&&clone(changed);assert.deepEqual(store.modify('undoTrash').ids,[b.id]);assert.equal(store.item(b.id).trashedAt,null);assert.deepEqual(store.data.items.find(value=>value.id===a.id),before);
}));

test('same-clock restore then re-Trash rotates the durable version and cannot revive an older undo batch',()=>fixture(store=>{
 const a=store.insert('text','Versioned note');store.modify('trashUndoably',{id:a.id});const first=a.trashRevision;store.modify('restore',{id:a.id});assert.equal(store.publicState().canUndoTrash,false);
 store.modify('trash',{id:a.id});assert.notEqual(a.trashRevision,first);assert.equal(store.trashUndoStack.length,1);assert.deepEqual(store.modify('undoTrash').ids,[a.id]);assert.deepEqual(store.modify('undoTrash').ids,[]);
}));

test('failed Trash and failed Undo preserve durable records and both undo journals for an explicit retry',()=>fixture(store=>{
 const a=store.insert('text','Durable note');const persist=store.persist.bind(store),before=clone(store.data);store.persist=()=>{throw new Error('Synthetic unavailable disk');};
 assert.throws(()=>store.modify('trashUndoably',{id:a.id}),/unavailable disk/);assert.deepEqual(store.data,before);assert.equal(store.trashUndoStack.length,0);store.persist=persist;
 store.modify('trashUndoably',{id:a.id});const trashed=clone(store.data),journal=clone(store.trashUndoStack);store.persist=()=>{throw new Error('Synthetic unavailable disk');};assert.throws(()=>store.modify('undoTrash'),/unavailable disk/);assert.deepEqual(store.data,trashed);assert.deepEqual(store.trashUndoStack,journal);store.persist=persist;assert.deepEqual(store.modify('undoTrash').ids,[a.id]);
}));

test('retention and cleanup do not become explicit user Undo; their Trash versions remain valid on reload',()=>fixture((store,time,directory)=>{
 const a=store.insert('text','Expired copy');time(32*86400000);store.expire();assert.ok(a.trashedAt);assert.match(a.trashRevision,/^[a-f0-9-]{36}$/);assert.equal(store.publicState().canUndoTrash,false);
 const b=store.insert('text','Cleared copy');store.modify('clearUnsavedHistory',store.unsavedHistorySnapshot());assert.ok(b.trashedAt);assert.match(b.trashRevision,/^[a-f0-9-]{36}$/);assert.equal(store.publicState().canUndoTrash,false);
 const loaded=new Store(directory,{clock:()=>32*86400000});assert.equal(loaded.item(a.id).trashRevision,a.trashRevision);assert.equal(loaded.item(b.id).trashRevision,b.trashRevision);
 loaded.item(a.id).trashRevision='../invalid';loaded.persist();assert.throws(()=>new Store(directory),/Invalid item selection/);
}));
