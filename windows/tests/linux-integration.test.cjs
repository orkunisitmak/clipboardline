'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {commandFromArgv,setAutostart,autostartFile,quoteExec,linkFile,screenshot,configurePlatform,LINUX_DEFAULT_SETTINGS}=require('../lib/linux-integration.cjs');
const {inspectFields}=require('../lib/linux-media.cjs');
const {PasteTargetTracker}=require('../lib/paste-target.cjs');
const {Store}=require('../lib/model.cjs');

test('desktop shortcut commands map to shelf actions and ignore unrelated arguments',()=>{
 assert.equal(commandFromArgv(['/opt/ClipBoardLine/clipboardline','--toggle']),'toggle');
 assert.equal(commandFromArgv(['app','--no-sandbox','--copy-latest']),'copyLatest');
 assert.equal(commandFromArgv(['app','--test-mode','--toggle=1']),null);
});
test('XDG autostart entry is written, quoted and removed',()=>{
 const home=fs.mkdtempSync(path.join(os.tmpdir(),'clipboardline-xdg-')),environment={XDG_CONFIG_HOME:home};
 try{
  setAutostart(true,{executable:'/opt/Clip Board/clipboardline',environment});
  const text=fs.readFileSync(autostartFile(environment),'utf8');
  assert.match(text,/^\[Desktop Entry\]\nType=Application\n/);assert.match(text,/\nExec="\/opt\/Clip Board\/clipboardline"\n/);
  setAutostart(false,{environment});assert.equal(fs.existsSync(autostartFile(environment)),false);
  setAutostart(false,{environment});
 }finally{fs.rmSync(home,{recursive:true,force:true});}
 assert.equal(quoteExec('/usr/bin/clipboardline'),'/usr/bin/clipboardline');assert.equal(quoteExec('/a/$b"c'),'"/a/\\$b\\"c"');
});
test('exported links use a freedesktop Link entry',()=>{
 assert.equal(linkFile('https://example.com/a?b=1'),'[Desktop Entry]\nType=Link\nName=example.com\nURL=https://example.com/a?b=1\nIcon=text-html\n');
});
test('screenshots use the first desktop tool that writes a PNG and always remove temporary files',async()=>{
 const directory=fs.mkdtempSync(path.join(os.tmpdir(),'clipboardline-shot-test-'));const used=[];
 try{
  const png=Buffer.concat([Buffer.from('89504e470d0a1a0a','hex'),Buffer.alloc(80)]);
  const run=async(tool,args)=>{used.push(tool);if(tool==='spectacle')throw new Error('no portal');fs.writeFileSync(args[args.length-1],png);return Buffer.alloc(0);};
  const bytes=await screenshot({run,find:name=>['spectacle','grim'].includes(name)?name:null,directory});
  assert.deepEqual(used,['spectacle','grim']);assert.ok(bytes.equals(png));assert.deepEqual(fs.readdirSync(directory),[]);
  assert.equal(await screenshot({run,find:()=>null,directory}),null);
 }finally{fs.rmSync(directory,{recursive:true,force:true});}
});
test('a Wayland session runs natively unless XWayland is explicitly requested',()=>{
 const app=()=>{const switches=new Map();return{switches,commandLine:{hasSwitch:name=>switches.has(name),getSwitchValue:name=>switches.get(name)||'',appendSwitch:(name,value)=>switches.set(name,value)}};};
 let a=app();assert.equal(configurePlatform(a,{argv:[],environment:{WAYLAND_DISPLAY:'wayland-0',DISPLAY:':0'}}),'wayland');
 assert.equal(a.switches.get('ozone-platform'),'wayland');assert.equal(a.switches.get('enable-features'),'GlobalShortcutsPortal');
 a=app();a.switches.set('ozone-platform','x11');assert.equal(configurePlatform(a,{argv:[],environment:{WAYLAND_DISPLAY:'wayland-0',DISPLAY:':0'}}),'wayland','a pre-resolved switch is not a user choice');
 a=app();assert.equal(configurePlatform(a,{argv:[],environment:{WAYLAND_DISPLAY:'wayland-0',DISPLAY:':0',CLIPBOARDLINE_OZONE_PLATFORM:'x11'}}),'x11');assert.equal(a.switches.has('enable-features'),false);
 a=app();assert.equal(configurePlatform(a,{argv:['--ozone-platform=x11'],environment:{WAYLAND_DISPLAY:'wayland-0'}}),'x11');assert.equal(a.switches.has('ozone-platform'),false);
 a=app();assert.equal(configurePlatform(a,{argv:[],environment:{DISPLAY:':0'}}),'auto','an X11 session needs no override');assert.equal(a.switches.size,0);
});
test('FFmpeg metadata keeps display orientation and ignores cover art',()=>{
 const probe={format:{duration:'6.0005'},streams:[{codec_type:'video',codec_name:'mjpeg',width:10,height:10,disposition:{attached_pic:1}},{codec_type:'video',codec_name:'h264',width:1920,height:1080,side_data_list:[{rotation:-90}]},{codec_type:'audio'},{codec_type:'audio'}]};
 assert.deepEqual(inspectFields(probe),{durationMs:6000.5,width:1080,height:1920,videoCodec:'H264',audioTracks:2});
 assert.throws(()=>inspectFields({streams:[{codec_type:'audio'}]}),/no video track/);
});
test('compositor paste targets are accepted only when the Linux bridge enables them',()=>{
 const target={handle:'0',processId:0,runtime:'',editable:true,secure:false,compositor:true};
 assert.equal(new PasteTargetTracker(100).capture(target),null);
 const linux=new PasteTargetTracker(100,{compositorTargets:true});
 assert.deepEqual({...linux.capture(target)},target);assert.deepEqual({...linux.resolve(target)},target);
 assert.equal(linux.capture({...target,secure:true}),null);
 assert.equal(linux.capture({handle:'42',processId:100,runtime:'42',editable:true,secure:false}),null,'own window is never a destination');
});
test('Linux default shortcuts apply to new profiles without overriding saved choices',()=>{
 const directory=fs.mkdtempSync(path.join(os.tmpdir(),'clipboardline-defaults-'));
 try{
  const fresh=new Store(directory,{defaultSettings:LINUX_DEFAULT_SETTINGS});
  assert.equal(fresh.data.settings.shortcuts.toggle,'Control+Alt+V');assert.equal(fresh.data.settings.shortcuts.search,'Control+Alt+S');
  fresh.modify('setSettings',{patch:{shortcuts:{toggle:'Control+Alt+T'}}});
  assert.equal(new Store(directory,{defaultSettings:LINUX_DEFAULT_SETTINGS}).data.settings.shortcuts.toggle,'Control+Alt+T');
  assert.equal(new Store(fs.mkdtempSync(path.join(directory,'plain-'))).data.settings.shortcuts.toggle,'Control+Alt+T');
  if(process.platform==='linux')assert.equal(fs.statSync(directory).mode&0o777,0o700);
 }finally{fs.rmSync(directory,{recursive:true,force:true});}
});
test('accelerators map to Qt key codes for Plasma shortcuts',()=>{
 const {qtKey}=require('../lib/linux-integration.cjs');
 assert.equal(qtKey('Control+Alt+V'),0x0C000056);assert.equal(qtKey('Ctrl+Shift+F5'),(0x04000000|0x02000000|0x01000034)>>>0);
 assert.equal(qtKey('Control+Alt+Space'),0x0C000020);assert.equal(qtKey('Super+ArrowLeft'),(0x10000000|0x01000012)>>>0);
 assert.equal(qtKey('Control++'),0x0400002b);assert.equal(qtKey('Control+V+X'),null);assert.equal(qtKey('Control+'),null);assert.equal(qtKey('Hyper+V'),null);
});
test('the Plasma registry registers through kglobalaccel, rejects conflicts and dispatches presses',()=>{
 const {KdeShortcutRegistry}=require('../lib/linux-integration.cjs');const {EventEmitter}=require('node:events');
 const calls=[];let available=true;const monitor=new EventEmitter();monitor.stdout=new EventEmitter();monitor.kill=()=>{};
 const call=(method,args)=>{calls.push([method,...args]);if(method==='isGlobalShortcutAvailable')return '('+available+',)\n';if(method==='setShortcut')return '('+args[1]+',)\n';return '()\n';};
 const stale=[];const componentCall=method=>{assert.equal(method,'shortcutNames');return "(['Control+Alt+T', 'Control+Alt+V'],)\n";};
 const registry=new KdeShortcutRegistry({call,componentCall,spawnMonitor:(file,args)=>{assert.equal(args.at(-1),'/component/clipboardline');return monitor;}});
 let pressed=0;assert.equal(registry.register('Control+Alt+V',()=>pressed++),true);
 assert.deepEqual(calls.slice(0,3),[['unregister','clipboardline','Control+Alt+T'],['unregister','clipboardline','Control+Alt+V'],['isGlobalShortcutAvailable','201326678','clipboardline']],'stale registrations from a killed instance are removed first');
 registry.register('Control+Alt+S',()=>{});assert.equal(calls.filter(value=>value[0]==='unregister').length,2,'stale cleanup runs once');
 assert.deepEqual(calls.find(value=>value[0]==='setShortcut'),['setShortcut','["clipboardline","Control+Alt+V","ClipBoardLine","Control+Alt+V"]','[201326678]','6']);
 monitor.stdout.emit('data',Buffer.from("/component/clipboardline: org.kde.kglobalaccel.Component.globalShortcutPressed ('clipboardline', 'Control+Alt+V', int64 0)\n/component/clipboardline: org.kde.kglobalaccel.Component.globalShortcutReleased ('clipboardline', 'Control+Alt+V', int64 0)\n"));
 assert.equal(pressed,1);
 available=false;assert.equal(registry.register('Control+Alt+T',()=>{}),false,'a binding owned by another app is rejected');
 assert.equal(registry.register('Control+Hyper',()=>{}),false);
 registry.dispose();assert.ok(calls.some(value=>value[0]==='unregister'&&value[2]==='Control+Alt+V'));
 monitor.stdout.emit('data',Buffer.from("x.globalShortcutPressed ('clipboardline', 'Control+Alt+V', int64 0)\n"));assert.equal(pressed,1);
});
test('Plasma Wayland selects kglobalaccel while X11 and other desktops keep Electron registration',()=>{
 const {shortcutRegistry}=require('../lib/linux-integration.cjs');const electron={register(){}};const fake={call:()=>'(true,)',component:'clipboardline'};
 let options;assert.equal(shortcutRegistry(electron,{environment:{WAYLAND_DISPLAY:'w',XDG_CURRENT_DESKTOP:'KDE'},find:()=>'/usr/bin/gdbus',component:'clipboardline-dev',create:value=>{options=value;return fake;}}),fake);
 assert.deepEqual(options,{component:'clipboardline-dev'},'each profile kind registers under its own component');
 assert.equal(shortcutRegistry(electron,{environment:{DISPLAY:':0',XDG_CURRENT_DESKTOP:'KDE'},find:()=>'/usr/bin/gdbus',create:()=>fake}),electron);
 assert.equal(shortcutRegistry(electron,{environment:{WAYLAND_DISPLAY:'w',XDG_CURRENT_DESKTOP:'ubuntu:GNOME'},find:()=>'/usr/bin/gdbus',create:()=>fake}),electron);
 assert.equal(shortcutRegistry(electron,{environment:{WAYLAND_DISPLAY:'w',XDG_CURRENT_DESKTOP:'KDE'},find:()=>'/usr/bin/gdbus',create:()=>({call:()=>{throw new Error('no daemon');}})}),electron);
});
test('pacman optdepends are inserted after depends and the .MTREE digest follows the new .PKGINFO',()=>{
 const {withOptionalDepends,withPkginfoDigest}=require('../scripts/pacman-optdepends.cjs');const crypto=require('node:crypto');
 const pkginfo=withOptionalDepends('pkgname = x\ndepend = gtk3\ndepend = nss\noptdepend = stale: old\nlicense = MIT\n',['wl-clipboard: Wayland clipboard','ffmpeg: recordings']);
 assert.equal(pkginfo,'pkgname = x\ndepend = gtk3\ndepend = nss\noptdepend = wl-clipboard: Wayland clipboard\noptdepend = ffmpeg: recordings\nlicense = MIT\n');
 const bytes=Buffer.from(pkginfo);
 const mtree=withPkginfoDigest('#mtree\n./.INSTALL time=1 size=4 md5digest=aa sha256digest=bb\n./.PKGINFO time=1.5 size=10 md5digest=00 sha256digest=11\n',bytes);
 assert.equal(mtree.split('\n')[2],'./.PKGINFO time=1.5 size='+bytes.length+' md5digest='+crypto.createHash('md5').update(bytes).digest('hex')+' sha256digest='+crypto.createHash('sha256').update(bytes).digest('hex'));
 assert.match(mtree,/\.\/\.INSTALL time=1 size=4 md5digest=aa sha256digest=bb/);
 assert.throws(()=>withPkginfoDigest('#mtree\n',bytes),/no \.PKGINFO entry/);
});
test('delay rejects a pre-aborted signal and never accumulates abort listeners',async()=>{
 const {delay}=require('../lib/linux-desktop.cjs');const {getEventListeners}=require('node:events');
 const aborted=new AbortController();aborted.abort();
 await assert.rejects(delay(1000,aborted.signal),{name:'AbortError'});
 const controller=new AbortController();
 for(let index=0;index<60;index++)await delay(0,controller.signal);
 assert.equal(getEventListeners(controller.signal,'abort').length,0);
 const pending=delay(1000,controller.signal);assert.equal(getEventListeners(controller.signal,'abort').length,1);
 controller.abort();await assert.rejects(pending,{name:'AbortError'});
});
