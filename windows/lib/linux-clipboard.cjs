'use strict';
const {spawn}=require('node:child_process');
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const {pathToFileURL}=require('node:url');
const {privateClipboard}=require('./clipboard-policy.cjs');

// Linux clipboard access through the desktop's own selection tools. A hidden
// native Wayland client cannot read the selection, so wl-clipboard (data-control)
// or xclip owns every read, write and change notification. No clipboard content
// is logged or retained by this module.
const MAXIMUM_BYTES=64*1024*1024;
const TEXT_TYPES=['text/plain;charset=utf-8','UTF8_STRING','text/plain','STRING','TEXT'];
const IMAGE_TYPES=['image/png','image/jpeg','image/bmp','image/webp'];
const FORMAT_MAP='application/web;type="custom/formatmap"',MARKER_TYPE='web application/x.clipboardline';
const URI_LIST='electron application/osclipboard;format="text/uri-list"',GNOME_FILES='electron application/osclipboard;format="x-special/gnome-copied-files"';

function which(name,{environment=process.env}={}){
  for(const directory of String(environment.PATH||'').split(path.delimiter)){
    if(!directory)continue;const file=path.join(directory,name);
    try{fs.accessSync(file,fs.constants.X_OK);if(fs.statSync(file).isFile())return file;}catch{}
  }
  return null;
}
function backend({environment=process.env,find=name=>which(name,{environment}),display=null}={}){
  if(display!=='x11'&&environment.WAYLAND_DISPLAY&&find('wl-paste')&&find('wl-copy'))return'wayland';
  if(environment.DISPLAY&&find('xclip'))return'x11';
  return null;
}
function run(file,args,{input,maximum=MAXIMUM_BYTES,timeout=5000}={}){
  return new Promise((resolve,reject)=>{
    const child=spawn(file,args,{stdio:['pipe','pipe','ignore']});
    const chunks=[];let size=0,failure=null;
    const timer=setTimeout(()=>{failure=new Error('Clipboard helper timed out.');child.kill();},timeout);
    child.stdout.on('data',chunk=>{size+=chunk.length;if(size>maximum){failure=new Error('Clipboard content exceeds the safe size.');child.kill();return;}chunks.push(chunk);});
    child.on('error',error=>{clearTimeout(timer);reject(failure||error);});
    child.on('close',code=>{clearTimeout(timer);if(failure)return reject(failure);if(code!==0)return reject(Object.assign(new Error('Clipboard helper failed.'),{exitCode:code}));resolve(Buffer.concat(chunks));});
    child.stdin.on('error',()=>{});child.stdin.end(input??'');
  });
}
// Chromium publishes web custom formats under generated names listed in a map.
function markerTarget(map,types){
  if(!map||typeof map!=='object'||Array.isArray(map))return null;
  for(const[key,value]of Object.entries(map)){
    if(!['application/x.clipboardline',MARKER_TYPE].includes(key)||typeof value!=='string'||value.length>200)continue;
    const target=value.startsWith('application/web')?value:`application/web;type="${value}"`;
    if(types.includes(target))return target;
  }
  return null;
}
function blob(bytes,type){return{type,size:bytes.length,arrayBuffer:async()=>bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.length)};}

class LinuxClipboard{
  constructor({kind=backend(),runner=run,convertImage=null}={}){this.kind=kind;this.runner=runner;this.convertImage=convertImage;}
  get available(){return this.kind==='wayland'||this.kind==='x11';}
  listCommand(){return this.kind==='wayland'?['wl-paste',['--no-newline','--list-types']]:['xclip',['-selection','clipboard','-t','TARGETS','-o']];}
  readCommand(type){return this.kind==='wayland'?['wl-paste',['--no-newline','--type',type]]:['xclip',['-selection','clipboard','-t',type,'-o']];}
  async types(){
    if(!this.available)throw new Error('No Linux clipboard tool is available. Install wl-clipboard or xclip.');
    let output;try{output=await this.runner(...this.listCommand(),{maximum:64000});}catch(error){if(error.exitCode!==undefined)return[];throw error;}
    return[...new Set(output.toString('utf8').split('\n').map(value=>value.trim()).filter(value=>value&&value.length<=200))];
  }
  async raw(type){const[file,args]=this.readCommand(type);return this.runner(file,args);}
  // Mirrors Electron's clipboard.read(): one item whose web types are normalized
  // while the native type names stay visible to the privacy marker policy.
  async read(){
    const native=await this.types();if(!native.length)return[];
    const text=TEXT_TYPES.find(type=>native.includes(type)),image=IMAGE_TYPES.find(type=>native.includes(type));
    const types=[...native];if(text&&!types.includes('text/plain'))types.push('text/plain');if(image&&!types.includes('image/png'))types.push('image/png');
    let marker=null;
    if(native.includes(FORMAT_MAP)){let map=null;try{map=JSON.parse((await this.raw(FORMAT_MAP)).toString('utf8'));}catch{}marker=markerTarget(map,native);if(marker)types.push(MARKER_TYPE);}
    const getType=async type=>{
      if(type==='text/plain'&&text)return blob(await this.raw(text),'text/plain');
      if(type==='image/png'&&image){
        let bytes=await this.raw(image);
        if(image!=='image/png'){if(!this.convertImage)throw new Error('Clipboard image format is unsupported.');bytes=this.convertImage(bytes);}
        return blob(bytes,'image/png');
      }
      if(type===MARKER_TYPE&&marker)return blob(await this.raw(marker),type);
      if(!native.includes(type))throw new Error('Clipboard format is unavailable.');
      return blob(await this.raw(type),type);
    };
    // The change signature hashes the offered bytes without converting them.
    return[{types,getType,imageBytes:image?()=>this.raw(image):null}];
  }
  writeCommand(type){return this.kind==='wayland'?['wl-copy',['--type',type]]:['xclip',['-selection','clipboard','-t',type,'-i','-quiet']];}
  // wl-copy and xclip stay alive as the selection owner; never wait for exit.
  write(type,bytes){
    if(!this.available)return Promise.reject(new Error('No Linux clipboard tool is available. Install wl-clipboard or xclip.'));
    const[file,args]=this.writeCommand(type);
    return new Promise((resolve,reject)=>{
      const child=spawn(file,args,{stdio:['pipe','ignore','ignore'],detached:true});
      let settled=false;const done=error=>{if(settled)return;settled=true;error?reject(error):resolve();};
      child.on('error',error=>done(error));
      child.on('exit',code=>done(code===0?null:new Error('The Linux clipboard rejected this copy.')));
      child.stdin.on('error',()=>{});child.stdin.end(bytes,()=>setTimeout(()=>{child.unref();done(null);},this.kind==='x11'?150:60));
    });
  }
  writeText(value){return this.write('text/plain;charset=utf-8',Buffer.from(String(value),'utf8'));}
  writePNG(bytes){return this.write('image/png',bytes);}
  // File managers (Dolphin, Nautilus, Thunar) accept RFC 2483 URI lists.
  writeFiles(files){
    if(!Array.isArray(files)||!files.length||files.length>1000||files.some(file=>typeof file!=='string'||!path.isAbsolute(file)))return Promise.reject(new Error('A copied file is unavailable.'));
    return this.write('text/uri-list',Buffer.from(files.map(file=>'file://'+file.split('/').map(encodeURIComponent).join('/')).join('\r\n')+'\r\n','utf8'));
  }
}

// Electron writes every format at once, including this copy's marker. A native
// Wayland client may set the selection only with a recent input serial, so a
// write made while hidden is verified and replaced by wl-copy, which offers the
// main format alone. X11 selections need no focus.
function fileClipboard(files){
  const uris=files.map(file=>pathToFileURL(file).href);
  return{uriList:uris.join('\r\n')+'\r\n',gnome:'copy\n'+uris.join('\n')};
}
async function carriesMarker(reader,marker){
  for(const entry of await reader.read())if(entry.types.includes(MARKER_TYPE)&&Buffer.from(await(await entry.getType(MARKER_TYPE)).arrayBuffer()).equals(marker))return true;
  return false;
}
async function writeClipboard({electron,ClipboardItem,tool,marker,text='',png=null,files=[],focused=false,delay=ms=>new Promise(resolve=>setTimeout(resolve,ms))}){
  const data={[MARKER_TYPE]:new Blob([marker])},wayland=tool.kind==='wayland';
  if(text)data['text/plain']=new Blob([text],{type:'text/plain'});
  if(png)data['image/png']=new Blob([png],{type:'image/png'});
  const transfer=files.length?fileClipboard(files):null;
  if(transfer){data[URI_LIST]=new Blob([transfer.uriList]);data[GNOME_FILES]=new Blob([transfer.gnome]);}
  if(!wayland||focused)await electron.write([new ClipboardItem(data)]);
  if(!wayland)return'electron';
  // Chromium re-encodes images, so only this copy's marker proves the write landed.
  if(focused)for(let attempt=0;attempt<4;attempt++){
    try{if(await carriesMarker(tool,marker))return'electron';}catch{}
    await delay(75);
  }
  if(files.length)await tool.writeFiles(files);else if(png)await tool.writePNG(png);else await tool.writeText(text);
  return'wl-copy';
}

// Copies are told apart without reading them where possible. Owners publish
// TIMESTAMP when they acquire the selection; content hashes cover owners that
// omit it. Mutter's Xwayland bridge lists TIMESTAMP but cannot serve it, so a
// failure falls through to content. A private copy is identified by its formats
// alone, and image payloads are hashed only when images are captured.
async function clipboardSignature(clipboard,{images=false}={}){
  const entries=await clipboard.read(),hash=crypto.createHash('sha256');
  if(privateClipboard(entries.flatMap(entry=>entry.types))){for(const entry of entries)hash.update(JSON.stringify(entry.types));return hash.digest('hex');}
  for(const entry of entries){
    hash.update(JSON.stringify(entry.types));
    const timestamp=entry.types.find(type=>/^TIMESTAMP$|format="TIMESTAMP"/.test(type));
    if(timestamp){
      let bytes=null;try{bytes=Buffer.from(await(await entry.getType(timestamp)).arrayBuffer());}catch{}
      if(bytes?.length&&bytes.some(Boolean)){hash.update(bytes);continue;}
    }
    if(entry.types.includes('text/plain'))hash.update(Buffer.from(await(await entry.getType('text/plain')).arrayBuffer()));
    if(images&&entry.imageBytes)hash.update(await entry.imageBytes());
    else if(images&&entry.types.includes('image/png'))hash.update(Buffer.from(await(await entry.getType('image/png')).arrayBuffer()));
  }
  return hash.digest('hex');
}

// Monotonic change counter. wl-paste --watch reports every selection change on
// data-control compositors (KDE, wlroots). Other sessions poll the signature
// above, backing off after an expensive read. Without data-control every wl-paste
// takes focus for a moment, so a Wayland fallback reads only while focused.
class ClipboardWatcher{
  constructor(clipboard,{changed=()=>{},failed=()=>{},interval=750,spawner=spawn,now=Date.now,context=()=>({images:true,focused:true})}={}){
    this.clipboard=clipboard;this.changed=changed;this.failed=failed;this.interval=interval;this.spawner=spawner;this.now=now;this.context=context;this.resume=0;
    this.sequence=1;this.child=null;this.timer=null;this.signature=null;this.stopped=false;this.polling=false;
  }
  bump(){this.sequence=this.sequence>=0xffffffff?1:this.sequence+1;try{this.changed(this.sequence);}catch{}}
  start(){
    if(this.clipboard.kind==='wayland'){
      const child=this.spawner('wl-paste',['--watch','echo','changed'],{stdio:['ignore','pipe','ignore']});this.child=child;
      // The first line reports the selection present at startup, even an empty
      // one. Only later changes count, as on Windows and macOS.
      let launched=false;
      child.stdout.on('data',chunk=>{for(const line of chunk.toString().split('\n'))if(line.trim()==='changed'){if(launched)this.bump();launched=true;}});
      // GNOME has no data-control protocol and wl-paste exits at once there.
      // Any watcher exit keeps the same sequence counter alive by polling.
      const fallback=()=>{if(this.child===child)this.child=null;if(this.stopped||this.timer)return;this.poll();this.failed(Object.assign(new Error('The wl-paste clipboard monitor stopped. Clipboard capture now works only while ClipBoardLine is focused.'),{recoverable:true}));};
      child.on('error',fallback);child.on('exit',fallback);
    }else this.poll();
    return this;
  }
  digest(){return clipboardSignature(this.clipboard,{images:this.context().images});}
  poll(){
    if(this.timer||this.stopped)return;
    const tick=async()=>{
      const started=this.now();
      if(this.polling||started<this.resume||(this.clipboard.kind==='wayland'&&!this.context().focused))return;this.polling=true;
      try{const signature=await this.digest();if(this.signature!==null&&signature!==this.signature)this.bump();this.signature=signature;}catch{}
      finally{this.polling=false;this.resume=this.now()+Math.min(5000,(this.now()-started)*4);}
    };
    void tick();this.timer=setInterval(()=>void tick(),this.interval);
  }
  read(){return this.sequence;}
  kill(){this.stopped=true;clearInterval(this.timer);this.timer=null;this.child?.kill();this.child=null;}
}
// A Linux selection disappears when the app that copied it quits. Only a captured
// image still on the shelf comes back: text and links stay cleared, so a password
// manager's clear is never undone.
// KDE's clipboard keeps a copied screenshot alive after its source exits by
// serving it again, re-encoded. The same pixels must not become a second item,
// so Linux identifies clipboard images by decoded content, not bytes. A small
// file can declare huge dimensions, so the limit on a stored image applies first:
// decoding would allocate the whole bitmap.
const MAXIMUM_PIXELS=80_000_000;
function decodablePNG(bytes){
  if(!Buffer.isBuffer(bytes)||bytes.length<24||bytes.subarray(0,8).toString('hex')!=='89504e470d0a1a0a'||bytes.subarray(12,16).toString('latin1')!=='IHDR')return false;
  const width=bytes.readUInt32BE(16),height=bytes.readUInt32BE(20);
  return width>0&&height>0&&width*height<=MAXIMUM_PIXELS;
}
function decodableJPEG(bytes){
  if(!Buffer.isBuffer(bytes)||bytes[0]!==0xff||bytes[1]!==0xd8)return false;
  for(let offset=2;offset+9<bytes.length;offset+=2+bytes.readUInt16BE(offset+2)){
    if(bytes[offset]!==0xff)return false;
    const marker=bytes[offset+1];
    if(marker>=0xc0&&marker<=0xcf&&![0xc4,0xc8,0xcc].includes(marker)){const height=bytes.readUInt16BE(offset+5),width=bytes.readUInt16BE(offset+7);return width>0&&height>0&&width*height<=MAXIMUM_PIXELS;}
  }
  return false;
}
function pixelFingerprint(bytes,decode){
  if(!decodablePNG(bytes))return null;
  let image;try{image=decode(bytes);}catch{return null;}
  if(!image||!Number.isInteger(image.width)||!Number.isInteger(image.height)||!image.bitmap?.length)return null;
  return 'image:pixels:'+image.width+'x'+image.height+':'+crypto.createHash('sha256').update(image.bitmap).digest('hex');
}
function keptImage(id,items){return items.find(item=>item.id===id&&item.kind==='image'&&!item.recording&&!item.trashedAt&&!item.hiddenFromShelf)||null;}
module.exports={keptImage,pixelFingerprint,decodableJPEG,LinuxClipboard,ClipboardWatcher,clipboardSignature,writeClipboard,fileClipboard,backend,which,run,TEXT_TYPES,IMAGE_TYPES,FORMAT_MAP,MARKER_TYPE};
