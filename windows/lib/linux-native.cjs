'use strict';
const fs=require('node:fs'),path=require('node:path');
const {which,session,runTool,delay}=require('./linux-desktop.cjs');
const {linuxClipboard}=require('./linux-clipboard.cjs');

// Linux counterpart of windows-bridge.ps1. X11 exposes the active window and
// its process, so a captured destination is validated before keys are sent.
// Wayland deliberately hides other clients' windows: the compositor returns
// focus to the previous window when the shelves hide, and input is injected
// through the kernel uinput device (ydotool) because no portable protocol
// for synthetic keys exists.
const PASTE_KEYS=Object.freeze({
 'ctrl+v':{xdotool:'ctrl+v',ydotool:['29:1','47:1','47:0','29:0']},
 'shift+insert':{xdotool:'shift+Insert',ydotool:['42:1','110:1','110:0','42:0']},
 'ctrl+shift+v':{xdotool:'ctrl+shift+v',ydotool:['29:1','42:1','47:1','47:0','42:0','29:0']}
});
const controllers=new Set();
function pasteKeys(environment=process.env){return PASTE_KEYS[String(environment.CLIPBOARDLINE_PASTE_KEYS||'ctrl+v').toLowerCase().replace(/\s+/g,'')]||PASTE_KEYS['ctrl+v'];}
function ydotoolSocket(environment=process.env){
 const candidates=[environment.YDOTOOL_SOCKET,environment.XDG_RUNTIME_DIR&&path.join(environment.XDG_RUNTIME_DIR,'.ydotool_socket'),'/tmp/.ydotool_socket'].filter(Boolean);
 return candidates.find(file=>{try{return fs.statSync(file).isSocket();}catch{return false;}})||null;
}
function compositorTarget(){return{handle:'0',processId:0,runtime:'',editable:true,secure:false,compositor:true};}
function operation(){const controller=new AbortController();controllers.add(controller);return{signal:controller.signal,done:()=>controllers.delete(controller)};}
async function x11Window(signal){
 const xdotool=which('xdotool');if(!xdotool)return null;
 const handle=(await runTool(xdotool,['getactivewindow'],{timeout:1500,signal})).toString().trim();
 if(!/^\d{1,20}$/.test(handle)||handle==='0')return null;
 let processId=0;try{processId=Number((await runTool(xdotool,['getwindowpid',handle],{timeout:1500,signal})).toString().trim());}catch{}
 return{handle,processId:Number.isInteger(processId)?processId:0};
}
async function capture(){
 const current=session();
 if(current.wayland)return compositorTarget();
 const {signal,done}=operation();
 try{const active=await x11Window(signal);if(!active||active.processId<=0)return null;return{handle:active.handle,processId:active.processId,runtime:active.handle,editable:true,secure:false};}
 catch{return null;}finally{done();}
}
function injector(target){
 if(target?.compositor){
  const ydotool=which('ydotool');
  if(!ydotool||!ydotoolSocket())throw new Error('Automatic paste on Wayland needs the ydotool service (ydotoold). Press Enter to copy, then paste with Ctrl+V.');
  return{tool:ydotool,args:['key',...pasteKeys().ydotool]};
 }
 const xdotool=which('xdotool');if(!xdotool)throw new Error('Automatic paste on X11 needs xdotool. Press Enter to copy, then paste with Ctrl+V.');
 return{tool:xdotool,args:['key','--clearmodifiers',pasteKeys().xdotool]};
}
function expected(target){
 if(!target||(!target.compositor&&(!/^\d{1,20}$/.test(String(target.handle))||!(target.processId>0))))throw new Error('No previous application was captured.');
 return target;
}
async function owner(target,signal){
 const xdotool=which('xdotool');if(!xdotool)throw new Error('Automatic paste on X11 needs xdotool.');
 let processId=0;try{processId=Number((await runTool(xdotool,['getwindowpid',target.handle],{timeout:1500,signal})).toString().trim());}catch{}
 if(processId!==target.processId)throw new Error('The previous application has closed.');
}
async function activeIs(target,signal,{timeout=2000}={}){
 const deadline=Date.now()+timeout;
 do{const active=await x11Window(signal).catch(()=>null);if(active?.handle===target.handle)return true;await delay(40,signal);}while(Date.now()<deadline);
 return false;
}
async function restore(target){
 if(!target||target.compositor)return{ok:true,mode:'Restore'};
 const {signal,done}=operation();
 try{expected(target);await owner(target,signal);await runTool(which('xdotool'),['windowactivate',target.handle],{timeout:2000,signal});return{ok:true,mode:'Restore'};}
 finally{done();}
}
async function preparePaste(target){
 expected(target);injector(target);
 if(target.compositor)return{ok:true,mode:'PreparePaste'};
 const {signal,done}=operation();try{await owner(target,signal);return{ok:true,mode:'PreparePaste'};}finally{done();}
}
async function validatePaste(target){
 expected(target);const {signal,done}=operation();
 try{
  // The shelves were hidden by the caller. Give the compositor time to
  // return keyboard focus before the clipboard changes.
  if(target.compositor){await delay(180,signal);return{ok:true,mode:'ValidatePaste'};}
  await owner(target,signal);
  await runTool(which('xdotool'),['windowactivate','--sync',target.handle],{timeout:2500,signal}).catch(()=>{});
  if(!await activeIs(target,signal))throw new Error('Another window became active. No keys were sent.');
  return{ok:true,mode:'ValidatePaste'};
 }finally{done();}
}
async function paste(target){
 expected(target);const keys=injector(target),{signal,done}=operation();
 try{
  if(!target.compositor&&!await activeIs(target,signal,{timeout:600}))throw new Error('Focus changed before paste. No keys were sent.');
  await runTool(keys.tool,keys.args,{timeout:3000,signal});
  return{ok:true,mode:'Paste'};
 }finally{done();}
}
function cancelPaste(){for(const controller of controllers)controller.abort();controllers.clear();}
function diagnostics(){
 const current=session(),clipboard=linuxClipboard();
 return{ok:true,platform:'linux',session:current.wayland?'wayland':current.x11?'x11':'unknown',desktop:current.desktop,clipboardBackend:clipboard.backend,
  tools:Object.fromEntries(['wl-copy','wl-paste','xclip','xdotool','ydotool','ffmpeg','ffprobe','spectacle','grim','gnome-screenshot'].map(name=>[name,!!which(name)])),ydotoolSocket:!!ydotoolSocket(),pasteKeys:String(process.env.CLIPBOARDLINE_PASTE_KEYS||'ctrl+v')};
}
function monitor(changed,failed){
 const clipboard=linuxClipboard();
 const offChange=clipboard.onChange(sequence=>changed(sequence));
 const offFailure=clipboard.onFailure(error=>failed(error));
 clipboard.start();
 // main.cjs treats a null monitor as "poll by timer"; the Linux watcher keeps
 // running behind this handle, so return an object with the same kill() shape.
 return{kill(){offChange();offFailure();}};
}
async function copyImages(payload){
 if(!Array.isArray(payload?.files)||payload.files.length<1||payload.files.length>1000||payload.files.some(file=>typeof file!=='string'||!path.isAbsolute(file)||path.extname(file)!=='.png'))throw new Error('Invalid image batch.');
 await linuxClipboard().write({files:payload.files,marker:payload.marker?Buffer.from(payload.marker,'base64'):null});
 return{ok:true};
}
module.exports={
 clipboardSequence:async()=>linuxClipboard().sequence(),cancelPaste,capture,captureDiagnostics:async()=>diagnostics(),selfTestFocusPolicy:async()=>diagnostics(),
 restore,preparePaste,validatePaste,paste,copyImages,monitor,pasteKeys,ydotoolSocket,compositorTarget
};
