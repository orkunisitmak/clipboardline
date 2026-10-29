'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {Store}=require('../lib/model.cjs');
const png=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==','base64');
function fixture(run){const directory=fs.mkdtempSync(path.join(os.tmpdir(),'clipboardline-tags-'));try{return run(new Store(directory,{clock:()=>1000}),directory);}finally{fs.rmSync(directory,{recursive:true,force:true});}}

test('global tag rename and confirmed deletion update image text link and Trash without altering saved content',()=>fixture((store,directory)=>{
 const image=store.insert('image',png),text=store.insert('text','Synthetic saved note'),link=store.insert('link','https://example.com/reference'),other=store.insert('text','Unrelated item');
 for(const item of [image,text,link])store.modify('tag',{id:item.id,tags:['client','work']});
 store.modify('pin',{id:text.id,value:true});store.modify('trash',{id:link.id});store.modify('remove',{id:image.id});
 const preserved=store.data.items.map(({tags,...value})=>structuredClone(value));
 store.modify('renameTag',{tag:'client',name:'Renamed client'});
 for(const item of [image,text,link])assert.deepEqual(item.tags,['Renamed client','work']);assert.deepEqual(other.tags,[]);
 assert.deepEqual(store.data.items.map(({tags,...value})=>value),preserved);
 const reloaded=new Store(directory,{clock:()=>2000});assert.deepEqual(reloaded.item(link.id).tags,['Renamed client','work']);
 reloaded.modify('deleteTag',{tag:'Renamed client'});for(const id of [image.id,text.id,link.id])assert.deepEqual(reloaded.item(id).tags,['work']);
 reloaded.modify('deleteTag',{tag:'work'});for(const id of [image.id,text.id,link.id]){assert.deepEqual(reloaded.item(id).tags,[]);assert.equal(reloaded.item(id).retainedAt,1000);}
 assert.deepEqual(reloaded.data.items.map(({tags,...value})=>value),preserved);
}));

test('global tag changes reject missing names, controls, overlong names and folded collisions atomically',()=>fixture(store=>{
 const first=store.insert('text','First note'),second=store.insert('text','Second note');store.modify('tag',{id:first.id,tags:['source']});store.modify('tag',{id:second.id,tags:['Résumé']});const before=structuredClone(store.data),bytes=fs.readFileSync(store.file);
 for(const payload of [{tag:'missing',name:'New'},{tag:'source',name:''},{tag:'source',name:' '.repeat(3)},{tag:'source',name:'x'.repeat(65)},{tag:'source',name:'a\nb'},{tag:'source',name:'a\u0085b'},{tag:'source',name:'RESUME'},{tag:'source',name:'ＲＥＳＵＭＥ'}]){assert.throws(()=>store.modify('renameTag',payload));assert.deepEqual(store.data,before);assert.deepEqual(fs.readFileSync(store.file),bytes);}
 assert.throws(()=>store.modify('deleteTag',{tag:'missing'}));store.modify('renameTag',{tag:'source',name:'SOURCE'});assert.deepEqual(store.item(first.id).tags,['SOURCE']);assert.deepEqual(store.item(second.id).tags,['Résumé']);
}));

test('failed global tag persistence restores every affected membership and keeps disk intact',()=>fixture(store=>{
 const first=store.insert('text','One'),second=store.insert('text','Two');store.modify('tag',{ids:[first.id,second.id],tags:['shared']});const before=structuredClone(store.data),bytes=fs.readFileSync(store.file);store.persist=()=>{throw new Error('Synthetic save failure');};for(const action of ['renameTag','deleteTag']){assert.throws(()=>store.modify(action,{tag:'shared',name:'Renamed'}),/Synthetic save failure/);assert.deepEqual(store.data,before);assert.deepEqual(fs.readFileSync(store.file),bytes);}
}));
