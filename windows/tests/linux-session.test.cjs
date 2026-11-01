'use strict';
// Linux desktop integration; the Linux CI runs it, and Windows hosts skip it.
const linuxOnly={skip:process.platform==='win32'&&'Linux desktop integration'};
const test=(name,options,body)=>typeof options==='function'?require('node:test').test(name,linuxOnly,options):require('node:test').test(name,{...options,...linuxOnly},body);
const assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {linuxSession,backendRelaunchArguments,linuxTools,findExecutable,desktopNames,mapAnimationDelay}=require('../lib/linux-session.cjs');

const kde={XDG_SESSION_TYPE:'wayland',WAYLAND_DISPLAY:'wayland-0',DISPLAY:':0',XDG_CURRENT_DESKTOP:'KDE'};
test('native Wayland is used where data-control lets wl-clipboard observe the selection',()=>{
  for(const desktop of ['KDE','sway','Hyprland','COSMIC','niri']){
    const value=linuxSession({...kde,XDG_CURRENT_DESKTOP:desktop},['electron']);
    assert.equal(value.backend,'wayland',desktop);assert.equal(value.session,'wayland');assert.equal(value.reason,'wayland-session');
  }
});
test('Mutter desktops use Xwayland because Mutter offers no data-control protocol',()=>{
  for(const desktop of ['GNOME','ubuntu:GNOME','GNOME-Classic:GNOME','Pantheon','X-Cinnamon','Budgie:GNOME']){
    const value=linuxSession({...kde,XDG_CURRENT_DESKTOP:desktop},[]);
    assert.equal(value.backend,'x11',desktop);assert.equal(value.session,'wayland');assert.equal(value.reason,'mutter-selection-bridge');assert.equal(value.mutter,true);
  }
  // Without an Xwayland display the app must remain a Wayland client.
  assert.equal(linuxSession({...kde,DISPLAY:'',XDG_CURRENT_DESKTOP:'GNOME'},[]).backend,'wayland');
});
test('X11 sessions stay on X11 and explicit choices are honored only when that display exists',()=>{
  assert.deepEqual({...linuxSession({XDG_SESSION_TYPE:'x11',DISPLAY:':0',XDG_CURRENT_DESKTOP:'XFCE'},[])},{session:'x11',backend:'x11',reason:'x11-session',desktop:'xfce',desktops:['xfce'],mutter:false});
  assert.equal(linuxSession({...kde,XDG_CURRENT_DESKTOP:'GNOME'},['--ozone-platform=wayland']).backend,'wayland');
  assert.equal(linuxSession(kde,['--ozone-platform=x11']).reason,'requested');
  assert.equal(linuxSession({...kde,CLIPBOARDLINE_DISPLAY_BACKEND:'x11'},[]).backend,'x11');
  assert.equal(linuxSession({...kde,DISPLAY:'',CLIPBOARDLINE_DISPLAY_BACKEND:'x11'},[]).backend,'wayland');
  assert.equal(linuxSession(kde,['--ozone-platform=headless']).backend,'wayland');
  assert.deepEqual(desktopNames({XDG_CURRENT_DESKTOP:' ubuntu : GNOME '}),['ubuntu','gnome']);
});
test('Xwayland on a Wayland session restarts once with a real backend argument',()=>{
  const gnome=linuxSession({...kde,XDG_CURRENT_DESKTOP:'ubuntu:GNOME'},[]);
  assert.deepEqual(backendRelaunchArguments(gnome,['--toggle']),['--toggle','--ozone-platform=x11']);
  assert.equal(backendRelaunchArguments(linuxSession({...kde,XDG_CURRENT_DESKTOP:'GNOME'},['--ozone-platform=x11']),['--ozone-platform=x11']),null);
  assert.equal(backendRelaunchArguments(linuxSession(kde,[]),[]),null);
  assert.equal(backendRelaunchArguments(linuxSession({XDG_SESSION_TYPE:'x11',DISPLAY:':0',XDG_CURRENT_DESKTOP:'XFCE'},[]),[]),null);
});
test('tool discovery accepts only executable regular files on absolute PATH entries',t=>{
  const root=fs.mkdtempSync(path.join(os.tmpdir(),'clipboardline-tools-'));t.after(()=>fs.rmSync(root,{recursive:true,force:true}));
  const bin=path.join(root,'bin');fs.mkdirSync(bin);fs.writeFileSync(path.join(bin,'wl-paste'),'#!/bin/sh\n',{mode:0o755});fs.writeFileSync(path.join(bin,'wl-copy'),'data',{mode:0o644});fs.mkdirSync(path.join(bin,'ffmpeg'));
  const env={PATH:['relative/bin',bin].join(path.delimiter)};
  if(process.platform!=='win32'){assert.equal(findExecutable('wl-paste',env),path.join(bin,'wl-paste'));assert.equal(findExecutable('wl-copy',env),null);}
  assert.equal(findExecutable('ffmpeg',env),null);assert.equal(findExecutable('../wl-paste',env),null);
  const tools=linuxTools(env,name=>name==='gdbus'?'/usr/bin/gdbus':null);assert.deepEqual(Object.keys(tools),['wl-paste','wl-copy','xclip','xdotool','ffmpeg','ffprobe','gdbus']);assert.equal(tools.gdbus,'/usr/bin/gdbus');assert.equal(Object.isFrozen(tools),true);
});
test('the reveal waits out the desktop map animation, scaled by KDE animation speed',()=>{
  const kde=linuxSession({XDG_CURRENT_DESKTOP:'KDE',WAYLAND_DISPLAY:'wayland-0'},[]),files=new Map(),read=file=>{if(!files.has(file))throw new Error('ENOENT');return files.get(file);};
  const env={HOME:'/home/user'};
  assert.equal(mapAnimationDelay(kde,{env,read}),200,'KWin Scale default');
  files.set('/home/user/.config/kdeglobals','[General]\nAnimationDurationFactor=4\n[KDE]\nLookAndFeelPackage=org.kde.breezedark.desktop\nAnimationDurationFactor=0.5\n');
  assert.equal(mapAnimationDelay(kde,{env,read}),100,'only the [KDE] group counts');
  files.set('/home/user/.config/kdeglobals','[KDE]\nAnimationDurationFactor=0\n');assert.equal(mapAnimationDelay(kde,{env,read}),0,'instant animations');
  files.set('/home/user/.config/kdeglobals','[KDE]\nAnimationDurationFactor=8\n');assert.equal(mapAnimationDelay(kde,{env,read}),600,'bounded');
  files.set('/xdg/kdeglobals','[KDE]\nAnimationDurationFactor=2\n');assert.equal(mapAnimationDelay(kde,{env:{...env,XDG_CONFIG_HOME:'/xdg'},read}),400);
  assert.equal(mapAnimationDelay(linuxSession({XDG_CURRENT_DESKTOP:'ubuntu:GNOME',WAYLAND_DISPLAY:'wayland-0',DISPLAY:':0'},[]),{env,read}),150,'Mutter');
  assert.equal(mapAnimationDelay(linuxSession({XDG_CURRENT_DESKTOP:'sway',WAYLAND_DISPLAY:'wayland-1'},[]),{env,read}),0,'no map animation to wait for');
});
