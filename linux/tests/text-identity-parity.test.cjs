'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {Store}=require('../lib/model.cjs');
const contract=require('../../contracts/text-identity.json');

test('shared text identities preserve latest literal bytes and saved organization across recapture and restart',()=>{
 const directory=fs.mkdtempSync(path.join(os.tmpdir(),'clipboardline-text-parity-'));
 try{
  let now=1000,store=new Store(directory,{clock:()=>now});
  const folder=store.modify('createFolder',{name:'Synthetic references'}),identities=new Map();
  for(const entry of contract.cases){
   const first=store.insert('text',entry.copies[0]);identities.set(entry.id,first.id);
   store.modify('name',{id:first.id,name:entry.id});store.modify('folder',{ids:[first.id],folderId:folder.id});
   store.modify('tag',{ids:[first.id],tags:['synthetic']});store.modify('details',{id:first.id,note:'Personal synthetic note'});
   const retained=first.retainedAt;
   for(const body of entry.copies){now+=1000;const latest=store.insert('text',body);
    assert.equal(latest.id,first.id,entry.id);assert.equal(Buffer.from(latest.text).equals(Buffer.from(body)),true,entry.id);
    assert.equal(latest.name,entry.id);assert.equal(latest.pinned,true);assert.equal(latest.note,'Personal synthetic note');
    assert.deepEqual(latest.folderIds,[folder.id]);assert.deepEqual(latest.tags,['synthetic']);assert.equal(latest.retainedAt,retained);
    assert.equal(store.data.items[0].id,first.id);assert.equal(latest.createdAt,now);
   }
   store=new Store(directory,{clock:()=>now});
  }
  assert.equal(new Set(identities.values()).size,contract.cases.length);
  assert.equal(store.data.items.filter(item=>!item.trashedAt).length,contract.cases.length);
  for(const entry of contract.cases){now+=1000;const latest=store.insert('text',entry.copies.at(-1));assert.equal(latest.id,identities.get(entry.id));}
 }finally{fs.rmSync(directory,{recursive:true,force:true});}
});

test('normalized recapture repairs old duplicate groups without dropping names, pins, folders, tags or notes',()=>{
 const directory=fs.mkdtempSync(path.join(os.tmpdir(),'clipboardline-text-repair-'));
 try{
  let now=1000;const store=new Store(directory,{clock:()=>now});
  const first=store.insert('text','café\nline'),second=store.insert('text','temporary duplicate seed');
  store.modify('name',{id:first.id,name:'Named synthetic reference'});const folder=store.modify('createFolder',{name:'Folder'});
  store.modify('folder',{ids:[first.id],folderId:folder.id});store.modify('tag',{ids:[second.id],tags:['keep']});
  store.modify('details',{id:second.id,note:'Preserve this note'});store.modify('editText',{id:second.id,text:'cafe\u0301\r\nline\n'});
  now=2000;const latest=store.insert('text','\ncafé\nline\r\n');
  assert.equal(store.data.items.length,1);assert.equal(latest.name,'Named synthetic reference');assert.equal(latest.pinned,true);
  assert.deepEqual(latest.folderIds,[folder.id]);assert.deepEqual(latest.tags,['keep']);assert.equal(latest.note,'Preserve this note');
  assert.equal(latest.text,'\ncafé\nline\r\n');
 }finally{fs.rmSync(directory,{recursive:true,force:true});}
});

test('editing changes the cached identity and explicitly trashed records are not resurrected by normalized recapture',()=>{
 const directory=fs.mkdtempSync(path.join(os.tmpdir(),'clipboardline-text-edit-'));
 try{
  const store=new Store(directory),original=store.insert('text','café');store.insert('text','cafe\u0301\n');
  store.modify('editText',{id:original.id,text:'edited'});const newOriginal=store.insert('text','café\r\n');
  assert.notEqual(newOriginal.id,original.id);assert.equal(store.insert('text','\nedited\n').id,original.id);
  store.modify('trash',{ids:[original.id]});assert.notEqual(store.insert('text','edited\r\n').id,original.id);
  assert.ok(store.item(original.id).trashedAt);
 }finally{fs.rmSync(directory,{recursive:true,force:true});}
});
