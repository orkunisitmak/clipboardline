'use strict';
const fs=require('node:fs'),path=require('node:path');

// Mutter-based compositors expose neither wlr- nor ext-data-control, so a
// native Wayland client cannot observe another application's clipboard while
// it is hidden. Mutter mirrors the Wayland selection to Xwayland, which keeps
// background capture available to an X11 client on these desktops.
const MUTTER_DESKTOPS=new Set(['gnome','gnome-classic','gnome-flashback','ubuntu','pantheon','budgie','budgie-desktop','unity','x-cinnamon','cinnamon']);
const BACKENDS=new Set(['wayland','x11']);

function desktopNames(env=process.env){
 return String(env.XDG_CURRENT_DESKTOP||env.XDG_SESSION_DESKTOP||env.DESKTOP_SESSION||'').split(':').map(value=>value.trim().toLowerCase()).filter(Boolean);
}
function explicitBackend(argv=process.argv){
 const value=argv.find(argument=>typeof argument==='string'&&argument.startsWith('--ozone-platform='))?.slice('--ozone-platform='.length);
 return BACKENDS.has(value)?value:null;
}
// Chooses the Electron display backend before the app is ready. The user can
// override it with --ozone-platform=x11|wayland or CLIPBOARDLINE_DISPLAY_BACKEND.
function linuxSession(env=process.env,argv=process.argv){
 const desktops=desktopNames(env),wayland=!!env.WAYLAND_DISPLAY||env.XDG_SESSION_TYPE==='wayland',xwayland=!!env.DISPLAY;
 const mutter=desktops.some(name=>MUTTER_DESKTOPS.has(name));
 const requested=explicitBackend(argv)||(BACKENDS.has(env.CLIPBOARDLINE_DISPLAY_BACKEND)?env.CLIPBOARDLINE_DISPLAY_BACKEND:null);
 let backend,reason;
 if(requested&&(requested==='x11'?xwayland:wayland)){backend=requested;reason='requested';}
 else if(!wayland){backend='x11';reason='x11-session';}
 else if(mutter&&xwayland){backend='x11';reason='mutter-selection-bridge';}
 else{backend='wayland';reason='wayland-session';}
 return Object.freeze({session:wayland?'wayland':'x11',backend,reason,desktop:desktops[0]||'',desktops:Object.freeze(desktops),mutter});
}
// Chromium picks its display backend before any application code runs, so a
// switch appended from main.cjs reaches only child processes. The Wayland browser
// process would then hand its surfaces to an X11 GPU process, which crashes and
// presents nothing. Xwayland on a Wayland session therefore needs a real argument.
function backendRelaunchArguments(session,argv=process.argv.slice(1)){
 if(session?.session!=='wayland'||session.backend!=='x11'||argv.some(argument=>typeof argument==='string'&&argument.startsWith('--ozone-platform=')))return null;
 return[...argv,'--ozone-platform=x11'];
}
function findExecutable(name,env=process.env){
 if(typeof name!=='string'||!/^[A-Za-z0-9._-]+$/.test(name))return null;
 for(const directory of String(env.PATH||'').split(path.delimiter)){
  if(!directory||!path.isAbsolute(directory))continue;
  const file=path.join(directory,name);
  try{if(fs.statSync(file).isFile()){fs.accessSync(file,fs.constants.X_OK);return file;}}catch{}
 }
 return null;
}
function linuxTools(env=process.env,find=findExecutable){
 return Object.freeze(Object.fromEntries(['wl-paste','wl-copy','xclip','xdotool','ffmpeg','ffprobe','gdbus'].map(name=>[name,find(name,env)])));
}
// KWin (Scale) and Mutter fade in every newly mapped window, which would hide
// a reveal that starts at the same moment. The line waits out that animation;
// KDE stretches it by the user's animation speed (0 turns animations off).
function mapAnimationDelay(session,{env=process.env,read=fs.readFileSync}={}){
 if(!session?.desktops?.includes('kde'))return session?.mutter?150:0;
 let factor=1;
 try{
  const home=path.isAbsolute(env.XDG_CONFIG_HOME||'')?env.XDG_CONFIG_HOME:path.join(env.HOME||'/','.config');let section='';
  for(const line of String(read(path.join(home,'kdeglobals'),'utf8')).split('\n')){const value=line.trim();if(value.startsWith('['))section=value;else if(section==='[KDE]'&&value.startsWith('AnimationDurationFactor='))factor=Number(value.slice(24));}
 }catch{}
 return Number.isFinite(factor)?Math.round(Math.min(600,Math.max(0,200*factor))):200;
}
module.exports={linuxSession,backendRelaunchArguments,linuxTools,findExecutable,desktopNames,mapAnimationDelay,MUTTER_DESKTOPS};
