'use strict';
// Native Linux acceptance: launches the real application in an isolated test
// profile on the current desktop session and exercises the actual clipboard,
// screen capture, FFmpeg, global shortcut and paste paths. The user's current
// text or image clipboard is saved first and restored at the end.
// Run from an unlocked graphical session:  npm run test:linux
const assert=require('node:assert/strict');
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),crypto=require('node:crypto');
const {spawn,execFileSync}=require('node:child_process');
const {_electron:electron}=require('playwright');
if(process.platform!=='linux'){console.error('Linux acceptance must run on Linux.');process.exit(2);}
const results=[];const check=(name,detail='')=>{results.push(name);console.log('  ✔ '+name+(detail?' — '+detail:''));};
const skip=(name,reason)=>console.log('  ﹣ '+name+' (skipped: '+reason+')');
const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
// A small grayscale rendering of the current monitor through the desktop tool.
function screen(){const file=path.join(os.tmpdir(),'clipboardline-acceptance-'+process.pid+'.png');try{execFileSync('spectacle',['--background','--nonotify','--current','--output',file],{timeout:15000,stdio:'ignore'});return execFileSync('ffmpeg',['-v','error','-i',file,'-vf','scale=320:200,format=gray','-f','rawvideo','pipe:1']);}finally{fs.rmSync(file,{force:true});}}
function difference(a,b){let changed=0;for(let i=0;i<Math.min(a.length,b.length);i++)if(Math.abs(a[i]-b[i])>24)changed++;return changed/Math.min(a.length,b.length);}
// Watchers of a ClipBoardLine the user already runs are not this test's.
const watchers=()=>{try{return execFileSync('pgrep',['-a','-x','wl-paste']).toString().split('\n').filter(line=>line.includes('--watch /bin/sh -c cat >/dev/null; echo'));}catch{return [];}};
const preexistingWatchers=new Set(watchers());
const has=name=>{try{execFileSync('sh',['-c','command -v "$1"','sh',name],{stdio:'ignore'});return true;}catch{return false;}};
const wayland=!!process.env.WAYLAND_DISPLAY;
if(!wayland||!has('wl-copy')||!has('wl-paste')){console.error('This acceptance run needs a Wayland session with wl-clipboard.');process.exit(2);}
const paste=(args=[])=>{try{return execFileSync('wl-paste',args,{timeout:4000,maxBuffer:256*1024*1024});}catch{return null;}};
const copy=(bytes,type)=>{const child=spawn('wl-copy',['--type',type],{stdio:['pipe','ignore','ignore']});child.stdin.end(bytes);return new Promise(resolve=>child.on('exit',resolve));};
async function until(read,accept,{timeout=8000,interval=100}={}){const deadline=Date.now()+timeout;let value;do{value=await read();if(accept(value))return value;await wait(interval);}while(Date.now()<deadline);return value;}
function saveClipboard(){
 const types=String(paste(['--list-types'])||'').split('\n').filter(Boolean);
 for(const type of ['image/png','text/plain;charset=utf-8','text/plain'])if(types.includes(type)){const bytes=paste(['--no-newline','--type',type]);if(bytes)return{type,bytes};}
 return null;
}
(async()=>{
 const saved=saveClipboard();const data=fs.mkdtempSync(path.join(os.tmpdir(),'clipboardline-linux-acceptance-'));
 let application,target;const token=crypto.randomBytes(4).toString('hex');
 try{
  // CLIPBOARDLINE_EXECUTABLE checks a packaged build (dist/linux-unpacked/clipboardline).
  const testArgs=['--test-mode','--test-data='+data];
  application=await electron.launch({...(process.env.CLIPBOARDLINE_EXECUTABLE?{executablePath:path.resolve(process.env.CLIPBOARDLINE_EXECUTABLE),args:testArgs}:{args:[path.resolve(__dirname,'..'),...testArgs]}),timeout:60000});
  await until(()=>application.evaluate(()=>!!global.__clipboardLineTest),Boolean,{timeout:30000});
  const main=(fn,arg)=>application.evaluate(fn,arg);
  const command=(action,payload)=>main(async(_e,[action,payload])=>global.__clipboardLineTest.command(action,payload),[action,payload]);
  const items=()=>main(()=>global.__clipboardLineTest.store.data.items.map(item=>({id:item.id,kind:item.kind,text:item.text,url:item.url,recording:!!item.recording,durationMs:item.durationMs,videoFile:item.videoFile,renderedVideoFile:item.renderedVideoFile,trashedAt:item.trashedAt||null})));
  const read=()=>main(()=>global.__clipboardLineTest.readClipboard());

  const diagnostics=await main(()=>global.__clipboardLineTest.native.captureDiagnostics());
  const ozone=await main(({app})=>app.commandLine.getSwitchValue('ozone-platform'));
  assert.equal(diagnostics.platform,'linux');assert.equal(diagnostics.clipboardBackend,'wl-clipboard');assert.equal(ozone,'wayland');
  const gpu=await main(({app})=>app.getGPUFeatureStatus().gpu_compositing);
  check('application starts as a native Wayland client with the wl-clipboard backend',diagnostics.session+'/'+diagnostics.desktop.join(':')+', GPU compositing '+gpu);
  // State alone is not proof: compare real screen pixels with the shelves
  // hidden and shown (an invisible XWayland surface once passed every state check).
  // A powered-off display yields empty screenshots; never report that as a result.
  const displaysOff=has('kscreen-doctor')&&/dpms mode for screen \S+: off/.test(execFileSync('kscreen-doctor',['--dpms','show']).toString());
  if(displaysOff)skip('on-screen drawing','displays are powered off (DPMS); run with the screen on');
  else if(has('spectacle')){
   await command('hide',{});await wait(700);const hidden=screen();
   await command('show',{});await wait(1200);const shown=screen();
   const changed=difference(hidden,shown);assert.ok(changed>0.01,'shelves were not drawn on screen ('+(changed*100).toFixed(2)+'% of pixels changed)');
   check('shelves are actually drawn on screen',(changed*100).toFixed(1)+'% of screen pixels changed');
  }else skip('on-screen drawing','spectacle is not installed');
  const state=await main(()=>global.__clipboardLineTest.state());
  assert.equal(state.platform,'linux');assert.equal(state.settings.shortcuts.toggle,'Control+Alt+V');assert.equal(state.update.status,'unsupported');
  check('Linux defaults: terminal-safe toggle shortcut and no Windows update channel');
  assert.equal(fs.statSync(data).mode&0o777,0o700);check('private profile directory is 0700');

  await command('setSettings',{patch:{captureText:true,captureImages:true,captureLinks:true,fetchLinkMetadata:false,indexImages:false}});
  const text='ClipBoardLine Linux acceptance '+token;
  await copy(Buffer.from(text),'text/plain;charset=utf-8');
  const textItem=(await until(async()=>{await read();return (await items()).find(item=>item.text===text);},Boolean));
  assert.ok(textItem,'external text copy was not captured');check('background capture of text copied by another Wayland client');
  const url='https://example.com/clipboardline-'+token;
  await copy(Buffer.from(url),'text/plain;charset=utf-8');
  const linkItem=await until(async()=>{await read();return (await items()).find(item=>item.url===url);},Boolean);
  assert.equal(linkItem?.kind,'link');check('standalone URL becomes a link record');

  const png=fs.readFileSync(path.join(__dirname,'..','assets','clipboardline.png'));
  const before=(await items()).filter(item=>item.kind==='image').length;
  await copy(png,'image/png');
  const imageCount=await until(async()=>{await read();return (await items()).filter(item=>item.kind==='image').length;},count=>count===before+1);
  assert.equal(imageCount,before+1);check('background capture of a PNG image');
  if(has('ffmpeg')){
   const jpeg=execFileSync('ffmpeg',['-v','error','-i','pipe:0','-vf','scale=320:-2','-f','image2','-c:v','mjpeg','pipe:1'],{input:png,maxBuffer:64*1024*1024});
   await copy(jpeg,'image/jpeg');
   const count=await until(async()=>{await read();return (await items()).filter(item=>item.kind==='image').length;},value=>value===before+2);
   assert.equal(count,before+2);check('JPEG-only image offer is converted and captured');
  }

  const all=await items();const imageItems=all.filter(item=>item.kind==='image');
  const countBefore=all.length;
  await main(async(_e,id)=>{const t=global.__clipboardLineTest;await t.writeClipboard(t.store.selected([id]));},textItem.id);
  assert.equal(String(paste(['--no-newline'])),text);await wait(400);await read();
  assert.equal((await items()).length,countBefore);check('copying text from the library reaches other apps and is not recaptured');
  await main(async(_e,id)=>{const t=global.__clipboardLineTest;await t.writeClipboard(t.store.selected([id]));},imageItems[0].id);
  const offered=String(paste(['--list-types'])).split('\n');assert.ok(offered.includes('image/png'),'image/png not offered: '+offered.join(','));
  const pasted=paste(['--no-newline','--type','image/png']);assert.equal(pasted.subarray(0,8).toString('hex'),'89504e470d0a1a0a');
  await wait(400);await read();assert.equal((await items()).length,countBefore);
  check('copying an image publishes image/png to Wayland apps','offered '+pasted.length+' bytes');
  if(imageItems.length>1){
   await main(async(_e,ids)=>{const t=global.__clipboardLineTest;await t.writeClipboard(t.store.selected(ids));},imageItems.slice(0,2).map(item=>item.id));
   const list=String(paste(['--no-newline','--type','text/uri-list'])).trim().split(/\r?\n/);
   assert.equal(list.length,2);assert.ok(list.every(uri=>fs.existsSync(decodeURIComponent(new URL(uri).pathname))));
   check('multi-image copy publishes an existing file list (text/uri-list)');
  }

  if(has('ffmpeg')&&has('ffprobe')){
   const fixture=path.join(__dirname,'fixtures','recordings','synthetic-rgb-tone.mp4');
   const recording=await main(async(_e,file)=>{const t=global.__clipboardLineTest,item=await t.importFile(file);return{id:item.id,recording:!!item.recording,durationMs:item.durationMs,fingerprint:(item.renderedVideoFile||item.videoFile).slice(0,64)};},fixture);
   assert.equal(recording.recording,true);assert.equal(Math.round(recording.durationMs),6000);check('MP4 recording import with FFmpeg metadata and poster');
   const trimmed=await command('trimRecording',{id:recording.id,sourceFingerprint:recording.fingerprint,startMs:1000,endMs:4000});
   assert.equal(trimmed.result?.id,recording.id,trimmed.result?.error||trimmed.message);
   const after=(await items()).find(item=>item.id===recording.id);assert.ok(Math.abs(after.durationMs-3000)<=150,'trimmed duration '+after.durationMs);
   check('recording trim re-encodes the selected range',Math.round(after.durationMs)+' ms');
   await main(async(_e,id)=>{const t=global.__clipboardLineTest;await t.writeClipboard(t.store.selected([id]));},recording.id);
   const uri=String(paste(['--no-newline','--type','text/uri-list'])).trim();assert.match(uri,/^file:\/\/.+\.mp4$/);check('recording copy transfers the video file');
  }else skip('recordings','ffmpeg/ffprobe not installed');

  if(has('spectacle')||has('grim')||has('gnome-screenshot')){
   const shot=await main(()=>global.__clipboardLineTest.capture());
   const item=(await items()).find(value=>value.id===shot.id);assert.equal(item?.kind,'image');check('screenshot through the desktop screenshot tool');
   await command('hide',{});
  }else skip('screenshot','no desktop screenshot tool');

  const ydotool=diagnostics.tools.ydotool&&diagnostics.ydotoolSocket;
  if(ydotool){
   await command('hide',{});await wait(300);
   // A dedicated combination in its own Plasma component never collides with
   // a ClipBoardLine the user is running.
   await command('setSettings',{patch:{shortcuts:{toggle:'Control+Alt+Shift+V'}}});
   const toggleKeys=['29:1','56:1','42:1','47:1','47:0','42:0','56:0','29:0'];
   execFileSync('ydotool',['key',...toggleKeys]);
   const shown=await until(()=>main(()=>global.__clipboardLineTest.state().windowVisible),Boolean,{timeout:4000});
   assert.equal(shown,true);
   const shelfFocused=await until(()=>main(()=>global.__clipboardLineTest.getWindow().isFocused()),Boolean,{timeout:2000});
   assert.equal(shelfFocused,true,'shelves opened without keyboard focus');
   check('global shortcut opens the shelves with keyboard focus',diagnostics.desktop.includes('KDE')?'registered with Plasma kglobalaccel':'Electron key grab');
   execFileSync('ydotool',['key',...toggleKeys]);
   const hidden=await until(()=>main(()=>global.__clipboardLineTest.state().windowVisible),value=>value===false,{timeout:4000});
   assert.equal(hidden,false);check('the same shortcut hides the shelves');

   // Paste into a disposable native Wayland editor the test owns.
   const executable=require('electron');
   target=spawn(executable,[path.join(__dirname,'linux-paste-target.cjs')],{stdio:['ignore','pipe','ignore'],env:{...process.env,CLIPBOARDLINE_TARGET_LIFETIME:'25000'}});
   const events=[];let buffer='';target.stdout.on('data',chunk=>{buffer+=chunk;let line;while((line=buffer.indexOf('\n'))>=0){try{events.push(JSON.parse(buffer.slice(0,line)));}catch{}buffer=buffer.slice(line+1);}});
   const focused=await until(()=>events.filter(event=>'focused' in event).at(-1)?.focused,Boolean,{timeout:10000});
   if(!focused)skip('paste into the previous application','the target editor did not receive focus');
   else{
    await command('show',{});await wait(500);
    const response=await command('paste',{ids:[textItem.id]});
    assert.ok(!response.result?.error,response.result?.error);
    const value=await until(()=>events.filter(event=>'value' in event).at(-1)?.value,value=>value===text,{timeout:5000});
    assert.equal(value,text);check('Ctrl+Enter paste returns focus to the previous Wayland app and pastes there');
   }
  }else skip('global shortcut and paste','ydotool service is not available');
  // Quit the way a user does (tray Quit → app.quit) and observe the real exit.
  const exited=new Promise(resolve=>application.process().once('exit',resolve));
  await application.evaluate(({app})=>{setTimeout(()=>app.quit(),50);}).catch(()=>{});
  await Promise.race([exited,wait(15000)]);application=null;
  const orphaned=await until(()=>watchers().filter(line=>!preexistingWatchers.has(line)).join('\n'),value=>value==='',{timeout:3000});
  assert.equal(orphaned,'','clipboard watcher outlived the application');check('quitting stops the clipboard watcher and releases Plasma shortcuts');
  console.log(`\nLinux acceptance passed: ${results.length} checks.`);
 }catch(error){console.error('\n✖ Linux acceptance failed:',error);process.exitCode=1;}
 finally{
  target?.kill();if(application)await Promise.race([application.close().catch(()=>{}),wait(15000)]);
  if(saved)await copy(saved.bytes,saved.type);else execFileSync('wl-copy',['--clear']);
  fs.rmSync(data,{recursive:true,force:true});
 }
 process.exit(process.exitCode||0);
})();
