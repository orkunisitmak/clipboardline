'use strict';
const crypto=require('node:crypto');
const {privateClipboard}=require('./clipboard-policy.cjs');
const {spawn}=require('node:child_process');
const {pathToFileURL}=require('node:url');

const TEXT_LIMIT=1024*1024,IMAGE_LIMIT=64*1024*1024;
const TEXT_TYPES=['text/plain;charset=utf-8','UTF8_STRING','text/plain','STRING','TEXT'];
const FORMAT_MAP='application/web;type="custom/formatmap"';
const MARKER_TYPE='web application/x.clipboardline';
const URI_LIST='electron application/osclipboard;format="text/uri-list"';
const GNOME_FILES='electron application/osclipboard;format="x-special/gnome-copied-files"';

// Runs a clipboard tool and keeps at most limit+1 bytes, so the shared
// admission policy can reject oversized payloads without buffering them.
function readProcess(file,args,{limit=TEXT_LIMIT,timeout=3000,input=null,spawner=spawn}={}){
 return new Promise((resolve,reject)=>{
  let child;try{child=spawner(file,args,{stdio:[input===null?'ignore':'pipe','pipe','pipe']});}catch(error){reject(error);return;}
  const chunks=[];let size=0,stderr='',settled=false;
  const finish=(error,value)=>{if(settled)return;settled=true;clearTimeout(timer);if(error)reject(error);else resolve(value);};
  const timer=setTimeout(()=>{child.kill();finish(new Error('Clipboard helper timed out.'));},timeout);
  child.stdout.on('data',chunk=>{if(size>limit)return;const room=limit+1-size;chunks.push(chunk.length>room?chunk.subarray(0,room):chunk);size+=Math.min(chunk.length,room);if(size>limit){child.kill();finish(null,Buffer.concat(chunks));}});
  child.stderr.on('data',chunk=>{if(stderr.length<2000)stderr+=chunk.toString('utf8');});
  child.on('error',error=>finish(error));
  child.on('close',code=>{
   if(code===0)return finish(null,Buffer.concat(chunks));
   const error=new Error(stderr.trim().slice(0,300)||'Clipboard helper failed.');
   // wl-paste and xclip report an empty clipboard or a missing type as a failure;
   // xclip 0.13 (Ubuntu 24.04) says "target TARGETS not available" when no one owns it.
   error.empty=/nothing is copied|no selection|clipboard content is not available|no suitable type|there is no owner|cannot convert .* to target|target \S+ not available/i.test(stderr);finish(error);
  });
  if(input!==null){child.stdin.on('error',()=>{});child.stdin.end(input);}
 });
}
// wl-copy forks a server that keeps serving the selection. It must not inherit
// our output pipes; the foreground process exits once the offer is in place.
function copyProcess(file,args,{input,timeout=5000,spawner=spawn}={}){
 return new Promise((resolve,reject)=>{
  let child;try{child=spawner(file,args,{stdio:['pipe','ignore','ignore']});}catch(error){reject(error);return;}
  const timer=setTimeout(()=>{child.kill();reject(new Error('wl-copy timed out.'));},timeout);
  child.on('error',error=>{clearTimeout(timer);reject(error);});
  child.on('exit',code=>{clearTimeout(timer);if(code===0)resolve();else reject(new Error('wl-copy could not set the clipboard.'));});
  child.stdin.on('error',()=>{});child.stdin.end(input);
 });
}
function lines(buffer,limit=200){return[...new Set(buffer.toString('utf8').split('\n').map(value=>value.trim()).filter(value=>value&&value.length<=512))].slice(0,limit);}
function markerTarget(map,types){
 if(!map||typeof map!=='object'||Array.isArray(map))return null;
 for(const[key,value]of Object.entries(map)){
  if(!['application/x.clipboardline',MARKER_TYPE].includes(key)||typeof value!=='string'||value.length>200)continue;
  const target=value.startsWith('application/web')?value:`application/web;type="${value}"`;
  if(types.has(target))return target;
 }
 return null;
}

// Presents wl-paste data as Electron ClipboardItem-like entries. Raw MIME
// names are preserved so password-manager markers reach the shared policy.
class WaylandClipboard{
 constructor({wlPaste,run=readProcess}){this.wlPaste=wlPaste;this.run=run;}
 readType(type,limit){return this.run(this.wlPaste,['--no-newline','--type',type],{limit,timeout:limit>TEXT_LIMIT?10000:3000});}
 async types(){
  try{return lines(await this.run(this.wlPaste,['--list-types'],{limit:65536}));}
  catch(error){if(error.empty)return[];throw error;}
 }
 async read(){
  const raw=await this.types();if(!raw.length)return[];
  const available=new Set(raw),alias=new Map(),types=[...raw];
  const text=TEXT_TYPES.find(type=>available.has(type));if(text){alias.set('text/plain',text);types.push('text/plain');}
  if(available.has(FORMAT_MAP)){
   let map=null;try{map=JSON.parse((await this.readType(FORMAT_MAP,65536)).toString('utf8'));}catch{}
   const target=markerTarget(map,available);if(target){alias.set(MARKER_TYPE,target);types.push(MARKER_TYPE);}
  }
  return[{types:[...new Set(types)],getType:async type=>{
   const source=alias.get(type)||type;if(!available.has(source))throw new Error('Clipboard type is unavailable.');
   return new Blob([await this.readType(source,type==='image/png'?IMAGE_LIMIT:TEXT_LIMIT)]);
  }}];
 }
}

// xclip reads the X11 selection in its own process. A request to an owner
// that quits mid-transfer may never be answered; a helper process can be
// abandoned, while Electron's own reader would stay stuck for good.
class X11Clipboard extends WaylandClipboard{
 constructor({xclip,run=readProcess}){super({wlPaste:null,run});this.xclip=xclip;}
 readType(type,limit){return this.run(this.xclip,['-selection','clipboard','-o','-t',type],{limit,timeout:limit>TEXT_LIMIT?10000:3000});}
 async types(){
  try{return lines(await this.run(this.xclip,['-selection','clipboard','-o','-t','TARGETS'],{limit:65536}));}
  catch(error){if(error.empty)return[];throw error;}
 }
}

// One wl-paste --watch process per offered kind: wl-paste only reports offers
// that contain its requested type. Only change notifications cross the pipe;
// the clipboard payload is discarded by the notification command.
class WaylandWatchers{
 constructor({wlPaste,spawner=spawn,changed,failed}){this.wlPaste=wlPaste;this.spawner=spawner;this.changed=changed;this.failed=failed;this.children=new Map();this.closed=false;}
 update({text,images}){
  for(const[kind,wanted]of[['text',text],['image',images]]){
   if(wanted&&!this.children.has(kind))this.start(kind);
   if(!wanted&&this.children.has(kind)){const child=this.children.get(kind);this.children.delete(kind);child.kill();}
  }
 }
 start(kind){
  if(this.closed)return;
  const args=[...(kind==='image'?['--type','image/png']:[]),'--watch','echo','clipboardline-change'];
  let child;try{child=this.spawner(this.wlPaste,args,{stdio:['ignore','pipe','pipe']});}catch(error){this.failed(error);return;}
  this.children.set(kind,child);const started=Date.now();let buffer='',stderr='';
  child.stdout.on('data',chunk=>{buffer+=chunk.toString('utf8');if(buffer.length>4096)buffer=buffer.slice(-4096);let index;while((index=buffer.indexOf('\n'))>=0){const line=buffer.slice(0,index).trim();buffer=buffer.slice(index+1);if(line==='clipboardline-change')this.changed(kind);}});
  child.stderr.on('data',chunk=>{if(stderr.length<1000)stderr+=chunk.toString('utf8');});
  child.on('error',error=>{if(this.children.get(kind)===child){this.children.delete(kind);this.failed(error);}});
  child.on('exit',code=>{
   if(this.closed||this.children.get(kind)!==child)return;this.children.delete(kind);
   const error=new Error(/data-control|watch mode/i.test(stderr)?'This compositor does not offer the Wayland data-control protocol.':'The wl-paste clipboard monitor stopped'+(code?` (${code})`:'')+'.');
   error.unsupported=/data-control|watch mode/i.test(stderr)||Date.now()-started<1000;this.failed(error);
  });
 }
 kill(){this.closed=true;for(const child of this.children.values())child.kill();this.children.clear();}
}

// X11 selections are global, but Electron exposes no change counter. Owners
// publish TIMESTAMP when they acquire the selection, which identifies a copy
// without reading it; content hashes cover owners that omit it. A copy marked
// private is identified by its formats alone and its payload is never read.
// Image payloads are hashed only when images are wanted.
async function clipboardSignature(clipboard,{images=false}={}){
 const entries=await clipboard.read();if(!Array.isArray(entries))return'';
 const hash=crypto.createHash('sha256');let stamped=false;
 if(privateClipboard(entries.flatMap(entry=>entry.types))){for(const entry of entries)hash.update(JSON.stringify(entry.types));return hash.digest('hex');}
 for(const entry of entries){
  hash.update(JSON.stringify(entry.types));
  const timestamp=entry.types.find(type=>/^TIMESTAMP$|format="TIMESTAMP"/.test(type));
  // Mutter's Xwayland bridge lists TIMESTAMP for Wayland copies but cannot serve
  // it; the failure must fall through to content or no copy is ever noticed.
  if(timestamp){let bytes=null;try{bytes=Buffer.from(await(await entry.getType(timestamp)).arrayBuffer());}catch{}if(bytes?.length&&bytes.some(Boolean)){hash.update(bytes);stamped=true;}}
  if(!stamped&&entry.types.includes('text/plain')){const blob=await entry.getType('text/plain');hash.update(blob.size<=TEXT_LIMIT?Buffer.from(await blob.arrayBuffer()):Buffer.from(String(blob.size)));}
  if(images&&!stamped&&entry.types.includes('image/png')){const blob=await entry.getType('image/png');hash.update(blob.size<=IMAGE_LIMIT?Buffer.from(await blob.arrayBuffer()):Buffer.from(String(blob.size)));}
 }
 return hash.digest('hex');
}
// A selection request to an unresponsive (or absent) owner may never settle;
// each poll has a deadline so one stalled read cannot stop later polls. The
// first observation and any unreadable state count as changes, like the
// Wayland watcher reporting the current selection when it starts.
const UNREADABLE='\0unreadable';
class PollingSequence{
 constructor({signature,interval=1000,deadline=3000,enabled=()=>true,changed=()=>{}}){this.signature=signature;this.interval=interval;this.deadline=deadline;this.enabled=enabled;this.changed=changed;this.value=1;this.last=null;this.timer=null;this.busy=false;}
 start(){if(!this.timer){this.timer=setInterval(()=>void this.poll(),this.interval);this.timer.unref?.();}return this;}
 async poll(){
  if(this.busy||!this.enabled())return this.value;this.busy=true;let timer;
  try{
   const next=await Promise.race([this.signature(),new Promise((_resolve,reject)=>{timer=setTimeout(()=>reject(new Error('Clipboard poll timed out.')),this.deadline);})]);
   this.observe(next);
  }catch{this.observe(UNREADABLE);}finally{clearTimeout(timer);this.busy=false;}
  return this.value;
 }
 observe(next){if(next===this.last)return;this.last=next;if(next===UNREADABLE)return;this.value=this.value>=0xffffffff?1:this.value+1;this.changed(this.value);}
 kill(){clearInterval(this.timer);this.timer=null;}
}
// KDE's clipboard keeps a copied screenshot alive after its source exits by
// serving it again, re-encoded. The same pixels must not become a second item,
// so Linux identifies clipboard images by decoded content, not PNG bytes.
function pixelFingerprint(bytes,decode){
 let image;try{image=decode(bytes);}catch{return null;}
 if(!image||!Number.isInteger(image.width)||!Number.isInteger(image.height)||!image.bitmap?.length)return null;
 return 'image:pixels:'+image.width+'x'+image.height+':'+crypto.createHash('sha256').update(image.bitmap).digest('hex');
}

// A Linux selection disappears with the app that copied it; Spectacle quits
// right after copying a screenshot. Only that captured image is served again,
// and only while its item is still on the shelf and nothing else was copied:
// text, links and deleted copies stay gone, so a password manager's clear is
// never undone.
function keptCopy(kept,{fingerprint,items}){
 if(kept?.kind!=='image'||!kept.fingerprint||kept.fingerprint!==fingerprint)return null;
 return items.some(item=>item.id===kept.id&&!item.trashedAt&&!item.hiddenFromShelf)?kept:null;
}

function fileClipboard(files){
 const uris=files.map(file=>pathToFileURL(file).href);
 return{uriList:uris.join('\r\n')+'\r\n',gnome:'copy\n'+uris.join('\n')};
}
// Electron writes every format atomically. A native Wayland client may only
// set the selection with a recent input serial, so a write made while hidden
// (or without a key event) is verified and replaced by wl-copy if it is absent.
async function carriesMarker(reader,marker){
 for(const entry of await reader.read())if(entry.types.includes(MARKER_TYPE)&&Buffer.from(await(await entry.getType(MARKER_TYPE)).arrayBuffer()).equals(marker))return true;
 return false;
}
async function writeClipboard({clipboard,ClipboardItem,marker,text='',png=null,files=[],wayland=false,focused=false,wlCopy=null,wlPaste=null,run=readProcess,copy=copyProcess,delay=ms=>new Promise(resolve=>setTimeout(resolve,ms))}){
 const data={[MARKER_TYPE]:new Blob([marker])};
 if(text)data['text/plain']=new Blob([text],{type:'text/plain'});
 if(png)data['image/png']=new Blob([png],{type:'image/png'});
 const transfer=files.length?fileClipboard(files):null;
 if(transfer){data[URI_LIST]=new Blob([transfer.uriList]);data[GNOME_FILES]=new Blob([transfer.gnome]);}
 const primary=transfer?{type:'text/uri-list',bytes:Buffer.from(transfer.uriList)}:png?{type:'image/png',bytes:png}:{type:'text/plain;charset=utf-8',bytes:Buffer.from(text,'utf8')};
 if(!wayland||focused)await clipboard.write([new ClipboardItem(data)]);
 if(!wayland)return{method:'electron'};
 if(focused){
  if(!wlPaste||!wlCopy)return{method:'electron'};
  // Chromium re-encodes images, so the payload bytes cannot prove the write
  // landed; this copy's marker in the current selection does.
  const reader=new WaylandClipboard({wlPaste,run});
  for(let attempt=0;attempt<4;attempt++){
   try{if(await carriesMarker(reader,marker))return{method:'electron'};}catch{}
   await delay(75);
  }
 }
 if(!wlCopy)throw new Error('Install wl-clipboard so ClipBoardLine can copy while its window is hidden.');
 try{await copy(wlCopy,['--type',primary.type],{input:primary.bytes});}
 catch(error){if(focused)return{method:'electron'};throw error;}
 // wl-copy can return before its server owns the selection; the caller reads
 // the clipboard next to recognize this copy as its own.
 if(wlPaste)for(let attempt=0;attempt<20;attempt++){
  try{if((await run(wlPaste,['--no-newline','--type',primary.type],{limit:primary.bytes.length+1,timeout:3000})).equals(primary.bytes))break;}catch{}
  await delay(25);
 }
 return{method:'wl-copy',type:primary.type};
}
module.exports={WaylandClipboard,X11Clipboard,WaylandWatchers,PollingSequence,clipboardSignature,pixelFingerprint,keptCopy,writeClipboard,fileClipboard,readProcess,copyProcess,TEXT_TYPES,FORMAT_MAP,MARKER_TYPE};
