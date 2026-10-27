'use strict';
const crypto=require('node:crypto');
const {spawn}=require('node:child_process');
const {pathToFileURL}=require('node:url');
const {which,session,runTool}=require('./linux-desktop.cjs');

// Electron's Linux clipboard cannot be used directly: under Wayland it cannot
// read or write while the window is unfocused and it drops image/png offers;
// under XWayland the compositor does not synchronize a background selection.
// wl-clipboard (data-control) and xclip own the selection independently.
const MARKER_TYPE='web application/x.clipboardline';
const TEXT_TYPES=['text/plain;charset=utf-8','text/plain','UTF8_STRING','STRING','TEXT'];
const IMAGE_TYPES=['image/png','image/jpeg','image/webp','image/bmp','image/x-bmp','image/gif','image/tiff'];
const X11_META=new Set(['TARGETS','TIMESTAMP','MULTIPLE','SAVE_TARGETS','DELETE','INCR']);
// KDE's clipboard history re-offers its previous entry when the owner exits.
// That replay is not a new copy and must not resurrect a removed record.
const REPLAYED=/^application\/x-kde-onlyreplaceempty$/i;
// Copied files are ignored like a Windows FileDrop; their path text fallback
// is not a clipboard text record.
const FILE_COPY=/^(x-special\/gnome-copied-files|application\/x-kde-cutselection)$/i;
const MAXIMUM_SEQUENCE=0xffffffff;

function detectBackend({environment=process.env,find=which}={}){
 const current=session(environment);
 if(current.wayland&&find('wl-paste')&&find('wl-copy'))return 'wl-clipboard';
 if(current.display&&find('xclip'))return 'xclip';
 return 'electron';
}
function parseTypes(bytes){return [...new Set(String(bytes).split(/\r?\n/).map(value=>value.trim()).filter(value=>value&&value.length<=256&&!value.includes('\0')&&!X11_META.has(value)))].slice(0,200);}
function fileURIList(text){const lines=text.split(/\r?\n/).map(line=>line.trim()).filter(line=>line&&!line.startsWith('#'));return lines.length>0&&lines.every(line=>/^file:\/\//i.test(line));}
function uriList(files){return files.map(file=>pathToFileURL(file).href).join('\r\n')+'\r\n';}
const digest=bytes=>crypto.createHash('sha256').update(bytes).digest('hex');
function payload({text='',png=null,files=[]}){
 // wl-copy and xclip publish one MIME type per selection. Files win so batches
 // and recordings stay file transfers; one image wins over accompanying text.
 if(Array.isArray(files)&&files.length)return{type:'text/uri-list',bytes:Buffer.from(uriList(files),'utf8')};
 if(png){if(!Buffer.isBuffer(png)||png.subarray(0,8).toString('hex')!=='89504e470d0a1a0a')throw new Error('Image unavailable');return{type:'image/png',bytes:png};}
 if(typeof text==='string'&&text.length)return{type:'text/plain;charset=utf-8',bytes:Buffer.from(text,'utf8')};
 throw new Error('Select an item first');
}
class LinuxClipboard{
 constructor({backend,run=runTool,find=which,environment=process.env,electron=null,toPNG=null,pollInterval=500,spawnWatcher=spawn}={}){
  this.find=find;this.run=run;this.environment=environment;this.electron=electron;this.toPNG=toPNG;this.pollInterval=pollInterval;this.spawnWatcher=spawnWatcher;
  this.backend=backend||detectBackend({environment,find});
  this.sequenceValue=1;this.watcher=null;this.poller=null;this.listeners=new Set();this.failures=new Set();this.ownWrite=null;this.stopped=false;
 }
 configure({electron,toPNG}={}){if(electron)this.electron=electron;if(toPNG)this.toPNG=toPNG;}
 get native(){return this.backend!=='electron';}
 tool(name){const file=this.find(name);if(!file)throw new Error(name+' is not installed.');return file;}
 async rawTypes(){
  try{
   if(this.backend==='wl-clipboard')return parseTypes(await this.run(this.tool('wl-paste'),['--list-types'],{timeout:2000,maximum:65536,environment:this.environment}));
   return parseTypes(await this.run(this.tool('xclip'),['-selection','clipboard','-target','TARGETS','-out'],{timeout:2000,maximum:65536,environment:this.environment}));
  }catch{return [];}
 }
 rawData(type){
  if(this.backend==='wl-clipboard')return this.run(this.tool('wl-paste'),['--no-newline','--type',type],{timeout:4000,environment:this.environment});
  return this.run(this.tool('xclip'),['-selection','clipboard','-target',type,'-out'],{timeout:4000,environment:this.environment});
 }
 // Returns Electron-shaped entries so the shared admission policy applies the
 // same private-marker, ownership, size and text rules on every platform.
 async read(){
  if(this.backend==='electron'){if(!this.electron?.clipboard)throw new Error('Clipboard is unavailable.');return this.electron.clipboard.read();}
  const types=await this.rawTypes();if(!types.length||types.some(type=>REPLAYED.test(type)))return [];
  const cache=new Map(),data=type=>{if(!cache.has(type))cache.set(type,this.rawData(type));return cache.get(type);};
  let fileCopy=types.some(type=>FILE_COPY.test(type));
  if(!fileCopy&&types.includes('text/uri-list')){try{fileCopy=fileURIList((await data('text/uri-list')).toString('utf8'));}catch{}}
  const loaders=new Map();
  for(const type of types)if(!TEXT_TYPES.includes(type)&&!IMAGE_TYPES.includes(type)&&type!==MARKER_TYPE)loaders.set(type,()=>data(type));
  const image=IMAGE_TYPES.find(type=>types.includes(type)),text=TEXT_TYPES.find(type=>types.includes(type));
  if(image&&!fileCopy)loaders.set('image/png',image==='image/png'?()=>data(image):async()=>{if(!this.toPNG)throw new Error('Image conversion is unavailable.');return this.toPNG(await data(image));});
  if(text&&!fileCopy)loaders.set('text/plain',()=>data(text));
  const own=this.ownWrite;
  if(own&&types.includes(own.offered)){try{if(digest(await data(own.offered))===own.hash)loaders.set(MARKER_TYPE,async()=>own.marker);}catch{}}
  return [{types:[...loaders.keys()],getType:async type=>{const load=loaders.get(type);if(!load)throw new Error('Clipboard type unavailable.');return new Blob([await load()]);}}];
 }
 async write({text='',png=null,files=[],marker=null}={}){
  const value=payload({text,png,files});
  if(this.backend==='electron')return this.writeElectron(value,{marker});
  let offered=value.type;
  if(this.backend==='wl-clipboard'){
   // An explicit type stops content sniffing (HTML-like text would become
   // text/html); wl-copy still adds the text/plain and X11 text aliases.
   await this.run(this.tool('wl-copy'),['--type',value.type],{input:value.bytes,detach:true,timeout:4000,environment:this.environment});
  }else{
   offered=value.type.startsWith('text/plain')?'UTF8_STRING':value.type;
   await this.run(this.tool('xclip'),['-selection','clipboard','-target',offered,'-in'],{input:value.bytes,detach:true,timeout:4000,environment:this.environment});
  }
  // The next change notification is this write. Any later change belongs to
  // another application, even when it copies identical bytes.
  this.ownWrite=marker?{offered,hash:digest(value.bytes),marker:Buffer.from(marker),pending:true}:null;
  return{type:value.type};
 }
 async writeElectron(value,{marker}){
  const {clipboard,ClipboardItem}=this.electron||{};if(!clipboard||!ClipboardItem)throw new Error('Clipboard is unavailable.');
  const data={};if(marker)data[MARKER_TYPE]=new Blob([marker]);
  if(value.type==='text/uri-list'){
   const list=value.bytes.toString('utf8');
   data['text/plain']=new Blob([list.trim().split(/\r\n/).map(uri=>decodeURIComponent(new URL(uri).pathname)).join('\n')],{type:'text/plain'});
   data['electron application/osclipboard;format="text/uri-list"']=new Blob([list]);
   data['electron application/osclipboard;format="x-special/gnome-copied-files"']=new Blob(['copy\n'+list.trim().split(/\r\n/).join('\n')]);
  }else data[value.type.startsWith('text/plain')?'text/plain':value.type]=new Blob([value.bytes],{type:value.type.startsWith('text/plain')?'text/plain':value.type});
  await clipboard.write([new ClipboardItem(data)]);return{type:value.type};
 }
 changed(){
  this.sequenceValue=this.sequenceValue>=MAXIMUM_SEQUENCE?1:this.sequenceValue+1;
  if(this.ownWrite){if(this.ownWrite.pending)this.ownWrite.pending=false;else this.ownWrite=null;}
  for(const listener of this.listeners){try{listener(this.sequenceValue);}catch{}}
 }
 onChange(listener){this.listeners.add(listener);return()=>this.listeners.delete(listener);}
 onFailure(listener){this.failures.add(listener);return()=>this.failures.delete(listener);}
 sequence(){this.start();return this.sequenceValue;}
 start(){
  if(this.stopped||this.watcher||this.poller)return;
  if(this.backend==='wl-clipboard'){
   let child;
   // The command drains each offer so a source application never sees EPIPE.
   try{child=this.spawnWatcher(this.tool('wl-paste'),['--watch','/bin/sh','-c','cat >/dev/null; echo'],{stdio:['ignore','pipe','pipe'],env:this.environment});}catch{return this.fallback(new Error('Clipboard watcher could not start.'));}
   this.watcher=child;let stderr='';
   // A background watcher must never outlive the application.
   if(!this.exitHook){this.exitHook=()=>this.watcher?.kill();process.once('exit',this.exitHook);}
   child.stdout.on('data',chunk=>{for(const byte of chunk)if(byte===10)this.changed();});
   child.stderr.on('data',chunk=>{if(stderr.length<2000)stderr+=chunk.toString('utf8');});
   child.on('error',error=>{if(this.watcher===child){this.watcher=null;this.fallback(error);}});
   child.on('exit',()=>{if(this.watcher===child){this.watcher=null;this.fallback(new Error('Wayland clipboard watcher stopped'+(stderr?': '+stderr.trim().split('\n')[0].slice(0,200):'.')));}});
   return;
  }
  this.poll();
 }
 // Compositors without data-control (for example GNOME Shell) cannot be
 // observed in the background through wl-paste; poll Electron's XWayland view.
 fallback(error){
  if(this.stopped)return;
  if(this.backend==='wl-clipboard'&&this.electron?.clipboard){this.backend='electron';this.ownWrite=null;}
  for(const listener of this.failures){try{listener(error);}catch{}}
  this.poll();
 }
 poll(){
  if(this.stopped||this.poller)return;let last=null,busy=false;
  this.poller=setInterval(async()=>{
   if(busy)return;busy=true;
   try{const value=await this.signature();if(last!==null&&value!==last)this.changed();last=value;}catch{}finally{busy=false;}
  },this.pollInterval);this.poller.unref?.();
 }
 async signature(){
  if(this.backend==='xclip'){try{return 'timestamp:'+(await this.run(this.tool('xclip'),['-selection','clipboard','-target','TIMESTAMP','-out'],{timeout:1500,maximum:4096,environment:this.environment})).toString('hex');}catch{}}
  const entries=await this.read(),hash=crypto.createHash('sha256');
  for(const entry of entries){hash.update(entry.types.join('\n'));for(const type of ['text/plain','image/png'])if(entry.types.includes(type))hash.update(Buffer.from(await (await entry.getType(type)).arrayBuffer()));}
  return hash.digest('hex');
 }
 stop(){if(this.exitHook){process.removeListener('exit',this.exitHook);this.exitHook=null;}this.stopped=true;this.watcher?.kill();this.watcher=null;clearInterval(this.poller);this.poller=null;this.listeners.clear();this.failures.clear();}
}
let shared=null;
function linuxClipboard(options){shared??=new LinuxClipboard(options);return shared;}
module.exports={LinuxClipboard,linuxClipboard,detectBackend,parseTypes,fileURIList,uriList,payload,MARKER_TYPE};
