'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const os=require('node:os');
const {Store}=require('../lib/model.cjs');
const png=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==','base64');

test('an image rejected at the library item limit leaves no unreferenced managed PNG',()=>{
 const directory=fs.mkdtempSync(path.join(os.tmpdir(),'clipboardline-image-capacity-'));
 try{
  const store=Object.create(Store.prototype);
  store.file=path.join(directory,'library.json');
  store.mediaDirectory=path.join(directory,'media');
  fs.mkdirSync(store.mediaDirectory);
  store.data={items:Array.from({length:20000},(_,index)=>({id:String(index),kind:'text',trashedAt:null}))};
  store.inFlightMediaReferences=new Map();
  assert.throws(()=>store.insert('image',png),/Library item limit reached/);
  assert.deepEqual(fs.readdirSync(store.mediaDirectory),[]);
 }finally{fs.rmSync(directory,{recursive:true,force:true});}
});
