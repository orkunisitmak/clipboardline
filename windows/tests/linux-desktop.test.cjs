'use strict';
// Linux desktop integration; the Linux CI runs it, and Windows hosts skip it.
const linuxOnly={skip:process.platform==='win32'&&'Linux desktop integration'};
const test=(name,options,body)=>typeof options==='function'?require('node:test').test(name,linuxOnly,options):require('node:test').test(name,{...options,...linuxOnly},body);
const assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {EventEmitter}=require('node:events'),{execFileSync}=require('node:child_process');
const {parseResponse,screenshotPath,portalScreenshot}=require('../lib/linux-screenshot.cjs');
const {setAutostart,autostartEnabled,autostartEntry,autostartFile,execArgument}=require('../lib/linux-autostart.cjs');
const {linkFile}=require('../lib/link-file.cjs');
const {createLinuxNative,LinuxPasteTargets}=require('../lib/linux-native.cjs');
function temporary(t){const root=fs.mkdtempSync(path.join(os.tmpdir(),'clipboardline-linux-desktop-'));t.after(()=>fs.rmSync(root,{recursive:true,force:true}));return root;}

test('only the matching portal request response is accepted and its file URI is decoded',t=>{
  const token='clipboardline_0123456789abcdef',line=uri=>`/org/freedesktop/portal/desktop/request/1_42/${token}: org.freedesktop.portal.Request.Response (uint32 0, {'uri': <'${uri}'>})`;
  assert.deepEqual(parseResponse(line('file:///tmp/Screenshot%20one.png'),token),{code:0,uri:'file:///tmp/Screenshot%20one.png'});
  assert.equal(parseResponse(line('file:///tmp/a.png'),'clipboardline_other'),null);
  assert.equal(parseResponse(`/org/freedesktop/portal/desktop/request/1_42/${token}: org.freedesktop.portal.Request.Closed ()`,token),null);
  assert.deepEqual(parseResponse(`/org/freedesktop/portal/desktop/request/1_42/${token}: org.freedesktop.portal.Request.Response (uint32 1, @a{sv} {})`,token),{code:1,uri:null});
  assert.throws(()=>screenshotPath({code:1,uri:null}),/canceled/);assert.throws(()=>screenshotPath({code:2,uri:null}),/could not capture/);
  assert.throws(()=>screenshotPath({code:0,uri:'https://example.com/a.png'}),/unsupported location/);
  const root=temporary(t),file=path.join(root,'Screenshot one.png');fs.writeFileSync(file,'png');
  assert.equal(screenshotPath({code:0,uri:'file://'+root.split(path.sep).map(encodeURIComponent).join('/')+'/Screenshot%20one.png'}),file);
  fs.symlinkSync(file,path.join(root,'link.png'));assert.throws(()=>screenshotPath({code:0,uri:'file://'+path.join(root,'link.png')}),/unavailable/);
});
test('the portal is called only after the signal subscription is confirmed',async t=>{
  const root=temporary(t),file=path.join(root,'shot.png');fs.writeFileSync(file,'png');
  const monitor=new EventEmitter();monitor.stdout=new EventEmitter();monitor.kill=()=>{monitor.killed=true;};
  const calls=[];let token;
  const pending=portalScreenshot({gdbus:'gdbus',spawner:(_file,args)=>{assert.deepEqual(args,['monitor','--session','--dest','org.freedesktop.portal.Desktop']);return monitor;},caller:(_file,args,_options,done)=>{calls.push(args);token=/'handle_token': <'([a-z0-9_]+)'>/.exec(args.at(-1))[1];setImmediate(()=>done(null));}});
  assert.equal(calls.length,0);monitor.stdout.emit('data',Buffer.from('Monitoring signals from all objects owned by org.freedesktop.portal.Desktop\n'));
  assert.equal(calls.length,1);assert.ok(calls[0].includes('org.freedesktop.portal.Screenshot.Screenshot'));assert.match(calls[0].at(-1),/'interactive': <false>/);
  monitor.stdout.emit('data',Buffer.from(`/org/freedesktop/portal/desktop/request/1_9/other: org.freedesktop.portal.Request.Response (uint32 0, {'uri': <'file:///etc/passwd'>})\n`));
  monitor.stdout.emit('data',Buffer.from(`/org/freedesktop/portal/desktop/request/1_9/${token}: org.freedesktop.portal.Request.Response (uint32 0, {'uri': <'file://${file}'>})\n`));
  assert.equal(await pending,file);assert.equal(monitor.killed,true);
  await assert.rejects(portalScreenshot({gdbus:null}),/requires gdbus/);
});
test('autostart writes an owned XDG entry, quotes paths and never replaces a foreign entry',t=>{
  const root=temporary(t),env={XDG_CONFIG_HOME:path.join(root,'config'),HOME:root},file=autostartFile(env);
  assert.equal(file,path.join(root,'config','autostart','clipboardline.desktop'));
  assert.equal(setAutostart(true,{env,command:['/opt/ClipBoardLine/clipboardline']}),true);assert.equal(autostartEnabled(env),true);
  const entry=fs.readFileSync(file,'utf8');assert.match(entry,/^\[Desktop Entry\]\nType=Application\n/);assert.match(entry,/\nExec=\/opt\/ClipBoardLine\/clipboardline\n/);assert.match(entry,/X-ClipBoardLine-Autostart=true/);
  assert.equal(execArgument('/home/u/Apps/Clip Board 100%.AppImage'),'"/home/u/Apps/Clip Board 100%%.AppImage"');
  for(const unsafe of ['/a"b','/a$b','/a`b','/a\\b','/a\nb',''])assert.throws(()=>execArgument(unsafe),/cannot be used|Invalid/);
  assert.throws(()=>autostartEntry({command:[]}),/Invalid/);
  assert.equal(setAutostart(false,{env}),false);assert.equal(fs.existsSync(file),false);assert.equal(setAutostart(false,{env}),false);
  fs.writeFileSync(file,'[Desktop Entry]\nExec=someone-else\n');assert.throws(()=>setAutostart(true,{env,command:['/x']}),/already exists/);assert.throws(()=>setAutostart(false,{env}),/already exists/);
  assert.equal(fs.readFileSync(file,'utf8'),'[Desktop Entry]\nExec=someone-else\n');
  fs.unlinkSync(file);fs.symlinkSync(path.join(root,'elsewhere'),file);assert.throws(()=>setAutostart(true,{env,command:['/x']}),/regular file/);
  assert.equal(fs.readdirSync(path.dirname(file)).length,1,'no temporary entry is left behind');
});
test('link exports use each operating system native link file type',()=>{
  assert.deepEqual(linkFile('https://example.com/a?b=1',{platform:'win32'}),{extension:'.url',bytes:'[InternetShortcut]\r\nURL=https://example.com/a?b=1\r\n'});
  assert.deepEqual(linkFile('https://example.com/a?b=1',{platform:'linux'}),{extension:'.desktop',bytes:'[Desktop Entry]\nType=Link\nName=example.com\nURL=https://example.com/a?b=1\nIcon=text-html\n'});
  assert.throws(()=>linkFile('https://example.com/\nExec=x',{platform:'linux'}),/Invalid link/);
  assert.match(linkFile('https://example.com/?q=a\\nb',{platform:'linux'}).bytes,/^URL=https:\/\/example\.com\/\?q=a\\\\nb$/m,'a backslash in the URL stays a backslash, not a newline');
  assert.equal(linkFile('https://example.com/?q=a\\nb',{platform:'win32'}).bytes,'[InternetShortcut]\r\nURL=https://example.com/?q=a\\nb\r\n','Windows .url bytes are unchanged');
});
function fakeExec(responses){
  const calls=[];
  const exec=(file,args,_options,done)=>{calls.push([file,...args]);const value=responses(args);const child=new EventEmitter();child.kill=()=>{};setImmediate(()=>value instanceof Error?done(value,''):done(null,value+'\n'));return child;};
  return{calls,exec};
}
test('X11 paste re-activates and pastes only into the captured window while it is still active',async()=>{
  let active='4242';
  const fake=fakeExec(args=>args[0]==='getactivewindow'?active:args[0]==='getwindowpid'?'777':'');
  const native=createLinuxNative({session:{session:'x11',backend:'x11',desktop:'xfce'},tools:{xdotool:'/usr/bin/xdotool'},ownPID:1,exec:fake.exec});
  const target=await native.capture();assert.deepEqual(target,{handle:'4242',processId:777});
  await native.restore(target);assert.deepEqual(fake.calls.at(-1),['/usr/bin/xdotool','windowactivate','--sync','4242']);
  assert.deepEqual(await native.paste(target),{pasted:true});assert.deepEqual(fake.calls.at(-1),['/usr/bin/xdotool','key','--clearmodifiers','ctrl+v']);
  active='9';const count=fake.calls.length;await assert.rejects(native.paste(target),/no longer active/);assert.equal(fake.calls.length,count+1,'no keystroke after a focus change');
  assert.deepEqual(await native.paste(null),{pasted:false});
  const own=createLinuxNative({session:{session:'x11',backend:'x11'},tools:{xdotool:'/usr/bin/xdotool'},ownPID:777,exec:fake.exec});assert.equal(await own.capture(),null,'ClipBoardLine never targets itself');
});
test('the Wayland fallback reads the clipboard only while focused, but X11 polling stays in the background',async()=>{
  const start=backend=>{let focused=false,reads=0;const native=createLinuxNative({session:{session:backend,backend},tools:{},clipboard:{read:async()=>{reads++;return[];}},focused:()=>focused,ownPID:1});const monitor=native.monitor(()=>{});return{native,monitor,reads:()=>reads,focus:value=>{focused=value;}};};
  const wayland=start('wayland');await wayland.native.clipboardSequence();assert.equal(wayland.reads(),0,'unfocused Wayland polling reads nothing');
  wayland.focus(true);await wayland.native.clipboardSequence();assert.equal(wayland.reads(),1,'focus enables the fallback');wayland.monitor.kill();
  const x11=start('x11');await x11.native.clipboardSequence();assert.equal(x11.reads(),1,'X11 keeps polling without focus');x11.monitor.kill();
});
test('Wayland never injects input and reports which optional packages are missing',async()=>{
  const native=createLinuxNative({session:{session:'wayland',backend:'wayland',desktop:'kde'},tools:{'wl-paste':null,'wl-copy':null,xdotool:'/usr/bin/xdotool',ffmpeg:null,ffprobe:null,gdbus:'/usr/bin/gdbus'},clipboard:{read:async()=>[]},focused:()=>true,ownPID:1});
  assert.equal(await native.capture(),null);assert.deepEqual(await native.paste({handle:'5',processId:5}),{pasted:false});
  const monitor=native.monitor(()=>{});
  const status=native.status();assert.deepEqual(status.missing,['wl-clipboard','ffmpeg']);assert.equal(status.automaticPaste,false);assert.equal(status.clipboardMonitor,'focused-polling');assert.equal(status.screenshot,'portal');assert.match(status.problem,/wl-clipboard/);
  assert.equal(native.clipboardReader('electron'),'electron');assert.equal(await native.clipboardSequence(),2,'a query observes the current selection');assert.equal(await native.clipboardSequence(),2,'an unchanged selection keeps its sequence');monitor.kill();
  const targets=new LinuxPasteTargets(10);assert.equal(targets.capture({handle:'0',processId:5}),null);assert.equal(targets.capture({handle:'12',processId:10}),null);
  assert.deepEqual(targets.capture({handle:'12',processId:11,extra:'dropped'}),{handle:'12',processId:11});assert.deepEqual(targets.reenter(),{handle:'12',processId:11});targets.clear();assert.equal(targets.reenter(),null);
});
test('a Wayland watcher failure falls back to focused polling and is reported as recoverable',()=>{
  const children=[];
  const native=createLinuxNative({session:{session:'wayland',backend:'wayland'},tools:{'wl-paste':'wl-paste','wl-copy':'wl-copy',ffmpeg:'f',ffprobe:'p',gdbus:'g'},clipboard:{read:async()=>[]},options:()=>({text:true,images:true}),spawner:(_file,args)=>{const child=new EventEmitter();child.stdout=new EventEmitter();child.stderr=new EventEmitter();child.args=args;child.kill=()=>{};children.push(child);return child;},ownPID:1});
  const failures=[],changes=[];const monitor=native.monitor(value=>changes.push(value),error=>failures.push(error));
  assert.equal(children.length,2);assert.equal(native.status().clipboardMonitor,'wl-clipboard');assert.notEqual(native.clipboardReader('electron'),'electron');
  children[0].stdout.emit('data',Buffer.from('clipboardline-change\n'));assert.deepEqual(changes,[2]);
  children[0].stderr.emit('data',Buffer.from('Watch mode requires a compositor that supports the wlroots data-control protocol'));children[0].emit('exit',1);
  assert.equal(failures.length,1);assert.equal(failures[0].recoverable,true);assert.equal(native.status().clipboardMonitor,'focused-polling');assert.equal(native.clipboardReader('electron'),'electron');
  assert.deepEqual(native.status().missing,[]);monitor.kill();
});
test('an empty selection is told apart from one whose owner is still running',async()=>{
  // X11: Electron reads no formats once the owner has quit.
  let formats=['TARGETS','image/png'];
  const x11=createLinuxNative({session:{session:'x11',backend:'x11'},tools:{xdotool:null},clipboard:{read:async()=>[{types:formats}]},ownPID:1});
  assert.equal(await x11.clipboardEmpty(),false);formats=[];assert.equal(await x11.clipboardEmpty(),true);
  // Wayland: wl-paste reports "Nothing is copied" once the owner has quit.
  let owned=true;const run=async(_file,args)=>{if(!args.includes('--list-types'))throw new Error('unexpected read');if(owned)return Buffer.from('image/png\nx-kde-force-image-copy\n');throw Object.assign(new Error('Nothing is copied'),{empty:true});};
  const wayland=createLinuxNative({session:{session:'wayland',backend:'wayland'},tools:{'wl-paste':'wl-paste','wl-copy':'wl-copy'},clipboard:{read:async()=>[]},options:()=>({text:true,images:true}),run,spawner:()=>{const child=new EventEmitter();child.stdout=new EventEmitter();child.stderr=new EventEmitter();child.kill=()=>{};return child;},ownPID:1});
  const monitor=wayland.monitor(()=>{});
  assert.equal(await wayland.clipboardEmpty(),false);owned=false;assert.equal(await wayland.clipboardEmpty(),true);monitor.kill();
});
test('X11 reads go through xclip when it is installed and its absence is reported',async()=>{
  const run=async(_file,args)=>{if(args.includes('TARGETS'))return Buffer.from('TIMESTAMP\nTARGETS\nUTF8_STRING\n');return Buffer.from('7\n');};
  const withXclip=createLinuxNative({session:{session:'x11',backend:'x11'},tools:{xclip:'/usr/bin/xclip',xdotool:'/usr/bin/xdotool'},clipboard:{read:async()=>{throw new Error('Electron must not be read');}},run,ownPID:1});
  const monitor=withXclip.monitor(()=>{});
  assert.equal(withXclip.clipboardReader('electron').constructor.name,'X11Clipboard');assert.equal(await withXclip.clipboardEmpty(),false);assert.equal(await withXclip.clipboardSequence(),2,'the change signature is read through xclip');
  assert.deepEqual(withXclip.status().missing.filter(name=>name==='xclip'),[]);monitor.kill();
  const without=createLinuxNative({session:{session:'x11',backend:'x11'},tools:{xdotool:'/usr/bin/xdotool'},clipboard:{read:async()=>[]},ownPID:1});
  const fallback=without.monitor(()=>{});assert.equal(without.clipboardReader('electron'),'electron');assert.ok(without.status().missing.includes('xclip'));fallback.kill();
});
test('removing the package unregisters the command, but an rpm or deb upgrade keeps the new one',t=>{
  const root=temporary(t),bin=path.join(root,'bin'),calls=path.join(root,'calls'),script=path.join(root,'after-remove'),profile=path.join(root,'apparmor-profile');fs.mkdirSync(bin);
  fs.writeFileSync(path.join(bin,'update-alternatives'),'#!/bin/sh\necho "$@" >> "$CALLS"\n',{mode:0o755});
  // The script must never touch this machine's real AppArmor profile.
  fs.writeFileSync(path.join(bin,'apparmor_status'),'#!/bin/sh\nexit 1\n',{mode:0o755});
  // electron-builder fills the two macros when it packages the script.
  const values={executable:'clipboardline',sanitizedProductName:'ClipBoardLine'};
  fs.writeFileSync(script,fs.readFileSync(path.join(__dirname,'../scripts/linux-after-remove.sh'),'utf8').replace(/\$\{([a-zA-Z]+)\}/g,(_match,key)=>values[key]).replace("'/etc/apparmor.d/clipboardline'",()=>`'${profile}'`));
  const run=argument=>{fs.rmSync(calls,{force:true});execFileSync('bash',[script,argument],{env:{...process.env,PATH:bin+path.delimiter+process.env.PATH,CALLS:calls}});return fs.existsSync(calls)?fs.readFileSync(calls,'utf8').trim():'';};
  fs.writeFileSync(profile,'');
  for(const upgrade of ['1','2','upgrade','failed-upgrade','abort-upgrade']){assert.equal(run(upgrade),'','an upgrade keeps the command: '+upgrade);assert.equal(fs.existsSync(profile),true,'an upgrade keeps the profile: '+upgrade);}
  for(const removal of ['0','remove','purge']){fs.writeFileSync(profile,'');assert.equal(run(removal),'--remove clipboardline /opt/ClipBoardLine/clipboardline','removal unregisters it: '+removal);assert.equal(fs.existsSync(profile),false,'removal deletes the profile: '+removal);}
});
test('a library saved by an early Linux build with the removed full-screen preference still opens',t=>{
  const {Store,DEFAULTS}=require('../lib/model.cjs'),directory=path.join(temporary(t),'data');fs.mkdirSync(directory,{mode:0o700});
  fs.writeFileSync(path.join(directory,'library.json'),JSON.stringify({schema:1,items:[],folders:[],settings:{...DEFAULTS,lineFullScreen:true,sounds:true}}));
  const store=new Store(directory);
  assert.equal(Object.hasOwn(store.data.settings,'lineFullScreen'),false);assert.equal(store.data.settings.sounds,true,'other saved preferences are kept');
});
