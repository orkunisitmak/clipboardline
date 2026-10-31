'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const crypto=require('node:crypto');
const {Store}=require('../lib/model.cjs');
const poster=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==','base64');
function directory(prefix){return fs.mkdtempSync(path.join(__dirname,prefix));}
function installSyntheticVideoWriter(store){
 store.putVideo=async(file,{onManagedFile}={})=>{
  const contents=fs.readFileSync(file),name=crypto.createHash('sha256').update(contents).digest('hex')+path.extname(file).toLowerCase();
  try{fs.writeFileSync(path.join(store.mediaDirectory,name),contents,{flag:'wx'});}catch(error){if(error.code!=='EEXIST')throw error;}
  onManagedFile?.(name);
  return name;
 };
}
function recording(file,durationMs=1000){return{file,posterPNG:poster,durationMs,width:100,height:100,audioTracks:0,videoCodec:'H264'};}
function source(directory,name,contents){const file=path.join(directory,name);fs.writeFileSync(file,Buffer.from(contents));return file;}
function fillers(count,offset=0){const now=Date.now();return Array.from({length:count},(_,index)=>({id:'synthetic-text-'+(offset+index),kind:'text',text:'filler',url:'',title:'',name:'',pinned:false,folderIds:[],tags:[],note:'',retainedAt:null,lastCopiedAt:null,createdAt:now,updatedAt:now,trashedAt:null,hiddenFromShelf:false,annotations:[],crop:null,ocrText:''}));}
test('a recording rejected at the library item limit leaves no unreferenced managed media',async()=>{
 const data=directory('.recording-capacity-');
 try{
  const store=new Store(data),file=source(data,'synthetic-unique-recording.mp4','synthetic unique source bytes 123');installSyntheticVideoWriter(store);
  store.data.items=fillers(20000);
  const before=fs.readdirSync(store.mediaDirectory);
  await assert.rejects(store.insertRecording(recording(file)),/Library item limit reached/);
  assert.deepEqual(fs.readdirSync(store.mediaDirectory),before);
 }finally{fs.rmSync(data,{recursive:true,force:true});}
});
test('a duplicate recording can still be recaptured at the library item limit',async()=>{
 const data=directory('.recording-duplicate-capacity-');
 try{
  const store=new Store(data),file=source(data,'synthetic-duplicate-recording.mp4','synthetic duplicate source bytes 456');installSyntheticVideoWriter(store);
  const original=await store.insertRecording(recording(file));
  store.data.items.push(...fillers(19999));
  const repeated=await store.insertRecording(recording(file));
  assert.equal(repeated.id,original.id);
  assert.equal(store.data.items.length,20000);
 }finally{fs.rmSync(data,{recursive:true,force:true});}
});
test('capacity cleanup keeps assets held by an in-progress recording trim',async()=>{
 const data=directory('.recording-trim-capacity-');
 try{
  const store=new Store(data),originalFile=source(data,'original.mp4','synthetic original video bytes'),trimmedFile=source(data,'trimmed.mp4','synthetic trimmed video bytes');installSyntheticVideoWriter(store);
  const original=await store.insertRecording(recording(originalFile)),trimmedName=crypto.createHash('sha256').update(fs.readFileSync(trimmedFile)).digest('hex')+'.mp4';
  store.data.items.push(...fillers(19999));
  let announceTrimAssets;const trimAssetsReady=new Promise(resolve=>{announceTrimAssets=resolve;});
  let resumeTrim;const allowTrimCommit=new Promise(resolve=>{resumeTrim=resolve;});
  const recordingAssets=store.recordingAssets.bind(store);
  store.recordingAssets=async value=>{const assets=await recordingAssets(value);if(value.durationMs===2000){announceTrimAssets();await allowTrimCommit;}return assets;};
  const trim=store.commitRecordingTrim({...recording(trimmedFile,2000),id:original.id,sourceFingerprint:original.videoFile.slice(0,64)});
  await trimAssetsReady;
  assert.ok(fs.existsSync(path.join(store.mediaDirectory,trimmedName)));
  try{await assert.rejects(store.insertRecording(recording(trimmedFile)),/Library item limit reached/);}finally{resumeTrim();}
  await trim;
  assert.equal(store.item(original.id).renderedVideoFile,trimmedName);
  assert.ok(fs.existsSync(path.join(store.mediaDirectory,trimmedName)));
 }finally{fs.rmSync(data,{recursive:true,force:true});}
});
test('capacity cleanup keeps media referenced only by the recovery backup',async()=>{
 const data=directory('.recording-backup-capacity-');
 try{
  const store=new Store(data),originalFile=source(data,'backup-original.mp4','synthetic backup original bytes'),firstTrim=source(data,'backup-first-trim.mp4','synthetic first rendered bytes'),secondTrim=source(data,'backup-second-trim.mp4','synthetic second rendered bytes');installSyntheticVideoWriter(store);
  const item=await store.insertRecording(recording(originalFile));
  await store.commitRecordingTrim({...recording(firstTrim,2000),id:item.id,sourceFingerprint:item.videoFile.slice(0,64)});
  const firstName=crypto.createHash('sha256').update(fs.readFileSync(firstTrim)).digest('hex')+'.mp4';
  await store.commitRecordingTrim({...recording(secondTrim,3000),id:item.id,sourceFingerprint:firstName.slice(0,64)});
  const backup=JSON.parse(fs.readFileSync(store.file+'.backup','utf8'));
  assert.equal(backup.items.find(entry=>entry.id===item.id).renderedVideoFile,firstName);
  assert.notEqual(store.item(item.id).renderedVideoFile,firstName);
  store.data.items.push(...fillers(19999));
  const firstNameFile=path.join(data,'reimport-first-trim.mp4');fs.copyFileSync(firstTrim,firstNameFile);
  await assert.rejects(store.insertRecording(recording(firstNameFile)),/Library item limit reached/);
  assert.ok(fs.existsSync(path.join(store.mediaDirectory,firstName)));
 }finally{fs.rmSync(data,{recursive:true,force:true});}
});
test('capacity cleanup skips deletion when the recovery backup cannot be read',async()=>{
 const data=directory('.recording-unreadable-backup-');
 try{
  const store=new Store(data),file=source(data,'synthetic-unreadable-backup.mp4','synthetic unreadable backup bytes');installSyntheticVideoWriter(store);
  fs.writeFileSync(store.file+'.backup','not valid library JSON');
  store.data.items=fillers(20000);
  const videoName=crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')+'.mp4';
  await assert.rejects(store.insertRecording(recording(file)),/Library item limit reached/);
  assert.ok(fs.existsSync(path.join(store.mediaDirectory,videoName)));
  assert.ok(fs.readdirSync(store.mediaDirectory).some(name=>name.endsWith('.png')));
 }finally{fs.rmSync(data,{recursive:true,force:true});}
});
test('real video import registers its file before a concurrent capacity cleanup',async()=>{
 const data=directory('.recording-real-link-capacity-');let realLink,releaseLink,trim;
 try{
  const store=new Store(data),originalFile=source(data,'real-link-original.mp4','synthetic original video bytes'),trimmedFile=source(data,'real-link-trimmed.mp4','synthetic trim bytes long enough for putVideo');
  const putVideo=store.putVideo.bind(store);installSyntheticVideoWriter(store);
  const original=await store.insertRecording(recording(originalFile));store.putVideo=putVideo;store.data.items.push(...fillers(19999));
  const trimmedName=crypto.createHash('sha256').update(fs.readFileSync(trimmedFile)).digest('hex')+'.mp4';
  let announceLink;const linkStarted=new Promise(resolve=>{announceLink=resolve;});
  const linkGate=new Promise(resolve=>{releaseLink=resolve;});
  realLink=fs.promises.link.bind(fs.promises);let pauseFirstLink=true;
  fs.promises.link=async(sourcePath,destination)=>{
   if(pauseFirstLink){pauseFirstLink=false;announceLink(destination);await linkGate;}
   try{return await realLink(sourcePath,destination);}catch(error){if(error.code!=='EPERM')throw error;return fs.promises.copyFile(sourcePath,destination,fs.constants.COPYFILE_EXCL);}
  };
  trim=store.commitRecordingTrim({...recording(trimmedFile,2000),id:original.id,sourceFingerprint:original.videoFile.slice(0,64)});
  const destination=await linkStarted;
  assert.equal(path.basename(destination),trimmedName);
  assert.equal(store.inFlightMediaReferences.get(trimmedName),1);
  assert.equal(fs.existsSync(destination),false);
  try{
   await assert.rejects(store.insertRecording(recording(trimmedFile)),/Library item limit reached/);
   assert.ok(fs.existsSync(destination));
  }finally{releaseLink();}
  await trim;
  assert.equal(store.item(original.id).renderedVideoFile,trimmedName);
  assert.ok(fs.existsSync(destination));
 }finally{
  releaseLink?.();
  if(realLink)fs.promises.link=realLink;
  if(trim)await trim.catch(()=>{});
  fs.rmSync(data,{recursive:true,force:true});
 }
});
test('permanently deleting an item keeps media held by an in-progress recording import',async()=>{
 const data=directory('.recording-delete-inflight-');
 try{
  const store=new Store(data),older=source(data,'older.mp4','synthetic older video bytes'),incoming=source(data,'incoming.mp4','synthetic incoming video bytes');installSyntheticVideoWriter(store);
  const first=await store.insertRecording(recording(older)),name=crypto.createHash('sha256').update(fs.readFileSync(incoming)).digest('hex')+'.mp4';
  let announce;const ready=new Promise(resolve=>{announce=resolve;});let resume;const gate=new Promise(resolve=>{resume=resolve;});
  const recordingAssets=store.recordingAssets.bind(store);
  store.recordingAssets=async value=>{const assets=await recordingAssets(value);announce();await gate;return assets;};
  const pending=store.insertRecording(recording(incoming,2000));
  await ready;
  store.modify('trash',{id:first.id});store.modify('delete',{id:first.id});
  resume();
  const item=await pending;
  assert.equal(item.videoFile,name);
  assert.ok(fs.existsSync(path.join(store.mediaDirectory,name)));
  assert.ok(fs.existsSync(path.join(store.mediaDirectory,item.imageFile)));
 }finally{fs.rmSync(data,{recursive:true,force:true});}
});
