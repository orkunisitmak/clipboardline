'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const {execFileSync}=require('node:child_process');
const {windowsEnvironment}=require('./windows-environment.cjs');
const {textIdentity}=require('./text-identity.cjs');
const {metadata:recordingMetadata,MAXIMUM_VIDEO_BYTES}=require('./media.cjs');
const MANAGED_MEDIA=/^[a-f0-9]{64}\.(png|mp4|mov)$/;

const KINDS = ['image', 'text', 'link'];
const DEFAULTS = Object.freeze({
  visibleKinds: KINDS, captureText: false, captureImages: false, captureLinks: true,fetchLinkMetadata:true,
  retentionDays: {image: 30, text: 30, link: 30},
  shortcuts: {toggle: 'Control+Alt+T', search: 'Control+Alt+S', library:'', copyLatest:'', uploadLatest:'', screenshot: 'Control+Alt+A'},
  localShortcuts: {},
  r2AccountId: '', r2AccessKeyId: '', r2Bucket: '', r2PublicBaseUrl: '', r2KeyPrefix: '',
  autoCheckUpdates: true, watchFolders: [], openAfterScreenshot: true,
  theme:'soft', cardSize:'medium', sounds:false, launchAtLogin:false, language:'system',indexImages:true,
  libraryListMode:false,libraryInspectorVisible:true,librarySidebarVisible:true,librarySidebarWidth:220,libraryInspectorWidth:300,
  libraryListColumns:{title:300,kind:80,tags:150,created:130},recentPinFolderIds:[]
});
const clone = value => structuredClone(value);
const fail = message => { throw new Error(message); };
function incompleteDeletion(message){const error=new Error('Permanent deletion is incomplete. '+message+' Retry cleanup in Settings.');error.committed=true;return error;}
function text(value, maximum = 1024 * 1024, empty = false) {
  if (typeof value !== 'string' || value.length > maximum || (!empty && !value.length) || value.includes('\0')) fail('Invalid text');
  return value;
}
function ids(value) {
  if (!Array.isArray(value) || value.length > 10000 || value.some(id => typeof id !== 'string' || !/^[0-9a-f-]{36}$/.test(id))) fail('Invalid item selection');
  return [...new Set(value)];
}
function settings(patch, previous = DEFAULTS) {
  if (!patch || typeof patch !== 'object' || Array.isArray(patch)) fail('Invalid settings');
  const out = clone(previous);
  for (const [key, value] of Object.entries(patch)) {
    if (['captureText', 'captureImages', 'captureLinks', 'fetchLinkMetadata','autoCheckUpdates', 'openAfterScreenshot','sounds','launchAtLogin','indexImages','libraryListMode','libraryInspectorVisible','librarySidebarVisible'].includes(key)) {
      if (typeof value !== 'boolean') fail('Invalid preference');
      out[key] = value;
    } else if (key === 'visibleKinds') {
      if (!Array.isArray(value) || value.some(k => !KINDS.includes(k))) fail('Invalid visible shelves');
      out[key] = [...new Set(value)];
    } else if (key === 'retentionDays') {
      for (const [kind, days] of Object.entries(value || {})) {
        if (!KINDS.includes(kind) || !Number.isInteger(days) || days < 0 || days > 3650) fail('Invalid history duration');
        out.retentionDays[kind] = days;
      }
    } else if (key === 'shortcuts') {
      for (const [action, shortcut] of Object.entries(value || {})) {
        if (!['toggle', 'search', 'library', 'copyLatest', 'uploadLatest', 'screenshot'].includes(action) || typeof shortcut !== 'string' || shortcut.length > 80 || /[\r\n\0]/.test(shortcut)) fail('Invalid shortcut');
        out.shortcuts[action] = shortcut;
      }
    } else if (['r2AccountId', 'r2AccessKeyId', 'r2Bucket', 'r2PublicBaseUrl', 'r2KeyPrefix'].includes(key)) {
      if (typeof value !== 'string' || value.length > 512 || /[\r\n\0]/.test(value)) fail('Invalid R2 preference');
      out[key] = value.trim();
    } else if (key === 'localShortcuts') {
      for (const [action, shortcut] of Object.entries(value || {})) {
        if (!/^[a-zA-Z][a-zA-Z0-9_-]{0,60}$/.test(action) || ['constructor','prototype','__proto__'].includes(action)) fail('Invalid local shortcut');
        if(shortcut===null){delete out.localShortcuts[action];continue;}
        if(typeof shortcut !== 'string' || shortcut.length > 80 || /[\r\n\0]/.test(shortcut)) fail('Invalid local shortcut');
        out.localShortcuts[action] = shortcut;
      }
    } else if(key==='recentPinFolderIds') {
      if(!Array.isArray(value)||value.length>8)fail('Invalid recent folders');out.recentPinFolderIds=ids(value);
    } else if(key==='libraryListColumns') {
      if(!value||typeof value!=='object'||Array.isArray(value))fail('Invalid library columns');
      for(const [column,width] of Object.entries(value)){
        const limits=new Map([['title',[180,1200]],['kind',[70,400]],['tags',[80,800]],['created',[100,500]]]).get(column);
        if(!limits||!Number.isInteger(width)||width<limits[0]||width>limits[1])fail('Invalid library column width');out.libraryListColumns[column]=width;
      }
    } else if(['librarySidebarWidth','libraryInspectorWidth'].includes(key)) {
      const [low,high]=key==='librarySidebarWidth'?[180,320]:[270,400];
      if(!Number.isInteger(value)||value<low||value>high)fail('Invalid library panel width');out[key]=value;
    } else if (['theme','cardSize','language'].includes(key)) {
      const values={theme:['soft','neutral'],cardSize:['small','medium','large'],language:['system','en','tr','es','fr','pt-BR','az','zh-Hans','ja','ko']};
      if(!values[key].includes(value))fail('Invalid appearance preference');out[key]=value;
    } else if (key === 'watchFolders') {
      if (!Array.isArray(value) || value.length > 20 || value.some(v => typeof v !== 'string' || !path.isAbsolute(v) || v.length > 4096)) fail('Invalid watched folder');
      out.watchFolders = [...new Set(value)];
    } else fail('Unknown preference');
  }
  return out;
}
function trashUndoFingerprint(item){return crypto.createHash('sha256').update(JSON.stringify(item)).digest('hex');}
function trashUndoMatches(item,entry){return !!item&&item.trashedAt!=null&&item.trashedAt===entry.afterTrashedAt&&item.updatedAt===entry.afterUpdatedAt&&(item.captureRevision??null)===entry.captureRevision&&trashUndoFingerprint(item)===entry.fingerprint;}
function availableTrashUndo(items,journal){if(!journal?.length)return false;const byID=new Map(items.map(item=>[item.id,item]));for(let index=journal.length-1;index>=0;index--)if(journal[index].some(entry=>trashUndoMatches(byID.get(entry.id),entry)))return true;return false;}
function saved(item) { return item.retainedAt != null || item.pinned || item.folderIds.length > 0 || item.tags.length > 0; }
function plainURL(value) {
  if (typeof value !== 'string' || /\s/.test(value) || value.length > 8192) return null;
  try { const u = new URL(value); return ['http:', 'https:'].includes(u.protocol) && !u.username && !u.password ? u.href : null; } catch { return null; }
}

class Store {
  constructor(directory, {clock = Date.now} = {}) {
    this.directory = path.resolve(directory); this.clock = clock; this.undoStack = []; this.trashUndoStack = []; this.textIdentities = new WeakMap();this.revision=0;
    fs.mkdirSync(this.directory, {recursive: true, mode: 0o700});
    if(fs.lstatSync(this.directory).isSymbolicLink())fail('Application data must not be a symlink.');
    if(process.platform==='win32'){
      const script=__dirname.includes('app.asar')?path.join(process.resourcesPath,'native','protect-directory.ps1'):path.join(__dirname,'..','native','protect-directory.ps1');
      const powershell=path.join(process.env.SystemRoot,'System32','WindowsPowerShell','v1.0','powershell.exe');
      try{execFileSync(powershell,['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',script,'-Directory',this.directory],{windowsHide:true,timeout:15000,stdio:['ignore','pipe','pipe'],env:windowsEnvironment()});}
      catch(error){const detail=String(error.stderr||error.message||'').replaceAll(this.directory,'[application data]').replace(/[\r\n]+/g,' ').slice(0,900);fail('The private application data permissions could not be secured. Existing files were preserved. '+detail);}
    }
    this.mediaDirectory = path.join(this.directory, 'media'); fs.mkdirSync(this.mediaDirectory, {recursive: true, mode: 0o700});
    if(fs.lstatSync(this.mediaDirectory).isSymbolicLink())fail('Managed media must not be a symlink.');
    this.file = path.join(this.directory, 'library.json');
    this.data = {schema: 1, items: [], folders: [], settings: clone(DEFAULTS)};
    if (fs.existsSync(this.file)) {
      if(fs.lstatSync(this.file).isSymbolicLink())fail('Library must not be a symlink.');
      if (fs.statSync(this.file).size > 64 * 1024 * 1024) fail('Library exceeds safe load size');
      let parsed;
      try { parsed = JSON.parse(fs.readFileSync(this.file, 'utf8')); } catch { fail('Library is unreadable. Original data was preserved; recover library.json.backup.'); }
      if (parsed.schema !== 1 || !Array.isArray(parsed.items) || parsed.items.length > 20000 || !Array.isArray(parsed.folders)) fail('Unsupported library format');
      this.data = {...parsed, settings: settings(parsed.settings)};
      for (const item of this.data.items) this.validateStored(item);
      if(this.data.pendingDeletionFiles&&(!Array.isArray(this.data.pendingDeletionFiles)||this.data.pendingDeletionFiles.length>200000||this.data.pendingDeletionFiles.some(name=>typeof name!=='string'||!MANAGED_MEDIA.test(name))))fail('Invalid pending deletion state.');
    }
    this.pruneRecentFolders();
    this.privacyWarning='';
    if(this.data.pendingBackupRefresh||this.data.pendingDeletionFiles?.length)try{this.finishPermanentDeletion();}catch(error){this.privacyWarning=error.message;}
    this.expire();
  }
  pruneRecentFolders(){const known=new Set(this.data.folders.map(folder=>folder.id));this.data.settings.recentPinFolderIds=(this.data.settings.recentPinFolderIds||[]).filter(id=>known.has(id));}
  validateStored(item) {
    if(item.captureRevision!=null)ids([item.captureRevision]);if(item.trashRevision!=null)ids([item.trashRevision]);
    ids([item.id]); if (!KINDS.includes(item.kind) || !Array.isArray(item.folderIds) || !Array.isArray(item.tags)) fail('Invalid library record');
    if (item.text != null) text(item.text, 1024 * 1024, true);
    if(item.note!=null)text(item.note,1024*1024,true);
    if(item.retainedAt!=null&&(!Number.isFinite(item.retainedAt)||item.retainedAt<0))fail('Invalid saved timestamp');
    if(item.lastCopiedAt!=null&&(!Number.isFinite(item.lastCopiedAt)||item.lastCopiedAt<0))fail('Invalid copy timestamp');
    if(item.uploadedUrl!=null&&(typeof item.uploadedUrl!=='string'||item.uploadedUrl.length>2048||!plainURL(item.uploadedUrl)?.startsWith('https://')))fail('Invalid uploaded URL');
    if(item.uploadedAt!=null&&(!Number.isFinite(item.uploadedAt)||item.uploadedAt<0))fail('Invalid upload timestamp');
    if(item.retainedAt==null&&(item.pinned||item.folderIds.length||item.tags.length))item.retainedAt=item.updatedAt||item.createdAt||this.clock();
    for (const key of ['imageFile', 'renderedFile','thumbnailFile']) if (item[key] && !/^[a-f0-9]{64}\.png$/.test(item[key])) fail('Unsafe managed media path');
    if(item.recording!==undefined&&typeof item.recording!=='boolean')fail('Invalid recording record');
    if(item.recording){if(item.kind!=='image'||!item.videoFile||!item.imageFile)fail('Invalid recording record');recordingMetadata(item);}
    for(const key of ['videoFile','renderedVideoFile'])if(item[key]&&(!item.recording||!/^[a-f0-9]{64}\.(mov|mp4)$/.test(item[key])))fail('Unsafe recording path');
  }
  persist() {
    for(const destination of [this.file,this.file+'.backup'])if(fs.existsSync(destination)&&fs.lstatSync(destination).isSymbolicLink())fail('Library files must not be symlinks.');
    const temporary = this.file + '.tmp-' + crypto.randomUUID();
    let descriptor;
    try {
      descriptor = fs.openSync(temporary, 'wx', 0o600); fs.writeFileSync(descriptor, JSON.stringify(this.data)); fs.fsyncSync(descriptor); fs.closeSync(descriptor); descriptor = null;
      if (fs.existsSync(this.file)) fs.copyFileSync(this.file, this.file + '.backup');
      fs.renameSync(temporary, this.file);this.revision++;
    } finally { if (descriptor != null) fs.closeSync(descriptor); if (fs.existsSync(temporary)) fs.unlinkSync(temporary); }
  }
  mediaReferences(){return new Set(this.data.items.flatMap(item=>[item.imageFile,item.renderedFile,item.thumbnailFile,item.videoFile,item.renderedVideoFile]).filter(Boolean));}
  preparePermanentDeletion(){
    if(fs.lstatSync(this.mediaDirectory).isSymbolicLink())fail('Managed media must not be a symlink.');
    const referenced=this.mediaReferences(),files=fs.readdirSync(this.mediaDirectory).filter(name=>MANAGED_MEDIA.test(name)&&!referenced.has(name));
    this.data.pendingDeletionFiles=[...new Set([...(this.data.pendingDeletionFiles||[]),...files])];
    this.data.pendingBackupRefresh=true;
  }
  refreshPrivateBackup(){
    const destination=this.file+'.backup',temporary=destination+'.tmp-'+crypto.randomUUID();let descriptor;
    if(fs.existsSync(destination)&&fs.lstatSync(destination).isSymbolicLink())fail('Library backup must not be a symlink.');
    try{descriptor=fs.openSync(temporary,'wx',0o600);fs.writeFileSync(descriptor,JSON.stringify(this.data));fs.fsyncSync(descriptor);fs.closeSync(descriptor);descriptor=null;fs.renameSync(temporary,destination);}
    finally{if(descriptor!=null)fs.closeSync(descriptor);if(fs.existsSync(temporary))fs.unlinkSync(temporary);}
  }
  finishPermanentDeletion(){
    const pending=[...(this.data.pendingDeletionFiles||[])];
    if(!pending.length&&!this.data.pendingBackupRefresh)return;
    try{
      // This method runs only after the deletion request itself was persisted.
      // Replace the rollback JSON before touching any image, so deleted text and
      // records cannot survive in that older snapshot or be resurrected from it.
      this.refreshPrivateBackup();
      if(fs.lstatSync(this.mediaDirectory).isSymbolicLink())throw new Error('Managed media directory changed.');
      const referenced=this.mediaReferences();
      for(const name of pending){if(!MANAGED_MEDIA.test(name))throw new Error('Invalid managed filename.');if(referenced.has(name))continue;try{fs.unlinkSync(path.join(this.mediaDirectory,name));}catch(error){if(error.code!=='ENOENT')throw error;}}
      this.data.pendingDeletionFiles=[];this.data.pendingBackupRefresh=false;
      try{this.persist();}catch(error){this.data.pendingDeletionFiles=pending;this.data.pendingBackupRefresh=true;throw error;}
      this.privacyWarning='';
    }catch(error){const problem=incompleteDeletion('The local backup or unused managed images could not be removed.');this.privacyWarning=problem.message;throw problem;}
  }
  selected(value) { const selected = ids(value); const result = selected.map(id => this.data.items.find(i => i.id === id)); if (result.some(i => !i)) fail('An item no longer exists'); return result; }
  item(id) { return this.selected([id])[0]; }
  unsavedHistorySnapshot(kind='all') {
    if(kind!=='all'&&!KINDS.includes(kind))fail('Invalid history type');
    const items=this.data.items.filter(item=>!item.trashedAt&&!saved(item)&&(kind==='all'||item.kind===kind));
    return {kind,ids:items.map(item=>item.id).sort(),captures:Object.fromEntries(items.map(item=>[item.id,{revision:item.captureRevision??null,createdAt:item.createdAt,updatedAt:item.updatedAt,lastCopiedAt:item.lastCopiedAt??null}]))};
  }
  invalidateTrashUndo(value){const affected=new Set(value);this.trashUndoStack=this.trashUndoStack.map(batch=>batch.filter(entry=>!affected.has(entry.id))).filter(batch=>batch.length);}
  markCopied(value){this.modify('markCopied',{ids:value});}
  putPNG(buffer) {
    if (!Buffer.isBuffer(buffer) || buffer.length < 24 || buffer.length > 64 * 1024 * 1024 || buffer.subarray(0, 8).toString('hex') !== '89504e470d0a1a0a') fail('Invalid PNG image');
    const width = buffer.readUInt32BE(16), height = buffer.readUInt32BE(20);
    if (!width || !height || width * height > 80_000_000) fail('Image is too large');
    const filename = crypto.createHash('sha256').update(buffer).digest('hex') + '.png';
    const destination = path.join(this.mediaDirectory, filename);
    if (!fs.existsSync(destination)) fs.writeFileSync(destination, buffer, {flag: 'wx', mode: 0o600});
    return filename;
  }
  mediaPath(id, original = false) {
    const item = this.item(id); const filename = item.recording?(original?item.videoFile:(item.renderedVideoFile||item.videoFile)):(original ? item.imageFile : (item.renderedFile || item.imageFile));
    if (item.kind !== 'image' || !filename || !(item.recording?/^[a-f0-9]{64}\.(mp4|mov)$/:/^[a-f0-9]{64}\.png$/).test(filename)) fail('Media unavailable');
    const result = path.join(this.mediaDirectory, filename);
    if (!fs.existsSync(result) || fs.lstatSync(result).isSymbolicLink()) fail('Image unavailable');
    return result;
  }
  posterPath(id,original=false){
    const item=this.item(id),filename=original?item.imageFile:(item.renderedFile||item.imageFile);
    if(item.kind!=='image'||!filename||!/^[a-f0-9]{64}\.png$/.test(filename))fail('Image poster unavailable');
    const file=path.join(this.mediaDirectory,filename);if(!fs.existsSync(file)||!fs.lstatSync(file).isFile()||fs.lstatSync(file).isSymbolicLink())fail('Image poster unavailable');return file;
  }
  async putVideo(source,{signal}={}){
    if(typeof source!=='string'||!path.isAbsolute(source)||!['.mp4','.mov'].includes(path.extname(source).toLowerCase()))fail('Invalid recording file');
    if(fs.lstatSync(this.mediaDirectory).isSymbolicLink())fail('Unsafe managed media directory');
    const before=await fs.promises.lstat(source);if(!before.isFile()||before.isSymbolicLink()||before.size<12||before.size>MAXIMUM_VIDEO_BYTES)fail('Recording exceeds the 2 GB limit or is unavailable');
    const temporary=path.join(this.mediaDirectory,'.video-'+crypto.randomUUID());let input,output;
    try{
      input=await fs.promises.open(source,fs.constants.O_RDONLY|(fs.constants.O_NOFOLLOW||0));const opened=await input.stat();if(opened.ino!==before.ino||opened.size!==before.size||opened.mtimeMs!==before.mtimeMs)fail('Recording changed while importing');
      output=await fs.promises.open(temporary,'wx',0o600);const hash=crypto.createHash('sha256'),buffer=Buffer.allocUnsafe(1024*1024);let total=0;
      for(;;){if(signal?.aborted)fail('Video operation canceled');const {bytesRead}=await input.read(buffer,0,buffer.length,null);if(!bytesRead)break;total+=bytesRead;if(total>MAXIMUM_VIDEO_BYTES)fail('Recording exceeds the 2 GB limit');const bytes=buffer.subarray(0,bytesRead);hash.update(bytes);let written=0;while(written<bytesRead){const result=await output.write(bytes,written,bytesRead-written,null);if(!result.bytesWritten)fail('Recording could not be saved');written+=result.bytesWritten;}}
      const after=await input.stat(),pathAfter=await fs.promises.lstat(source);if(total!==before.size||after.size!==before.size||after.mtimeMs!==before.mtimeMs||pathAfter.isSymbolicLink()||pathAfter.ino!==before.ino||pathAfter.mtimeMs!==before.mtimeMs)fail('Recording changed while importing');
      await output.sync();await output.close();output=null;if(signal?.aborted)fail('Video operation canceled');const filename=hash.digest('hex')+path.extname(source).toLowerCase(),destination=path.join(this.mediaDirectory,filename);
      try{await fs.promises.link(temporary,destination);}catch(error){if(error.code!=='EEXIST')throw error;const existing=await fs.promises.lstat(destination);if(!existing.isFile()||existing.isSymbolicLink()||existing.size!==total)fail('Managed recording is unsafe');}
      if(signal?.aborted)fail('Video operation canceled');return filename;
    }finally{await input?.close();await output?.close();try{await fs.promises.unlink(temporary);}catch(error){if(error.code!=='ENOENT')throw error;}}
  }
  async recordingAssets(value){
    const details=recordingMetadata(value),videoFile=await this.putVideo(value.file,{signal:value.signal});
    let poster=value.posterPNG;
    if(!poster){if(typeof value.posterFile!=='string'||!path.isAbsolute(value.posterFile))fail('Recording poster unavailable');const stat=await fs.promises.lstat(value.posterFile);if(!stat.isFile()||stat.isSymbolicLink()||stat.size>4*1024*1024)fail('Recording poster unavailable');poster=await fs.promises.readFile(value.posterFile);}
    if(!Buffer.isBuffer(poster)||poster.length>4*1024*1024)fail('Invalid recording poster');
    if(value.signal?.aborted)fail('Video operation canceled');return{details,videoFile,posterFile:this.putPNG(poster)};
  }
  async insertRecording(value){
    const assets=await this.recordingAssets(value),matching=this.data.items.filter(item=>item.recording&&!item.trashedAt&&item.videoFile===assets.videoFile),prior=matching.sort((a,b)=>b.createdAt-a.createdAt)[0];
    if(value.signal?.aborted)fail('Video operation canceled');
    if(!prior&&this.data.items.length>=20000)fail('Library item limit reached');const before=clone(this.data),now=this.clock();
    try{
      const item=prior||{id:crypto.randomUUID(),kind:'image',recording:true,text:'',url:'',title:'',name:'',pinned:false,folderIds:[],tags:[],note:'',retainedAt:null,lastCopiedAt:null,createdAt:now,updatedAt:now,trashedAt:null,hiddenFromShelf:false,annotations:[],crop:null,ocrText:'',imageFile:assets.posterFile,renderedFile:'',videoFile:assets.videoFile,renderedVideoFile:'',...assets.details};
      item.createdAt=now;item.updatedAt=now;item.hiddenFromShelf=false;item.captureRevision=crypto.randomUUID();
      this.data.items=[item,...this.data.items.filter(entry=>entry.id!==item.id)];this.expire(false);this.persist();return item;
    }catch(error){this.data=before;throw error;}
  }
  async commitRecordingTrim(value){
    const expected=this.item(value.id);if(!expected.recording||expected.trashedAt||typeof value.sourceFingerprint!=='string'||(expected.renderedVideoFile||expected.videoFile).slice(0,64)!==value.sourceFingerprint)fail('The recording changed before trimming');
    const assets=await this.recordingAssets(value),item=this.item(value.id);if(!item.recording||item.trashedAt||(item.renderedVideoFile||item.videoFile).slice(0,64)!==value.sourceFingerprint)fail('The recording changed while trimming');
    if(value.signal?.aborted)fail('Video operation canceled');
    const before=clone(this.data);try{delete item.uploadedUrl;delete item.uploadedAt;Object.assign(item,assets.details,{renderedVideoFile:assets.videoFile,renderedFile:assets.posterFile,updatedAt:this.clock()});this.persist();return item;}catch(error){this.data=before;throw error;}
  }
  insert(kind, value, extra = {}) {
    if (!KINDS.includes(kind)) fail('Invalid content kind');
    let textValue = '', url = '', imageFile = '';
    if (kind === 'image') imageFile = this.putPNG(value);
    else if (kind === 'link') { url = plainURL(value) || fail('Invalid URL'); }
    else textValue = text(value);
    const identity=kind==='text'?textIdentity(textValue):null;
    const matching = this.data.items.filter(i => i.kind === kind && !i.trashedAt &&
      (kind === 'text' ? this.textIdentity(i) === identity : kind === 'link' ? i.url === url : !i.recording&&i.imageFile === imageFile));
    const prior = matching.sort((a, b) => b.updatedAt - a.updatedAt)[0];
    if(!prior&&this.data.items.length>=20000)fail('Library item limit reached');
    const now = this.clock();
    const item = prior || {id: crypto.randomUUID(), kind, text: textValue, url, title: '', name: '', pinned: false, folderIds: [], tags: [],
      imageFile, renderedFile: '', ocrText: '', annotations: [], crop: null, note:'', retainedAt:null, lastCopiedAt:null, createdAt: now, updatedAt: now, trashedAt: null, hiddenFromShelf: false};
    item.createdAt = now; item.updatedAt = now; item.hiddenFromShelf = false;item.captureRevision=crypto.randomUUID();
    if(kind==='text')item.text=textValue;
    if (extra.title) item.title = text(extra.title, 500, true);
    if (matching.length > 1) {
      item.pinned ||= matching.some(i => i.pinned);
      item.folderIds = [...new Set(matching.flatMap(i => i.folderIds))]; item.tags = [...new Set(matching.flatMap(i => i.tags))];
      item.name ||= matching.find(i => i.name)?.name || '';
      item.note ||= matching.find(i => i.note)?.note || '';
      if(!item.uploadedUrl){const uploaded=matching.find(i=>i.uploadedUrl);if(uploaded){item.uploadedUrl=uploaded.uploadedUrl;item.uploadedAt=uploaded.uploadedAt??now;}}
      const dates=matching.map(i=>i.retainedAt).filter(Number.isFinite);if(dates.length)item.retainedAt=Math.min(...dates);
    }
    this.data.items = [item, ...this.data.items.filter(i => i.id !== item.id && !matching.includes(i))];
    this.expire(false); this.persist(); return item;
  }
  textIdentity(item) {
    if(typeof item.text!=='string')return null;
    let cached=this.textIdentities.get(item);
    if(!cached||cached.text!==item.text){cached={text:item.text,key:textIdentity(item.text)};this.textIdentities.set(item,cached);}
    return cached.key;
  }
  expire(persist = true) {
    let changed = false;
    for (const item of this.data.items) {
      const days = this.data.settings.retentionDays[item.kind];
      if (!item.trashedAt && !saved(item) && days > 0 && item.createdAt < this.clock() - days * 86400000) { item.trashedAt = this.clock(); item.trashRevision=crypto.randomUUID(); changed = true; }
    }
    if (persist && changed) this.persist();
  }
  modify(action, payload = {}) {
    const before=clone(this.data), undo=clone(this.undoStack), trashUndo=clone(this.trashUndoStack);
    try{return this.modifyTransaction(action,payload);}catch(error){if(!error.committed){this.data=before;this.undoStack=undo;this.trashUndoStack=trashUndo;}throw error;}
  }
  modifyTransaction(action, payload = {}) {
    const now = this.clock();
    if(action==='trash'||action==='trashUndoably'){
      const selected=ids(payload.ids||(payload.id?[payload.id]:[])),byID=new Map(this.data.items.map(item=>[item.id,item]));
      const items=selected.map(id=>byID.get(id)).filter(item=>item&&item.trashedAt==null);
      if(!items.length)return{ids:[]};
      const entries=items.map(item=>({id:item.id,beforeHiddenFromShelf:item.hiddenFromShelf,beforeTrashedAt:item.trashedAt}));
      for(const item of items){item.trashedAt=now;item.trashRevision=crypto.randomUUID();item.hiddenFromShelf=true;item.updatedAt=now;}
      const batch=entries.map(entry=>{const item=byID.get(entry.id);return{...entry,afterTrashedAt:item.trashedAt,afterUpdatedAt:item.updatedAt,captureRevision:item.captureRevision??null,fingerprint:trashUndoFingerprint(item)};});
      // Publish the ephemeral journal only after the all-or-nothing durable save.
      this.persist();const affected=new Set(items.map(item=>item.id));
      this.undoStack=this.undoStack.map(batch=>batch.filter(entry=>!affected.has(entry.id))).filter(batch=>batch.length);
      this.trashUndoStack=this.trashUndoStack.map(batch=>batch.filter(entry=>!affected.has(entry.id))).filter(batch=>batch.length);
      this.trashUndoStack.push(batch);if(this.trashUndoStack.length>80)this.trashUndoStack.shift();
      return{ids:items.map(item=>item.id)};
    }
    if(action==='undoTrash'){
      const byID=new Map(this.data.items.map(item=>[item.id,item]));let index=this.trashUndoStack.length-1,entries=[];
      for(;index>=0;index--){entries=this.trashUndoStack[index].filter(entry=>trashUndoMatches(byID.get(entry.id),entry));if(entries.length)break;}
      if(index<0){this.trashUndoStack=[];return{ids:[]};}
      for(const entry of entries){const item=byID.get(entry.id);item.trashedAt=entry.beforeTrashedAt;item.trashRevision=null;item.hiddenFromShelf=entry.beforeHiddenFromShelf;item.updatedAt=now;}
      this.persist();this.trashUndoStack=this.trashUndoStack.slice(0,index);return{ids:entries.map(entry=>entry.id)};
    }
    if(action==='clearUnsavedHistory') {
      // A confirmation is a bounded identity snapshot, never a command to
      // include newly copied records or items saved while the dialog is open.
      if(!Array.isArray(payload.ids)||payload.ids.length>20000)fail('Invalid history snapshot');
      const captured=new Set();
      for(let offset=0;offset<payload.ids.length;offset+=10000)for(const id of ids(payload.ids.slice(offset,offset+10000)))captured.add(id);
      if(!payload.captures||typeof payload.captures!=='object'||Array.isArray(payload.captures))fail('Invalid history capture versions');
      const current=this.unsavedHistorySnapshot(payload.kind);
      const eligible=new Set(current.ids);
      const affected=this.data.items.filter(item=>{const a=payload.captures[item.id],b=current.captures[item.id];return captured.has(item.id)&&eligible.has(item.id)&&a&&b&&a.revision===b.revision&&a.createdAt===b.createdAt&&a.updatedAt===b.updatedAt&&a.lastCopiedAt===b.lastCopiedAt;});
      if(!affected.length)return {ids:[]};
      for(const item of affected){item.trashedAt=now;item.trashRevision=crypto.randomUUID();item.hiddenFromShelf=true;item.updatedAt=now;}
      const removed=new Set(affected.map(item=>item.id));
      this.undoStack=this.undoStack.map(batch=>batch.filter(item=>!removed.has(item.id))).filter(batch=>batch.length);
      this.persist();this.invalidateTrashUndo(removed);return {ids:[...removed]};
    }
    if(action==='cleanup'){this.finishPermanentDeletion();return;}
    if (action === 'setSettings') { this.data.settings = settings(payload.patch, this.data.settings);this.pruneRecentFolders();this.expire(false); this.persist(); return; }
    if (action === 'createFolder') {
      const name = text(payload.name, 120).trim(); if (!name) fail('Folder name is empty');
      const parentId = payload.parentId || null;
      if(parentId){const parent=this.data.folders.find(f=>f.id===parentId);if(!parent)fail('Parent folder is unavailable');if(parent.parentId!=null)fail('Only top-level folders can contain subfolders');}
      const folder = {id: crypto.randomUUID(), name, parentId}; this.data.folders.push(folder); this.persist(); return folder;
    }
    if(action==='renameFolder'||action==='removeFolder') {
      const folder=this.data.folders.find(f=>f.id===payload.id);if(!folder)fail('Folder unavailable');const originalMemberships=new Map(this.data.items.map(item=>[item.id,JSON.stringify(item.folderIds)]));
      if(action==='renameFolder'){folder.name=text(payload.name,120).trim();if(!folder.name)fail('Folder name is empty');}
      else {const removed=new Set([folder.id]);let changed=true;while(changed){changed=false;for(const child of this.data.folders)if(removed.has(child.parentId)&&!removed.has(child.id)){removed.add(child.id);changed=true;}}this.data.folders=this.data.folders.filter(f=>!removed.has(f.id));for(const item of this.data.items)if(item.folderIds.some(id=>removed.has(id))){item.retainedAt??=now;item.folderIds=item.folderIds.filter(id=>!removed.has(id));}}
      this.pruneRecentFolders();this.persist();this.invalidateTrashUndo(this.data.items.filter(item=>originalMemberships.get(item.id)!==JSON.stringify(item.folderIds)).map(item=>item.id));return;
    }
    if(action==='renameTag'||action==='deleteTag') {
      const tag=text(payload.tag,80).trim(),affected=this.data.items.filter(item=>item.tags.includes(tag));
      if(!tag||!affected.length)fail('Tag unavailable');
      let name;
      if(action==='renameTag'){
        name=text(payload.name,256).trim();
        if(!name||Array.from(name).length>64||/[\u0000-\u001f\u007f-\u009f]/u.test(name))fail('Invalid tag name');
        const folded=value=>value.normalize('NFKD').replace(/\p{M}/gu,'').toLowerCase();
        if(this.data.items.some(item=>item.tags.some(value=>value!==tag&&folded(value)===folded(name))))fail('A tag with this name already exists');
      }
      for(const item of affected){item.retainedAt??=now;item.tags=action==='renameTag'?[...new Set(item.tags.map(value=>value===tag?name:value))]:item.tags.filter(value=>value!==tag);}
      this.persist();this.invalidateTrashUndo(affected.map(item=>item.id));return;
    }
    if (action === 'undo') {
      const batch = this.undoStack.pop(); if (!batch) return;
      for (const before of batch) { const item = this.data.items.find(i => i.id === before.id); if (item) { item.trashedAt = before.trashedAt; item.trashRevision=before.trashedAt==null?null:crypto.randomUUID(); item.hiddenFromShelf = before.hiddenFromShelf; } }
      this.persist(); return;
    }
    const items = this.selected(payload.ids || (payload.id ? [payload.id] : []));
    if (!items.length) fail('Select an item first');
    if (action === 'remove') {
      this.undoStack.push(items.map(i => ({id: i.id, trashedAt: i.trashedAt, hiddenFromShelf: i.hiddenFromShelf})));
      if (this.undoStack.length > 32) this.undoStack.shift();
    }
    const targetPin = typeof payload.value === 'boolean' ? payload.value : items.some(i => !i.pinned);
    for (const item of items) {
      if (action === 'pin') {item.pinned = targetPin;if(targetPin)item.retainedAt??=now;}
      else if(action==='retain')item.retainedAt??=now;
      else if(action==='note')item.note=text(payload.note,1024*1024,true);
      else if(action==='details') {
        if(payload.name!==undefined)item.name=text(payload.name,200,true).trim();
        if(payload.note!==undefined)item.note=text(payload.note,1024*1024,true);
        if(payload.text!==undefined){if(item.kind!=='text')fail('Only text can be edited');const nextText=text(payload.text,1024*1024,true);if(nextText!==item.text){delete item.uploadedUrl;delete item.uploadedAt;}item.text=nextText;}
      }
      else if(action==='recordUpload'){const url=plainURL(payload.url);if(!url||!url.startsWith('https://')||url.length>2048)fail('Invalid uploaded URL');item.uploadedUrl=url;item.uploadedAt=now;}
      else if(action==='markCopied'){item.lastCopiedAt=now;item.captureRevision=crypto.randomUUID();}
      else if (action === 'name') { item.name = text(payload.name, 200, true).trim(); item.pinned = true; item.retainedAt??=now; }
      else if (action === 'folder') {
        if (!this.data.folders.some(f => f.id === payload.folderId)) fail('Folder unavailable');
        if(payload.pinning!==undefined&&typeof payload.pinning!=='boolean')fail('Invalid folder pin option');
        if(payload.rememberRecent!==undefined&&typeof payload.rememberRecent!=='boolean')fail('Invalid recent folder option');
        item.folderIds = [...new Set([...item.folderIds, payload.folderId])];if(payload.pinning!==false)item.pinned=true;item.retainedAt??=now;
      } else if(action==='unassign') {
        if(typeof payload.folderId!=='string'||!this.data.folders.some(f=>f.id===payload.folderId))fail('Folder unavailable');
        item.folderIds=item.folderIds.filter(id=>id!==payload.folderId);
      } else if(action==='removeTag') {
        const tag=text(payload.tag,80).trim();item.tags=item.tags.filter(value=>value!==tag);
      } else if (action === 'tag') {
        if (!Array.isArray(payload.tags) || payload.tags.length > 50) fail('Invalid tags');
        item.tags = [...new Set(payload.tags.map(tag => text(tag, 80).trim()).filter(Boolean))];
        if(item.tags.length)item.retainedAt??=now;
      } else if (action === 'remove') { if (saved(item)) item.hiddenFromShelf = true; else{item.trashedAt = now;item.trashRevision=crypto.randomUUID();} }
      else if (action === 'trash') item.trashedAt = now;
      else if (action === 'restore') { item.trashedAt = null; item.trashRevision=null; item.hiddenFromShelf = false; }
      else if (action === 'editText') { if (item.kind !== 'text') fail('Only text can be edited'); const nextText = text(payload.text, 1024 * 1024, true); if (nextText !== item.text) { delete item.uploadedUrl; delete item.uploadedAt; } item.text = nextText; }
      else if (action === 'saveImage') {
        if (item.kind !== 'image' || item.recording || typeof payload.dataUrl !== 'string' || !/^data:image\/png;base64,[A-Za-z0-9+/=]+$/.test(payload.dataUrl) || payload.dataUrl.length > 90_000_000) fail('Invalid image edit');
        const annotations = payload.annotations ?? []; const crop = payload.crop ?? null;
        if (!Array.isArray(annotations) || annotations.length > 2000 || JSON.stringify(annotations).length > 2_000_000 || (crop !== null && (typeof crop !== 'object' || ['x','y','width','height'].some(k => !Number.isFinite(crop[k])) || crop.x<0 || crop.y<0 || crop.width<=0 || crop.height<=0))) fail('Invalid image edit metadata');
        if(crop){const original=fs.readFileSync(this.mediaPath(item.id,true));if(crop.x+crop.width>original.readUInt32BE(16)||crop.y+crop.height>original.readUInt32BE(20))fail('Crop is outside the original image');}
        item.renderedFile = this.putPNG(Buffer.from(payload.dataUrl.split(',')[1], 'base64')); item.annotations = clone(annotations); item.crop = clone(crop); item.ocrText = ''; delete item.uploadedUrl; delete item.uploadedAt;
      } else if (action === 'delete') { if (!item.trashedAt) fail('Move items to Trash before permanent deletion'); }
      else fail('Unknown library action');
      if(action!=='markCopied')item.updatedAt = now;
    }
    if(action==='folder'&&payload.rememberRecent===true)this.data.settings.recentPinFolderIds=[payload.folderId,...this.data.settings.recentPinFolderIds.filter(id=>id!==payload.folderId)].slice(0,8);
    if (action === 'delete') this.data.items = this.data.items.filter(i => !items.includes(i));
    if (['delete', 'trash', 'restore'].includes(action)) this.undoStack = this.undoStack.filter(batch => !batch.some(old => items.some(i => i.id === old.id)));
    if(action==='delete')this.preparePermanentDeletion();
    this.persist();
    {const affected=new Set(items.map(item=>item.id));this.trashUndoStack=this.trashUndoStack.map(batch=>batch.filter(entry=>!affected.has(entry.id))).filter(batch=>batch.length);}
    if(action==='delete')this.finishPermanentDeletion();
  }
  publicState() {
    return {
      items: this.data.items.map(({imageFile, renderedFile, thumbnailFile, videoFile, renderedVideoFile, ...item}) => ({...clone(item),
        // Only a content hash of the displayed managed PNG; no path or disk read.
        ...((thumbnailFile||renderedFile||imageFile)?{mediaRevision:(thumbnailFile||renderedFile||imageFile).slice(0,64)}:{}),
        ...(thumbnailFile ? {thumbnailUrl: `appmedia://media/${item.id}/thumbnail?v=${thumbnailFile.slice(0,64)}`} : {}),
        ...(item.kind === 'image' ? {mediaUrl: `appmedia://media/${item.id}?v=${(renderedFile||imageFile).slice(0,64)}`, originalMediaUrl: `appmedia://media/${item.id}/original`} : {}),
        ...(item.recording?{videoUrl:`appmedia://media/${item.id}/video?v=${(renderedVideoFile||videoFile).slice(0,64)}`,originalVideoUrl:`appmedia://media/${item.id}/video/original`,sourceFingerprint:(renderedVideoFile||videoFile).slice(0,64)}:{})})),
      folders: clone(this.data.folders), settings: clone(this.data.settings), canUndo: this.undoStack.length > 0, canUndoTrash:availableTrashUndo(this.data.items,this.trashUndoStack),
      needsDeletionCleanup:!!(this.data.pendingBackupRefresh||this.data.pendingDeletionFiles?.length)
    };
  }
}
module.exports = {Store, KINDS, DEFAULTS, settings, saved, plainURL, text, ids};
