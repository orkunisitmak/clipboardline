'use strict';

const assert=require('node:assert/strict');
const {test}=require('node:test');
const fs=require('node:fs');
const os=require('node:os');
const path=require('node:path');
const {Store}=require('../lib/model.cjs');
const {copyNewCapture,PASTE_SETTLE_MS}=require('../lib/capture-copy.cjs');

const png=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==','base64');
function fixture(fn){const dir=fs.mkdtempSync(path.join(os.tmpdir(),'clipboardline-capture-copy-'));return Promise.resolve().then(()=>fn(new Store(dir,{clock:()=>1000}),dir)).finally(()=>fs.rmSync(dir,{recursive:true,force:true}));}
function arrive(store,item,written,pasting=false,write=async selected=>{written.push(selected.map(entry=>entry.id));}){return copyNewCapture({settings:store.data.settings,item,items:store.data.items,write,pasting,warn:()=>{}});}

test('copy new screenshots is off by default, validated and kept across restart like macOS',()=>fixture((s,dir)=>{
  assert.equal(s.data.settings.copyNewCaptures,false);
  assert.throws(()=>s.modify('setSettings',{patch:{copyNewCaptures:'yes'}}),/Invalid preference/);
  s.modify('setSettings',{patch:{copyNewCaptures:true}});
  assert.equal(new Store(dir).data.settings.copyNewCaptures,true);
}));

test('a new screenshot is copied only while the setting is on',()=>fixture(async s=>{
  const written=[];
  const first=s.insert('image',png);
  assert.equal(await arrive(s,first,written),false);
  assert.deepEqual(written,[]);
  s.modify('setSettings',{patch:{copyNewCaptures:true}});
  const second=s.insert('image',Buffer.concat([png,Buffer.from([1])]));
  assert.equal(await arrive(s,second,written),true);
  assert.deepEqual(written,[[second.id]]);
}));

test('recordings, text files and items removed before the copy leave the clipboard alone',()=>fixture(async s=>{
  s.modify('setSettings',{patch:{copyNewCaptures:true}});
  const written=[];
  const text=s.insert('text','notes.txt contents');
  const image=s.insert('image',png);
  s.modify('trash',{ids:[image.id]});
  assert.equal(await arrive(s,text,written),false);
  assert.equal(await arrive(s,image,written),false);
  const recording=s.insert('image',Buffer.concat([png,Buffer.from([2])]));recording.recording=true;
  assert.ok(s.data.items.includes(recording));
  assert.equal(await arrive(s,recording,written),false);
  assert.deepEqual(written,[]);
}));

test('a failed copy is reported to the user and does not stop the capture from hanging',()=>fixture(async s=>{
  s.modify('setSettings',{patch:{copyNewCaptures:true}});
  const image=s.insert('image',png),warnings=[];
  const notices=[];
  const copied=await copyNewCapture({settings:s.data.settings,item:image,items:s.data.items,write:async()=>{throw new Error('Clipboard busy');},warn:(...args)=>warnings.push(args.join(' ')),failed:async text=>{await Promise.resolve();notices.push(text);}});
  assert.equal(copied,false);
  assert.deepEqual(warnings,['New capture copy error: Clipboard busy']);
  assert.deepEqual(notices,['The new screenshot was not copied'],'The user hears that the capture did not reach the clipboard');
  assert.ok(s.data.items.includes(image));
}));

test('a capture during a direct paste, or just after it, hangs without replacing what is being pasted',()=>fixture(async s=>{
  s.modify('setSettings',{patch:{copyNewCaptures:true}});
  const written=[];
  const during=s.insert('image',png);
  assert.equal(await arrive(s,during,written,true),false);
  assert.deepEqual(written,[]);
  assert.ok(s.data.items.includes(during));
  const later=s.insert('image',Buffer.concat([png,Buffer.from([3])]));
  assert.equal(await arrive(s,later,written,false),true);
  assert.deepEqual(written,[[later.id]]);
  assert.equal(PASTE_SETTLE_MS,1000,'Matches the macOS settle time after a direct paste');
}));
