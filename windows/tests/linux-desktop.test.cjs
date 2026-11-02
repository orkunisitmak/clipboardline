'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {LinuxDesktop,session,handleFor,backendRelaunchArguments,launchCommand,RELAUNCHED}=require('../lib/linux-desktop.cjs');
const {LinuxClipboard,ClipboardWatcher,backend,keptImage,pixelFingerprint,decodableJPEG,clipboardSignature,writeClipboard,fileClipboard,ownerCommand,FORMAT_MAP,MARKER_TYPE}=require('../lib/linux-clipboard.cjs');
const {readClipboardContent}=require('../lib/clipboard-policy.cjs');
const {setAutostart,autostartEnabled,autostartEntry}=require('../lib/linux-autostart.cjs');
const {PasteTargetTracker}=require('../lib/paste-target.cjs');
const {parseResponse,screenshotPath,portalScreenshot}=require('../lib/linux-screenshot.cjs');
const {EventEmitter}=require('node:events');
const linuxOnly={skip:process.platform==='win32'&&'Linux paths'};
function temporary(t){const root=fs.mkdtempSync(path.join(os.tmpdir(),'clipboardline-linux-desktop-'));t.after(()=>fs.rmSync(root,{recursive:true,force:true}));return root;}

test('only the matching portal request response is accepted and its file URI is decoded',linuxOnly,t=>{
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
test('the portal is called only after the signal subscription is confirmed',linuxOnly,async t=>{
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

test('only a captured still image still on the shelf is served again',()=>{
  const image={id:'a',kind:'image'};
  assert.equal(keptImage('a',[image]),image);
  assert.equal(keptImage('a',[]),null,'deleted');
  assert.equal(keptImage('a',[{...image,trashedAt:1}]),null,'trashed');
  assert.equal(keptImage('a',[{...image,hiddenFromShelf:true}]),null,'off the shelf');
  assert.equal(keptImage('a',[{...image,recording:{}}]),null,'recording');
  assert.equal(keptImage('a',[{id:'a',kind:'text'}]),null,'text stays cleared');
  assert.equal(keptImage('a',[{id:'a',kind:'link'}]),null,'links stay cleared');
});
test('Mutter desktops use Xwayland for clipboard capture and other sessions stay native',()=>{
  const gnome={XDG_CURRENT_DESKTOP:'ubuntu:GNOME',WAYLAND_DISPLAY:'wayland-0',DISPLAY:':0'};
  assert.equal(session(gnome,[]).backend,'x11');assert.equal(session(gnome,[]).type,'wayland');
  assert.equal(session({...gnome,DISPLAY:''},[]).backend,'wayland','no Xwayland: stay native');
  assert.equal(session({...gnome,XDG_CURRENT_DESKTOP:'KDE'},[]).backend,'wayland');
  assert.equal(session(gnome,['--ozone-platform=wayland']).backend,'wayland','an explicit choice wins');
  assert.equal(session({...gnome,XDG_CURRENT_DESKTOP:'KDE',CLIPBOARDLINE_DISPLAY_BACKEND:'x11'},[]).backend,'x11');
  assert.equal(session({DISPLAY:':0'},[]).backend,'x11');
  const tools=name=>['wl-paste','wl-copy','xclip'].includes(name);
  assert.equal(backend({environment:gnome,find:tools}),'wayland');assert.equal(backend({environment:gnome,find:tools,display:'x11'}),'x11');
});
test('only an Xwayland choice on a Wayland session relaunches, and it keeps the original arguments once',()=>{
  const xwayland={type:'wayland',backend:'x11'};
  assert.deepEqual(backendRelaunchArguments(xwayland,['--toggle']),['--toggle','--ozone-platform=x11']);
  assert.equal(backendRelaunchArguments(xwayland,['--toggle','--ozone-platform=x11']),null);
  assert.equal(backendRelaunchArguments({type:'wayland',backend:'wayland'},[]),null);
  assert.equal(backendRelaunchArguments({type:'x11',backend:'x11'},[]),null);
});

function desktop(environment,tools,responses,{ownPID=4242}={}){
  const calls=[];
  const value=new LinuxDesktop({environment,ownPID,find:name=>tools.includes(name)?'/usr/bin/'+name:null,sleep:async()=>{},
    run:async(file,args)=>{calls.push([file,...args]);const key=[file,...args].join(' ');const response=typeof responses==='function'?responses(key,args):responses[key];if(response instanceof Error)throw response;return response??'';}});
  return{value,calls};
}

test('session detection distinguishes compositors and display servers',()=>{
  assert.deepEqual(session({WAYLAND_DISPLAY:'wayland-1',XDG_CURRENT_DESKTOP:'KDE'}),{type:'wayland',compositor:'kde',backend:'wayland'});
  assert.deepEqual(session({WAYLAND_DISPLAY:'wayland-1',HYPRLAND_INSTANCE_SIGNATURE:'x'}),{type:'wayland',compositor:'hyprland',backend:'wayland'});
  assert.deepEqual(session({WAYLAND_DISPLAY:'wayland-1',SWAYSOCK:'/run/sway'}),{type:'wayland',compositor:'sway',backend:'wayland'});
  assert.deepEqual(session({DISPLAY:':0',XDG_CURRENT_DESKTOP:'XFCE'}),{type:'x11',compositor:'other',backend:'x11'});
  assert.deepEqual(session({}),{type:'none',compositor:'other',backend:'none'});
});

test('X11 capture yields a paste-target identity accepted by the shared tracker and pastes with xdotool',async()=>{
  const {value,calls}=desktop({DISPLAY:':0'},['xdotool'],{'xdotool getactivewindow':'71303175\n','xdotool getwindowpid 71303175':'900\n'});
  const target=await value.capture();
  const tracker=new PasteTargetTracker(4242),resolved=tracker.resolve(tracker.capture(target));
  assert.ok(resolved&&resolved.editable&&!resolved.secure);assert.equal(resolved.processId,900);assert.equal(resolved.handle,handleFor('71303175'));
  await value.preparePaste(resolved);await value.validatePaste(resolved);await value.paste(resolved);
  assert.deepEqual(calls.filter(call=>call[1]!=='getactivewindow'&&call[1]!=='getwindowpid'),[['xdotool','windowactivate','--sync','71303175'],['xdotool','key','--clearmodifiers','ctrl+v']]);
});

test('own window and missing windows are never captured as paste destinations',async()=>{
  assert.equal(await desktop({DISPLAY:':0'},['xdotool'],{'xdotool getactivewindow':'5','xdotool getwindowpid 5':'4242'}).value.capture(),null);
  assert.equal(await desktop({DISPLAY:':0'},[],{}).value.capture(),null);
});

test('a different focused window vetoes paste before any key is sent',async()=>{
  let active='10';
  const {value,calls}=desktop({DISPLAY:':0'},['xdotool'],key=>key==='xdotool getactivewindow'?active:key.startsWith('xdotool getwindowpid')?'900':'');
  const target=await value.capture();active='11';
  await assert.rejects(value.preparePaste(target),/Another window became active/);
  await assert.rejects(value.validatePaste(target),/Focus changed before paste/);
  await assert.rejects(value.paste(target),/No keys were sent/);
  assert.equal(calls.some(call=>call[1]==='key'),false);
});

test('Hyprland and Sway restore the exact captured window through their IPC',async()=>{
  const hypr=desktop({WAYLAND_DISPLAY:'w',HYPRLAND_INSTANCE_SIGNATURE:'s'},['hyprctl','wtype'],{'hyprctl -j activewindow':JSON.stringify({address:'0x55d1',pid:77})});
  const target=await hypr.value.capture();await hypr.value.restore(target);await hypr.value.paste(target);
  assert.deepEqual(hypr.calls.filter(call=>call[1]!=='-j'),[['hyprctl','dispatch','focuswindow','address:0x55d1'],['wtype','-M','ctrl','v','-m','ctrl']]);
  const tree={nodes:[{nodes:[{id:31,pid:88,focused:true}]}]};
  const sway=desktop({WAYLAND_DISPLAY:'w',SWAYSOCK:'/s'},['swaymsg','ydotool'],{'swaymsg -t get_tree -r':JSON.stringify(tree)});
  await sway.value.restore(await sway.value.capture());
  assert.deepEqual(sway.calls.at(-1),['swaymsg','[con_id=31]','focus']);
});

test('Wayland desktops without a window API rely on compositor focus return and ydotool',async()=>{
  const {value,calls}=desktop({WAYLAND_DISPLAY:'w',XDG_CURRENT_DESKTOP:'GNOME'},['ydotool'],{});
  const target=await value.capture();assert.ok(target.editable);
  await value.restore(target);await value.validatePaste(target);await value.paste(target);
  assert.deepEqual(calls,[['ydotool','key','29:1','47:1','47:0','29:0']]);
  assert.equal(await desktop({WAYLAND_DISPLAY:'w',XDG_CURRENT_DESKTOP:'GNOME'},[],{}).value.capture(),null);
});

test('cancel during validation prevents the later paste',async()=>{
  const {value}=desktop({WAYLAND_DISPLAY:'w',XDG_CURRENT_DESKTOP:'GNOME'},['ydotool'],{});
  const target=await value.capture();value.sleep=async()=>value.cancel();
  await assert.rejects(value.validatePaste(target),/canceled/);
  await assert.rejects(value.restore({handle:'1'}),/No previous application/);
});

function clipboard(kind,data){
  const calls=[];
  const value=new LinuxClipboard({kind,convertImage:bytes=>Buffer.concat([Buffer.from('png:'),bytes]),runner:async(file,args)=>{
    calls.push([file,...args]);const listing=args.includes('--list-types')||args.includes('TARGETS');
    if(listing)return Buffer.from(Object.keys(data).join('\n'));
    const type=args[args.indexOf(kind==='wayland'?'--type':'-t')+1];if(!(type in data))throw Object.assign(new Error('missing'),{exitCode:1});return Buffer.from(data[type]);
  }});
  return{value,calls};
}

test('clipboard read normalizes native text and image types and keeps native names for privacy markers',async()=>{
  const {value}=clipboard('wayland',{'UTF8_STRING':'hello','x-kde-passwordManagerHint':'secret'});
  const [entry]=await value.read();
  assert.ok(entry.types.includes('text/plain')&&entry.types.includes('x-kde-passwordManagerHint'));
  assert.equal(Buffer.from(await(await entry.getType('text/plain')).arrayBuffer()).toString(),'hello');
  const {privateClipboard}=require('../lib/clipboard-policy.cjs');assert.equal(privateClipboard(entry.types),true);
  const image=clipboard('x11',{'image/jpeg':'J'});const [picture]=await image.value.read();
  assert.equal(Buffer.from(await(await picture.getType('image/png')).arrayBuffer()).toString(),'png:J');
  assert.deepEqual(image.calls[0],['xclip','-selection','clipboard','-t','TARGETS','-o']);
  assert.deepEqual(await clipboard('wayland',{}).value.read(),[]);
});

test('polling watcher advances the sequence only when the clipboard digest changes',async()=>{
  const data={'text/plain':'a'},{value}=clipboard('x11',data),changes=[];
  const watcher=new ClipboardWatcher(value,{changed:sequence=>changes.push(sequence),interval:5}).start();
  const wait=()=>new Promise(resolve=>setTimeout(resolve,30));
  await wait();assert.equal(watcher.read(),1);data['text/plain']='b';await wait();watcher.kill();
  assert.deepEqual(changes,[2]);assert.equal(watcher.read(),2);
});

test('XDG autostart is written, quoted and removed without touching an entry it does not own',()=>{
  const home=fs.mkdtempSync(path.join(os.tmpdir(),'clipboardline-autostart-')),env={XDG_CONFIG_HOME:home},command=['/home/u/Clip Board/App.AppImage','--hidden'];
  try{
    const file=path.join(home,'autostart','clipboardline.desktop');
    assert.equal(setAutostart(true,{command,env}),true);assert.equal(autostartEnabled(env),true);
    assert.match(fs.readFileSync(file,'utf8'),/^Exec="\/home\/u\/Clip Board\/App\.AppImage" --hidden$/m);
    assert.equal(setAutostart(false,{env}),false);assert.equal(fs.existsSync(file),false);
    fs.writeFileSync(file,'[Desktop Entry]\nExec=mine\n');
    assert.throws(()=>setAutostart(true,{command,env}),/already exists/);assert.throws(()=>setAutostart(false,{env}),/already exists/);
    assert.equal(fs.readFileSync(file,'utf8'),'[Desktop Entry]\nExec=mine\n');
    fs.unlinkSync(file);fs.symlinkSync('/etc/hostname',file);
    assert.throws(()=>setAutostart(true,{command,env}),/not a regular file/);
    assert.match(autostartEntry({command:['/a%b']}),/^Exec=\/a%%b$/m);assert.throws(()=>autostartEntry({command:['/a"b']}),/cannot be used/);
  }finally{fs.rmSync(home,{recursive:true,force:true});}
});

test('a relaunch and autostart use this AppImage only while the app runs from its mount, and relaunch once',()=>{
  const own={APPIMAGE:'/home/u/ClipBoardLine.AppImage',APPDIR:'/tmp/.mount_Clip1'};
  assert.deepEqual(launchCommand({environment:own,execPath:'/tmp/.mount_Clip1/clipboardline',packaged:true}),[own.APPIMAGE]);
  assert.deepEqual(launchCommand({environment:own,execPath:'/opt/ClipBoardLine/clipboardline',packaged:true}),['/opt/ClipBoardLine/clipboardline']);
  assert.deepEqual(launchCommand({environment:{},execPath:'/usr/bin/electron',packaged:false,appPath:'/src/windows'}),['/usr/bin/electron','/src/windows']);
  assert.equal(backendRelaunchArguments({type:'wayland',backend:'x11'},[],{[RELAUNCHED]:'1'}),null);
});

test('KDE Wayland reads and activates windows through one-shot KWin scripts reported by nonce',async()=>{
  const scripts=[];let active='{a1}';
  const {value,calls}=desktop({WAYLAND_DISPLAY:'w',XDG_CURRENT_DESKTOP:'KDE'},['gdbus','journalctl','ydotool'],(key,args)=>{
    if(key.includes('loadScript')){const file=args.at(-2);scripts.push(require('node:fs').readFileSync(file,'utf8'));return '(7,)';}
    if(key.startsWith('journalctl')){const nonce=key.split(' ').at(-1),body=scripts.at(-1);
      if(body.includes('activeWindow;print'))return nonce+' '+JSON.stringify({id:active,pid:51})+'\n';
      return nonce+(body.includes('let count')?' 1':'')+'\n';}
    return '';
  });
  const target=await value.capture();assert.equal(target.processId,51);
  await value.validatePaste(target);await value.paste(target);
  assert.ok(scripts.some(body=>body.includes('"{a1}"')&&body.includes('workspace.activeWindow=w')));
  assert.equal(await value.present(true),true);assert.match(scripts.at(-1),/w\.pid===4242&&.*w\.keepAbove=true/);
  assert.ok(calls.some(call=>call[0]==='gdbus'&&call.includes('/Scripting/Script7')));
  active='{b2}';await assert.rejects(value.paste(target),/No keys were sent/);
});

test('a Wayland watcher that exits (GNOME, no data-control) keeps the sequence alive by polling',async()=>{
  const {EventEmitter}=require('node:events');const data={'text/plain':'a'},{value}=clipboard('wayland',data);
  const child=Object.assign(new EventEmitter(),{stdout:new EventEmitter(),kill(){}});
  const watcher=new ClipboardWatcher(value,{interval:5,spawner:()=>child}).start();
  child.stdout.emit('data',Buffer.from('changed\nchanged\n'));assert.equal(watcher.read(),2);
  child.emit('exit',1);await new Promise(resolve=>setTimeout(resolve,30));data['text/plain']='b';await new Promise(resolve=>setTimeout(resolve,30));watcher.kill();
  assert.equal(watcher.read(),3);
});

test('a Wayland watcher never reports the clipboard present at launch, so the first real copy is captured',()=>{
  const {EventEmitter}=require('node:events'),{value}=clipboard('wayland',{'text/plain':'a'}),changes=[];
  const child=Object.assign(new EventEmitter(),{stdout:new EventEmitter(),kill(){}});
  const watcher=new ClipboardWatcher(value,{changed:sequence=>changes.push(sequence),spawner:()=>child}).start();
  child.stdout.emit('data',Buffer.from('changed\n'));assert.deepEqual(changes,[]);
  child.stdout.emit('data',Buffer.from('changed\n'));assert.deepEqual(changes,[2]);watcher.kill();
});

test('a failed ydotool paste explains how to enable the service',async()=>{
  const {value}=desktop({WAYLAND_DISPLAY:'w',XDG_CURRENT_DESKTOP:'GNOME'},['ydotool'],key=>key.startsWith('ydotool')?new Error('socket'):'');
  await assert.rejects(value.paste(await value.capture()),/systemctl --user enable --now ydotool/);
});

const signatureEntry=(types,payloads,reads=[])=>({types,getType:async type=>{reads.push(type);if(payloads[type] instanceof Error)throw payloads[type];const bytes=Buffer.from(payloads[type]);return{size:bytes.length,arrayBuffer:async()=>bytes};}});

test('the change signature skips payloads a timestamp identifies and never reads a private copy',async()=>{
  const reads=[],stamped=[signatureEntry(['TIMESTAMP','text/plain'],{TIMESTAMP:[1,2,3,4],'text/plain':'secret'},reads)];
  const first=await clipboardSignature({read:async()=>stamped});assert.deepEqual(reads,['TIMESTAMP']);
  const moved=[signatureEntry(['TIMESTAMP','text/plain'],{TIMESTAMP:[9,2,3,4],'text/plain':'secret'})];
  assert.notEqual(await clipboardSignature({read:async()=>moved}),first);
  reads.length=0;await clipboardSignature({read:async()=>[signatureEntry(['x-kde-passwordManagerHint','text/plain'],{'text/plain':'secret'},reads)]});assert.deepEqual(reads,[]);
});

test('a TIMESTAMP the owner cannot serve falls back to content, and images are read only when captured',async()=>{
  const entry=text=>[signatureEntry(['TIMESTAMP','text/plain'],{TIMESTAMP:new Error('unavailable'),'text/plain':text})];
  assert.notEqual(await clipboardSignature({read:async()=>entry('a')}),await clipboardSignature({read:async()=>entry('b')}));
  assert.notEqual(await clipboardSignature({read:async()=>[signatureEntry(['TIMESTAMP','text/plain'],{TIMESTAMP:[0,0,0,0],'text/plain':'a'})]}),await clipboardSignature({read:async()=>[signatureEntry(['TIMESTAMP','text/plain'],{TIMESTAMP:[0,0,0,0],'text/plain':'b'})]}));
  const reads=[],image=[{...signatureEntry(['image/jpeg','image/png'],{'image/png':'converted'},reads),imageBytes:async()=>Buffer.from('raw')}];
  await clipboardSignature({read:async()=>image});assert.deepEqual(reads,[]);
  await clipboardSignature({read:async()=>image},{images:true});assert.deepEqual(reads,[]);
});

test('a Wayland fallback polls only while focused, reports once and backs off after a slow read',async()=>{
  const {value}=clipboard('wayland',{'text/plain':'a'});let focused=false,now=0,digests=0;const child=new EventEmitter();child.stdout=new EventEmitter();child.kill=()=>{};
  const failures=[],watcher=new ClipboardWatcher(value,{interval:100000,spawner:()=>child,failed:error=>failures.push(error),now:()=>now,context:()=>({images:false,focused})});
  watcher.digest=async()=>{digests++;now+=1000;return'x';};watcher.start();child.emit('exit',1);child.emit('error',new Error('late'));
  assert.equal(failures.length,1);assert.equal(failures[0].recoverable,true);
  const tick=async()=>{clearInterval(watcher.timer);watcher.timer=null;watcher.poll();await new Promise(resolve=>setImmediate(resolve));};
  assert.equal(digests,0);focused=true;await tick();assert.equal(digests,1);await tick();assert.equal(digests,1);
  now+=4000;await tick();assert.equal(digests,2);watcher.kill();
});

test('own copies are recovered from Chromium custom formats, so they are skipped',async()=>{
  const marker=Buffer.from('0123456789abcdef'),target='application/web;type="custom/0"';
  const {value}=clipboard('x11',{'text/plain':'hello',[FORMAT_MAP]:JSON.stringify({'application/x.clipboardline':'custom/0'}),[target]:marker});
  const [entry]=await value.read();assert.ok(entry.types.includes(MARKER_TYPE));
  assert.equal(await readClipboardContent({clipboard:value,sequence:async()=>1,marker,plainURL:()=>null}),null);
  const foreign=await readClipboardContent({clipboard:value,sequence:async()=>1,marker:Buffer.from('fedcba9876543210'),plainURL:()=>null});assert.equal(foreign.owned,false);assert.equal(foreign.value,'hello');
});

test('a production JPEG conversion refuses a file declaring more pixels than a stored image',()=>{
  const jpeg=(width,height)=>{const b=Buffer.alloc(40);b.set([0xff,0xd8,0xff,0xe0,0,4,0,0,0xff,0xc0,0,17,8]);b.writeUInt16BE(height,13);b.writeUInt16BE(width,15);return b;};
  assert.equal(decodableJPEG(jpeg(1920,1080)),true);assert.equal(decodableJPEG(jpeg(65000,65000)),false);assert.equal(decodableJPEG(Buffer.from('not a jpeg')),false);
});

test('a re-encoded image keeps its identity and an oversized PNG is never decoded',()=>{
  const png=(width,height,tail)=>{const b=Buffer.alloc(32);b.write('89504e470d0a1a0a','hex');b.write('IHDR',12,'latin1');b.writeUInt32BE(width,16);b.writeUInt32BE(height,20);b.write(tail,24);return b;};
  let decoded=0;const decode=()=>{decoded++;return{width:2,height:2,bitmap:Buffer.from([1,2,3,4])};};
  assert.equal(pixelFingerprint(png(2,2,'a'),decode),pixelFingerprint(png(2,2,'b'),decode));assert.equal(decoded,2);
  assert.equal(pixelFingerprint(png(50000,50000,'a'),decode),null);assert.equal(decoded,2);
});

test('writes carry the marker and every format; a hidden Wayland write falls back to the tool',async()=>{
  class Item{constructor(data){this.data=data;}}
  const written=[],electron={write:async items=>written.push(Object.keys(items[0].data))},marker=Buffer.from('marker'),tool={kind:'x11',writes:[],writeText(value){this.writes.push(['text',value]);},writePNG(){this.writes.push(['png']);},writeFiles(files){this.writes.push(['files',files]);},read:async()=>[]};
  assert.equal(await writeClipboard({electron,ClipboardItem:Item,tool,marker,text:'t',png:Buffer.from('p'),files:['/tmp/a b.png']}),'electron');
  assert.equal(written[0].length,5);assert.ok(written[0].includes(MARKER_TYPE));assert.deepEqual(tool.writes,[]);
  tool.kind='wayland';written.length=0;
  assert.equal(await writeClipboard({electron,ClipboardItem:Item,tool,marker,text:'t'}),'wl-copy');assert.deepEqual(written,[]);assert.deepEqual(tool.writes,[['text','t']]);
  tool.writes.length=0;tool.read=async()=>[{types:[MARKER_TYPE],getType:async()=>({arrayBuffer:async()=>marker})}];
  assert.equal(await writeClipboard({electron,ClipboardItem:Item,tool,marker,text:'t',focused:true,delay:async()=>{}}),'electron');assert.deepEqual(tool.writes,[]);
  tool.read=async()=>[];assert.equal(await writeClipboard({electron,ClipboardItem:Item,tool,marker,text:'t',focused:true,delay:async()=>{}}),'wl-copy');assert.deepEqual(tool.writes,[['text','t']]);
  assert.deepEqual(fileClipboard(['/tmp/a b.png']),{uriList:'file:///tmp/a%20b.png\r\n',gnome:'copy\nfile:///tmp/a%20b.png'});
});

test('a surviving selection owner keeps only its standard streams',async t=>{
  if(process.platform!=='linux')return t.skip('needs /proc');
  const {spawn}=require('node:child_process'),descriptor=fs.openSync(process.execPath,'r');t.after(()=>fs.closeSync(descriptor));
  const [file,args]=ownerCommand('sh',['-c','ls /proc/self/fd']);
  const child=spawn(file,args,{stdio:['pipe','pipe','ignore',...Array(descriptor>3?descriptor-3:0).fill('ignore'),descriptor]});let output='';child.stdout.on('data',chunk=>{output+=chunk;});
  await new Promise(resolve=>child.on('close',resolve));
  assert.deepEqual(output.trim().split('\n').map(Number).filter(value=>value>2&&value===descriptor),[]);
  assert.deepEqual(ownerCommand('wl-copy',['--type','x'],()=>null),['wl-copy',['--type','x']]);
});
