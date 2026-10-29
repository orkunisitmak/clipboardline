'use strict';
const {execFile}=require('node:child_process');
const {linuxSession,linuxTools}=require('./linux-session.cjs');
const {WaylandClipboard,X11Clipboard,WaylandWatchers,PollingSequence,clipboardSignature,writeClipboard}=require('./linux-clipboard.cjs');

// Linux implementation of the native bridge used by main.cjs. Window focus is
// returned by the compositor when the shelves hide. Under X11 xdotool, when
// installed, re-activates the captured window and sends the paste keystroke;
// Wayland deliberately offers no way to inject input into another client.
function command(file,args,{timeout=3000,children,exec=execFile}={}){
 return new Promise((resolve,reject)=>{
  const child=exec(file,args,{timeout,maxBuffer:64000},(error,stdout)=>{children?.delete(child);if(error)reject(error);else resolve(String(stdout).trim());});
  children?.add(child);
 });
}
function validTarget(value,ownPID){
 return !!value&&typeof value==='object'&&typeof value.handle==='string'&&/^\d{1,20}$/.test(value.handle)&&value.handle!=='0'&&
  Number.isInteger(value.processId)&&value.processId>0&&value.processId!==ownPID;
}
class LinuxPasteTargets{
 constructor(ownPID){this.ownPID=ownPID;this.external=null;}
 observe(){}
 capture(value){this.external=validTarget(value,this.ownPID)?Object.freeze({handle:value.handle,processId:value.processId}):null;return this.external;}
 reenter(){return this.external;}
 resolve(captured){return validTarget(captured,this.ownPID)?captured:null;}
 clear(){this.external=null;}
}
function createLinuxNative({session=linuxSession(),tools=linuxTools(),clipboard,ClipboardItem,options=()=>({text:true,images:false}),focused=()=>false,ownPID=process.pid,spawner,run,exec=execFile}={}){
 const children=new Set(),wayland=session.backend==='wayland',xdotool=session.backend==='x11'?tools.xdotool:null;
 let sequence=1,reader=null,watchers=null,poller=null,mode='none',problem='',notify=()=>{};
 // Change detection is its own path, like the Windows sequence number: it
 // reads only formats and TIMESTAMP, separately from the capture reader.
 const selection={read:clipboard?.read?.bind(clipboard)};
 const bump=()=>{sequence=sequence>=0xffffffff?1:sequence+1;notify(sequence);};
 const startPolling=()=>{
  reader=!wayland&&tools.xclip?new X11Clipboard({xclip:tools.xclip,...(run?{run}:{})}):null;mode=wayland?'focused-polling':'x11-polling';
  poller=new PollingSequence({signature:()=>clipboardSignature(reader||selection,{images:!!options().images}),enabled:()=>{const value=options();return !!(value.text||value.images);},changed:value=>{sequence=value;notify(value);}}).start();
 };
 const native={
  session,tools,
  // X11 has no change counter: read the selection now, so a copy made during
  // a capture read is detected like a Windows or Mac sequence change.
  clipboardSequence:async()=>poller?await poller.poll():sequence,
  // wl-paste reads through data-control without focus and xclip reads the X11
  // selection; without them Electron's clipboard is current under X11 (and
  // Xwayland on Mutter desktops).
  clipboardReader:fallback=>reader||fallback,
  // Nothing owns the selection, as after the app that copied has quit.
  clipboardEmpty:async()=>reader?!(await reader.types()).length:!(await selection.read()).some(entry=>entry.types?.length),
  monitor(changed,failed=()=>{}){
   notify=changed;
   if(wayland&&tools['wl-paste']){
    reader=new WaylandClipboard({wlPaste:tools['wl-paste'],...(run?{run}:{})});mode='wl-clipboard';
    watchers=new WaylandWatchers({wlPaste:tools['wl-paste'],...(spawner?{spawner}:{}),changed:bump,failed:error=>{
     watchers?.kill();watchers=null;problem=error.message;startPolling();
     failed(Object.assign(new Error(error.message+' Clipboard capture now works only while ClipBoardLine is focused.'),{recoverable:true}));
    }});
    watchers.update(options());
   }else{
    if(wayland)problem='Install wl-clipboard for background clipboard capture on Wayland.';
    startPolling();
   }
   return{kill:()=>{watchers?.kill();poller?.kill();watchers=null;},refresh:()=>watchers?.update(options())};
  },
  async capture(){
   if(!xdotool)return null;
   try{const handle=await command(xdotool,['getactivewindow'],{children,exec});const processId=Number(await command(xdotool,['getwindowpid',handle],{children,exec}));return validTarget({handle,processId},ownPID)?{handle,processId}:null;}
   catch{return null;}
  },
  async restore(target){if(xdotool&&validTarget(target,ownPID))await command(xdotool,['windowactivate','--sync',target.handle],{children,exec}).catch(()=>{});return{ok:true};},
  // Paste only into the exact window that was active before the shelves
  // opened, and only while it is still the active window.
  async paste(target){
   if(!xdotool||!validTarget(target,ownPID))return{pasted:false};
   if(await command(xdotool,['getactivewindow'],{children,exec})!==target.handle)throw new Error('The previous window is no longer active. The item was copied; press Ctrl+V to paste.');
   await command(xdotool,['key','--clearmodifiers','ctrl+v'],{children,exec});return{pasted:true};
  },
  cancelPaste(){for(const child of children)child.kill();children.clear();},
  write({text='',png=null,files=[],marker}){
   return writeClipboard({clipboard,ClipboardItem,marker,text,png,files,wayland,focused:focused(),wlCopy:wayland?tools['wl-copy']:null,wlPaste:wayland?tools['wl-paste']:null,...(run?{run}:{})});
  },
  status(){
   const missing=[];
   if(wayland&&(!tools['wl-paste']||!tools['wl-copy']))missing.push('wl-clipboard');
   if(!tools.ffmpeg||!tools.ffprobe)missing.push('ffmpeg');
   if(session.session==='wayland'&&!tools.gdbus)missing.push('gdbus');
   if(session.backend==='x11'&&!tools.xclip)missing.push('xclip');
   if(session.backend==='x11'&&!tools.xdotool)missing.push('xdotool');
   return{session:session.session,backend:session.backend,desktop:session.desktop,clipboardMonitor:mode,automaticPaste:!!xdotool,screenshot:session.session==='wayland'?'portal':'x11',recordings:!!(tools.ffmpeg&&tools.ffprobe),missing,problem};
  }
 };
 return native;
}
module.exports={createLinuxNative,LinuxPasteTargets,validTarget};
