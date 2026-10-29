'use strict';
const fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {spawn,execFileSync}=require('node:child_process');
const {which,session,runTool}=require('./linux-desktop.cjs');

// Shelf commands a desktop environment can bind when global key grabs are not
// delivered (for example GNOME Wayland): `clipboardline --toggle`.
const COMMANDS=Object.freeze({'--toggle':'toggle','--show':'show','--search':'search','--library':'library','--settings':'settings','--screenshot':'screenshot','--copy-latest':'copyLatest'});
function commandFromArgv(argv=[]){for(const value of argv)if(Object.hasOwn(COMMANDS,value))return COMMANDS[value];return null;}

// KDE, GNOME and Ubuntu bind Control+Alt+T to the terminal; on Linux that
// default would silently never reach the shelves. Saved choices still win.
const LINUX_DEFAULT_SETTINGS=Object.freeze({shortcuts:Object.freeze({toggle:'Control+Alt+V'})});

// KWin forwards only non-character key combinations to XWayland grabs, so an
// X11 Control+Alt+V registration never fires on Plasma Wayland. Plasma's own
// shortcut daemon (kglobalaccel) is reachable over D-Bus and shows the actions
// in System Settings → Shortcuts. This registry has the subset of Electron's
// globalShortcut interface that GlobalShortcuts uses.
const QT_MODIFIERS={control:0x04000000,ctrl:0x04000000,commandorcontrol:0x04000000,cmdorctrl:0x04000000,alt:0x08000000,option:0x08000000,altgr:0x08000000,shift:0x02000000,super:0x10000000,meta:0x10000000,cmd:0x10000000,command:0x10000000};
const QT_KEYS={space:0x20,tab:0x01000001,backspace:0x01000003,enter:0x01000004,return:0x01000004,escape:0x01000000,esc:0x01000000,insert:0x01000006,delete:0x01000007,home:0x01000010,end:0x01000011,
 left:0x01000012,arrowleft:0x01000012,up:0x01000013,arrowup:0x01000013,right:0x01000014,arrowright:0x01000014,down:0x01000015,arrowdown:0x01000015,pageup:0x01000016,pagedown:0x01000017,printscreen:0x01000009,
 plus:0x2b,minus:0x2d,'-':0x2d,'=':0x3d,',':0x2c,'.':0x2e,'/':0x2f,';':0x3b,"'":0x27,'[':0x5b,']':0x5d,'\\':0x5c,'`':0x60};
function qtKey(accelerator){
 if(typeof accelerator!=='string'||!accelerator||accelerator.length>80)return null;
 const parts=accelerator.endsWith('++')?[...accelerator.slice(0,-2).split('+'),'plus']:accelerator.split('+');
 let code=0,key=null;
 for(const raw of parts){
  const part=raw.trim().toLowerCase();if(!part)return null;
  if(Object.hasOwn(QT_MODIFIERS,part)){code|=QT_MODIFIERS[part];continue;}
  if(key!==null)return null;
  if(/^[a-z0-9]$/.test(part))key=part.toUpperCase().charCodeAt(0);
  else if(/^f([1-9]|1[0-9]|2[0-4])$/.test(part))key=0x01000030+Number(part.slice(1))-1;
  else if(Object.hasOwn(QT_KEYS,part))key=QT_KEYS[part];else return null;
 }
 return key===null?null:(code|key)>>>0;
}
class KdeShortcutRegistry{
 constructor({component='clipboardline',friendly='ClipBoardLine',call,componentCall,spawnMonitor=spawn}={}){
  this.component=component;this.friendly=friendly;this.spawnMonitor=spawnMonitor;this.callbacks=new Map();this.monitor=null;this.disposed=false;this.cleaned=false;
  this.path='/component/'+component.replace(/[^A-Za-z0-9]/g,'_');
  this.componentCall=componentCall||(method=>execFileSync('gdbus',['call','--session','--dest','org.kde.kglobalaccel','--object-path',this.path,'--method','org.kde.kglobalaccel.Component.'+method],{timeout:3000,encoding:'utf8',stdio:['ignore','pipe','ignore']}));
  this.call=call||((method,args)=>execFileSync('gdbus',['call','--session','--dest','org.kde.kglobalaccel','--object-path','/kglobalaccel','--method','org.kde.KGlobalAccel.'+method,...args],{timeout:3000,encoding:'utf8',stdio:['ignore','pipe','ignore']}));
 }
 id(accelerator){return JSON.stringify([this.component,accelerator,this.friendly,accelerator]);}
 // A killed instance cannot unregister, and kglobalaccel reports a key held by
 // our own stale action as unavailable. Each profile kind owns its component
 // (installed, development, one per test process) and holds the single-
 // instance lock, so registrations already present belong to a dead process.
 removeStale(){
  if(this.cleaned)return;this.cleaned=true;let names=[];
  try{names=[...this.componentCall('shortcutNames').matchAll(/'((?:[^'\\]|\\.)*)'/g)].map(match=>match[1]);}catch{}
  for(const name of names){try{this.call('unregister',[this.component,name]);}catch{}}
 }
 register(accelerator,callback){
  const key=qtKey(accelerator);if(key===null||typeof callback!=='function')return false;
  this.removeStale();
  if(!/\btrue\b/.test(this.call('isGlobalShortcutAvailable',[String(key|0),this.component])))return false;
  this.call('doRegister',[this.id(accelerator)]);
  // Flags SetPresent|NoAutoloading: apply this key now instead of a saved one.
  const assigned=this.call('setShortcut',[this.id(accelerator),'['+(key|0)+']','6']);
  if(!new RegExp('\\b'+(key|0)+'\\b').test(assigned)){this.unregister(accelerator);return false;}
  this.callbacks.set(accelerator,callback);this.listen();return true;
 }
 unregister(accelerator){this.callbacks.delete(accelerator);try{this.call('unregister',[this.component,accelerator]);}catch{}}
 unregisterAll(){for(const accelerator of [...this.callbacks.keys()])this.unregister(accelerator);}
 listen(){
  if(this.monitor||this.disposed)return;
  const child=this.spawnMonitor('gdbus',['monitor','--session','--dest','org.kde.kglobalaccel','--object-path',this.path],{stdio:['ignore','pipe','ignore']});
  this.monitor=child;let buffer='';
  child.stdout.on('data',chunk=>{
   buffer+=chunk.toString('utf8');if(buffer.length>65536)buffer='';let newline;
   while((newline=buffer.indexOf('\n'))>=0){
    const line=buffer.slice(0,newline);buffer=buffer.slice(newline+1);
    const match=/\.globalShortcutPressed \('([^']*)', '([^']*)'/.exec(line);
    if(match&&match[1]===this.component)this.callbacks.get(match[2])?.();
   }
  });
  child.on('error',()=>{});
  child.on('exit',()=>{if(this.monitor===child)this.monitor=null;if(!this.disposed&&this.callbacks.size)setTimeout(()=>this.listen(),1000).unref?.();});
 }
 dispose(){this.disposed=true;this.unregisterAll();this.monitor?.kill();this.monitor=null;}
}
// Plasma Wayland → kglobalaccel; X11 sessions → Electron (X key grabs work).
// Other Wayland desktops keep Electron's registration and the command-line
// actions above for a system shortcut.
function shortcutRegistry(electronShortcuts,{environment=process.env,find=which,component='clipboardline',create=options=>new KdeShortcutRegistry(options)}={}){
 const current=session(environment);
 if(!current.wayland||!current.desktop.some(name=>/^KDE$/i.test(name))||!find('gdbus'))return electronShortcuts;
 try{const registry=create({component});registry.call('isGlobalShortcutAvailable',[String(qtKey('Control+Alt+V')),registry.component]);return registry;}catch{return electronShortcuts;}
}

// On a Wayland session the window runs as a native Wayland client. XWayland
// is not a safe default: with Electron 44 on Mesa/Intel its GPU process
// crashes and the software fallback presents nothing, so the transparent
// shelves are invisible. Clipboard (wl-clipboard), Plasma shortcuts
// (kglobalaccel) and paste (ydotool) do not depend on this choice; other
// Wayland desktops get global shortcuts through the XDG portal.
// CLIPBOARDLINE_OZONE_PLATFORM=x11 or an explicit --ozone-platform overrides.
function configurePlatform(app,{argv=process.argv,environment=process.env}={}){
 const current=session(environment);
 // Electron pre-populates the resolved ozone-platform switch from its hint,
 // so only the real command line identifies an explicit user choice.
 const option=argv.find(value=>value.startsWith('--ozone-platform'));
 const requested=String(environment.CLIPBOARDLINE_OZONE_PLATFORM||'').toLowerCase();
 let platform=option?(option.split('=')[1]||'explicit'):'auto';
 if(!option&&['x11','wayland'].includes(requested)){app.commandLine.appendSwitch('ozone-platform',requested);platform=requested;}
 else if(!option&&current.wayland){app.commandLine.appendSwitch('ozone-platform','wayland');platform='wayland';}
 if(platform==='wayland')app.commandLine.appendSwitch('enable-features','GlobalShortcutsPortal');
 return platform;
}

// Screen capture: a Wayland compositor only lets its own tools read the
// screen without an interactive portal, and XWayland/desktopCapturer sees only
// X11 windows there. Use the desktop's screenshot tool, then fall back.
const SCREENSHOT_TOOLS=[
 ['spectacle',file=>['--background','--nonotify','--current','--output',file]],
 ['grim',file=>[file]],
 ['gnome-screenshot',file=>['--file',file]],
 ['xfce4-screenshooter',file=>['--fullscreen','--save',file]],
 ['scrot',file=>['--overwrite',file]]
];
async function screenshot({run=runTool,find=which,directory=os.tmpdir()}={}){
 const folder=fs.mkdtempSync(path.join(directory,'clipboardline-shot-'));
 try{
  for(const [name,args] of SCREENSHOT_TOOLS){
   const tool=find(name);if(!tool)continue;const file=path.join(folder,name+'.png');
   try{
    await run(tool,args(file),{timeout:15000,maximum:65536});
    const stat=fs.lstatSync(file);if(!stat.isFile()||stat.isSymbolicLink()||stat.size<67||stat.size>256*1024*1024)continue;
    const bytes=fs.readFileSync(file);if(bytes.subarray(0,8).toString('hex')==='89504e470d0a1a0a')return bytes;
   }catch{}
  }
  return null;
 }finally{fs.rmSync(folder,{recursive:true,force:true});}
}

// Electron's login-item API is macOS/Windows only. The XDG autostart folder is
// read by every freedesktop-compliant session.
function autostartFile(environment=process.env){return path.join(environment.XDG_CONFIG_HOME||path.join(os.homedir(),'.config'),'autostart','clipboardline.desktop');}
function quoteExec(value){return /^[A-Za-z0-9_./+-]+$/.test(value)?value:'"'+value.replace(/(["`$\\])/g,'\\$1')+'"';}
function setAutostart(enabled,{executable=process.env.APPIMAGE||process.execPath,environment=process.env}={}){
 const file=autostartFile(environment);
 if(!enabled){try{fs.unlinkSync(file);}catch(error){if(error.code!=='ENOENT')throw error;}return;}
 fs.mkdirSync(path.dirname(file),{recursive:true});
 fs.writeFileSync(file,['[Desktop Entry]','Type=Application','Name=ClipBoardLine','Comment=Keyboard-first clipboard shelves and library','Exec='+quoteExec(executable),'Icon=clipboardline','Terminal=false','X-GNOME-Autostart-enabled=true',''].join('\n'),{mode:0o644});
}
function linkFile(url){return '[Desktop Entry]\nType=Link\nName='+new URL(url).hostname+'\nURL='+url+'\nIcon=text-html\n';}
module.exports={qtKey,KdeShortcutRegistry,shortcutRegistry,COMMANDS,commandFromArgv,LINUX_DEFAULT_SETTINGS,configurePlatform,screenshot,SCREENSHOT_TOOLS,autostartFile,setAutostart,quoteExec,linkFile};
