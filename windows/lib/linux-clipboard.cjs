'use strict';
const {spawn}=require('node:child_process');
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');

// Linux clipboard access through the desktop's own selection tools. A hidden
// native Wayland client cannot read the selection, so wl-clipboard (data-control)
// or xclip owns every read, write and change notification. No clipboard content
// is logged or retained by this module.
const MAXIMUM_BYTES=64*1024*1024;
const TEXT_TYPES=['text/plain;charset=utf-8','UTF8_STRING','text/plain','STRING','TEXT'];
const IMAGE_TYPES=['image/png','image/jpeg','image/bmp','image/webp'];

function which(name,{environment=process.env}={}){
  for(const directory of String(environment.PATH||'').split(path.delimiter)){
    if(!directory)continue;const file=path.join(directory,name);
    try{fs.accessSync(file,fs.constants.X_OK);if(fs.statSync(file).isFile())return file;}catch{}
  }
  return null;
}
function backend({environment=process.env,find=name=>which(name,{environment})}={}){
  if(environment.WAYLAND_DISPLAY&&find('wl-paste')&&find('wl-copy'))return'wayland';
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
    const getType=async type=>{
      if(type==='text/plain'&&text)return blob(await this.raw(text),'text/plain');
      if(type==='image/png'&&image){
        let bytes=await this.raw(image);
        if(image!=='image/png'){if(!this.convertImage)throw new Error('Clipboard image format is unsupported.');bytes=this.convertImage(bytes);}
        return blob(bytes,'image/png');
      }
      if(!native.includes(type))throw new Error('Clipboard format is unavailable.');
      return blob(await this.raw(type),type);
    };
    return[{types,getType}];
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

// Monotonic change counter. wl-paste --watch reports every selection change on
// data-control compositors (KDE, wlroots). Other sessions use bounded polling
// of the native type list and payload digest.
class ClipboardWatcher{
  constructor(clipboard,{changed=()=>{},interval=750,spawner=spawn}={}){
    this.clipboard=clipboard;this.changed=changed;this.interval=interval;this.spawner=spawner;
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
      child.on('error',()=>{if(this.child===child)this.child=null;if(!this.stopped)this.poll();});
      child.on('exit',()=>{if(this.child===child)this.child=null;if(!this.stopped)this.poll();});
    }else this.poll();
    return this;
  }
  async digest(){
    const types=await this.clipboard.types(),hash=crypto.createHash('sha256').update(types.join('\n'));
    const type=IMAGE_TYPES.find(value=>types.includes(value))||TEXT_TYPES.find(value=>types.includes(value));
    if(type)hash.update(await this.clipboard.raw(type));
    return hash.digest('hex');
  }
  poll(){
    if(this.timer||this.stopped)return;
    const tick=async()=>{
      if(this.polling)return;this.polling=true;
      try{const signature=await this.digest();if(this.signature!==null&&signature!==this.signature)this.bump();this.signature=signature;}catch{}
      finally{this.polling=false;}
    };
    void tick();this.timer=setInterval(()=>void tick(),this.interval);
  }
  read(){return this.sequence;}
  kill(){this.stopped=true;clearInterval(this.timer);this.timer=null;this.child?.kill();this.child=null;}
}
module.exports={LinuxClipboard,ClipboardWatcher,backend,which,run,TEXT_TYPES,IMAGE_TYPES};
