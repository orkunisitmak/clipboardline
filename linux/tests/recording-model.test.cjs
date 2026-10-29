'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),os=require('node:os'),crypto=require('node:crypto');
const {Store}=require('../lib/model.cjs'),{metadata,MediaJobs}=require('../lib/media.cjs');
const poster=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==','base64');
const fixtures=path.join(__dirname,'fixtures','recordings'),source=path.join(fixtures,'synthetic-rgb-tone.mp4');
async function fixture(fn){const directory=fs.mkdtempSync(path.join(os.tmpdir(),'clipboardline-recording-'));try{return await fn(new Store(directory),directory);}finally{fs.rmSync(directory,{recursive:true,force:true});}}
const imported=file=>({file,posterPNG:poster,durationMs:6000,width:160,height:120,audioTracks:1,videoCodec:'H264'});
const fingerprint=(store,id)=>store.publicState().items.find(item=>item.id===id).sourceFingerprint;
test('recordings stream into hashed private files, stay in Images and expose only safe media IDs',()=>fixture(async(store,directory)=>{
 const item=await store.insertRecording(imported(source)),original=store.mediaPath(item.id,true);assert.equal(item.kind,'image');assert.equal(item.recording,true);
 const digest=crypto.createHash('sha256').update(fs.readFileSync(source)).digest('hex');assert.equal(path.basename(original),digest+'.mp4');assert.equal(fs.readFileSync(original).equals(fs.readFileSync(source)),true);assert.equal(fingerprint(store,item.id),digest);
 assert.notEqual(store.posterPath(item.id),original);const state=store.publicState().items[0];assert.equal(state.videoFile,undefined);assert.equal(state.renderedVideoFile,undefined);assert.equal(state.videoUrl,'appmedia://media/'+item.id+'/video?v='+digest);assert.match(state.originalVideoUrl,/\/video\/original$/);assert.ok(!JSON.stringify(state).includes(directory));
 assert.equal(new Store(directory).item(item.id).durationMs,6000);if(process.platform!=='win32')assert.equal(fs.statSync(original).mode&0o777,0o600);
 const still=store.insert('image',poster);assert.notEqual(still.id,item.id);assert.equal(still.recording,undefined);
}));
test('recording recapture preserves names, pins, folders, tags and original media',()=>fixture(async(store)=>{
 const first=await store.insertRecording(imported(source));store.modify('name',{id:first.id,name:'Reference clip'});const folder=store.modify('createFolder',{name:'Video references'});store.modify('folder',{ids:[first.id],folderId:folder.id});store.modify('tag',{ids:[first.id],tags:['reference']});
 const repeated=await store.insertRecording(imported(source));assert.equal(first.id,repeated.id);assert.equal(store.data.items.length,1);assert.equal(repeated.name,'Reference clip');assert.equal(repeated.pinned,true);assert.deepEqual(repeated.folderIds,[folder.id]);assert.deepEqual(repeated.tags,['reference']);
 const mov=await store.insertRecording(imported(path.join(fixtures,'synthetic-rgb-tone.mov')));assert.match(store.mediaPath(mov.id,true),/\.mov$/);
}));
test('trim transaction preserves original video and organization and rejects stale or trashed targets',()=>fixture(async(store,directory)=>{
 const item=await store.insertRecording(imported(source)),original=store.mediaPath(item.id,true),hash=fingerprint(store,item.id),originalURL=store.publicState().items[0].videoUrl;store.modify('name',{id:item.id,name:'Kept name'});assert.equal(store.publicState().items[0].videoUrl,originalURL);
 // This test exercises storage transaction semantics; the separate native
 // suite verifies actual decoded duration, frame pixels and audio after trim.
 const rendered=path.join(directory,'rendered.mp4');fs.writeFileSync(rendered,Buffer.concat([fs.readFileSync(source),Buffer.from([0,0,0,8,102,114,101,101])]));
 await store.commitRecordingTrim({id:item.id,sourceFingerprint:hash,...imported(rendered),durationMs:2000});
 assert.equal(store.mediaPath(item.id,true),original);assert.notEqual(store.mediaPath(item.id),original);assert.equal(store.item(item.id).durationMs,2000);assert.equal(store.item(item.id).name,'Kept name');assert.equal(fs.readFileSync(original).equals(fs.readFileSync(source)),true);
 const trimmed=store.publicState().items[0];assert.notEqual(trimmed.videoUrl,originalURL);assert.equal(trimmed.videoUrl,'appmedia://media/'+item.id+'/video?v='+trimmed.sourceFingerprint);assert.equal(new Store(directory).publicState().items[0].videoUrl,trimmed.videoUrl);
 await assert.rejects(store.commitRecordingTrim({id:item.id,sourceFingerprint:hash,...imported(rendered)}),/changed/);
 const active=fingerprint(store,item.id);store.modify('trash',{ids:[item.id]});await assert.rejects(store.commitRecordingTrim({id:item.id,sourceFingerprint:active,...imported(source)}),/changed/);
}));
test('failed trim commit preserves the previous record and both referenced media versions',()=>fixture(async(store,directory)=>{
 const item=await store.insertRecording(imported(source)),before=structuredClone(store.item(item.id)),hash=fingerprint(store,item.id),persist=store.persist;
 store.persist=()=>{throw new Error('Synthetic recording commit failure');};await assert.rejects(store.commitRecordingTrim({id:item.id,sourceFingerprint:hash,...imported(source),durationMs:2000}),/Synthetic/);store.persist=persist;
 assert.deepEqual(store.item(item.id),before);assert.equal(new Store(directory).item(item.id).durationMs,6000);assert.equal(fs.readFileSync(store.mediaPath(item.id,true)).equals(fs.readFileSync(source)),true);
}));
test('canceling after recording assets finish prevents the trim transaction from committing',()=>fixture(async(store,directory)=>{
 const item=await store.insertRecording(imported(source)),before=structuredClone(store.item(item.id)),hash=fingerprint(store,item.id),controller=new AbortController(),assets=store.recordingAssets.bind(store);
 store.recordingAssets=async value=>{const result=await assets(value);controller.abort();return result;};
 await assert.rejects(store.commitRecordingTrim({id:item.id,sourceFingerprint:hash,...imported(source),durationMs:2000,signal:controller.signal}),/canceled/);
 assert.deepEqual(store.item(item.id),before);assert.equal(new Store(directory).item(item.id).durationMs,6000);assert.ok(!fs.readdirSync(store.mediaDirectory).some(name=>name.startsWith('.video-')));
}));
test('permanent deletion removes original/rendered recordings and posters after references and backup are cleared',()=>fixture(async(store,directory)=>{
 const item=await store.insertRecording(imported(source)),files=[store.mediaPath(item.id),store.posterPath(item.id)];store.modify('trash',{ids:[item.id]});assert.ok(files.every(file=>fs.existsSync(file)));store.modify('delete',{ids:[item.id]});assert.ok(files.every(file=>!fs.existsSync(file)));assert.equal(new Store(directory).data.items.length,0);assert.ok(!fs.readFileSync(store.file+'.backup','utf8').includes(item.id));
}));
test('recording validation rejects unsafe metadata, paths, edits and cancellation',()=>fixture(async(store,directory)=>{
 assert.throws(()=>metadata({durationMs:Infinity,width:160,height:120}),/metadata/);assert.throws(()=>metadata({durationMs:100,width:100000,height:100000}),/metadata/);
 const item=await store.insertRecording(imported(source));assert.throws(()=>store.modify('saveImage',{id:item.id,dataUrl:'data:image/png;base64,'+poster.toString('base64')}),/Invalid image edit/);
 await assert.rejects(store.putVideo('../not-allowed.mp4'),/Invalid/);const controller=new AbortController();controller.abort();await assert.rejects(store.putVideo(source,{signal:controller.signal}),/canceled/);assert.ok(!fs.readdirSync(store.mediaDirectory).some(name=>name.startsWith('.video-')));
 const tampered=JSON.parse(fs.readFileSync(store.file));tampered.items[0].videoFile='../../private.mp4';fs.writeFileSync(store.file,JSON.stringify(tampered));assert.throws(()=>new Store(directory),/Unsafe recording path/);
}));
test('owned media-job cleanup never removes unknown or foreign files',()=>fixture(async(_store,directory)=>{
 const jobs=new MediaJobs({directory:path.join(directory,'jobs')}),foreign=path.join(jobs.directory,'job-ABC123');fs.mkdirSync(foreign);fs.writeFileSync(path.join(foreign,'.clipboardline-media.json'),JSON.stringify({owner:'foreign'}));fs.writeFileSync(path.join(foreign,'private.txt'),'Synthetic keep');assert.equal(jobs.release({jobDirectory:foreign}),false);assert.ok(fs.existsSync(path.join(foreign,'private.txt')));jobs.dispose();assert.ok(fs.existsSync(path.join(foreign,'private.txt')));
}));
