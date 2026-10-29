'use strict';
// Real Linux runtime acceptance. Run it inside a disposable desktop session
// (CI: Xvfb or headless sway; locally: a nested compositor), never on a
// desktop whose clipboard holds personal data: it replaces the clipboard.
const assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),os=require('node:os'),crypto=require('node:crypto'),zlib=require('node:zlib');
const {spawn,spawnSync}=require('node:child_process');
const {pathToFileURL}=require('node:url');
const {_electron:electron}=require('playwright');
const {linuxTools}=require('../lib/linux-session.cjs');
if(process.platform!=='linux')throw new Error('Run Linux runtime acceptance on a Linux desktop session.');
if(!process.env.WAYLAND_DISPLAY&&!process.env.DISPLAY)throw new Error('Linux runtime acceptance needs a Wayland or X11 display.');
const output=path.resolve(process.env.CLIPBOARDLINE_VALIDATION||'validation/linux');fs.mkdirSync(output,{recursive:true});
const data=fs.mkdtempSync(path.join(os.tmpdir(),'clipboardline-linux-runtime-'));
const tools=linuxTools(),executable=process.env.CLIPBOARDLINE_EXECUTABLE?path.resolve(process.env.CLIPBOARDLINE_EXECUTABLE):null;
const report={platform:process.platform,arch:process.arch,sourceRevision:process.env.GITHUB_SHA||'',packaged:!!executable,environment:{sessionType:process.env.XDG_SESSION_TYPE||'',desktop:process.env.XDG_CURRENT_DESKTOP||'',wayland:!!process.env.WAYLAND_DISPLAY,x11:!!process.env.DISPLAY},checks:[],skipped:[]};
const check=(name,details={})=>{report.checks.push({name,passed:true,...details});console.log('PASS '+name);};
const skip=(name,reason)=>{report.skipped.push({name,reason});console.log('SKIP '+name+': '+reason);};
async function until(reader,predicate,timeout=15000){const end=Date.now()+timeout;let value;while(Date.now()<end){try{value=await reader();if(predicate(value))return value;}catch{}await new Promise(resolve=>setTimeout(resolve,100));}throw new Error('Timed out waiting for Linux runtime state: '+JSON.stringify(value)?.slice(0,500));}
// A generated 8x8 PNG; no personal screenshots are used.
function syntheticPNG(width=8,height=8){
  const chunk=(type,data)=>{const length=Buffer.alloc(4),crc=Buffer.alloc(4),body=Buffer.concat([Buffer.from(type),data]);length.writeUInt32BE(data.length);crc.writeUInt32BE(zlib.crc32(body));return Buffer.concat([length,body,crc]);};
  const header=Buffer.alloc(13);header.writeUInt32BE(width,0);header.writeUInt32BE(height,4);header.set([8,6,0,0,0],8);
  const rows=Buffer.concat(Array.from({length:height},(_row,y)=>Buffer.concat([Buffer.from([0]),...Array.from({length:width},(_column,x)=>Buffer.from([x*30,y*30,180,255]))])));
  return Buffer.concat([Buffer.from('89504e470d0a1a0a','hex'),chunk('IHDR',header),chunk('IDAT',zlib.deflateSync(rows)),chunk('IEND',Buffer.alloc(0))]);
}
const PNG=syntheticPNG();
const xclip=spawnSync('sh',['-c','command -v xclip'],{encoding:'utf8'}).stdout.trim()||null;
// Without xclip, a second Electron X11 client owns the selection instead.
const helper=path.join(__dirname,'x11-clipboard-helper.cjs'),owners=[];
const electronBinary=()=>require('electron');
function releaseOwners(){for(const owner of owners.splice(0))owner.stdin.end();}
function externalCopy(type,bytes,backend){
  releaseOwners();
  if(backend==='x11'&&!xclip)return new Promise((resolve,reject)=>{const child=spawn(electronBinary(),[helper,'write',type,bytes.toString('base64')],{stdio:['pipe','pipe','ignore']});owners.push(child);child.stdout.once('data',()=>resolve());child.on('error',reject);child.on('exit',code=>{if(code)reject(new Error('X11 helper failed'));});});
  const [file,args]=backend==='wayland'?[tools['wl-copy'],['--type',type]]:[xclip,['-selection','clipboard','-t',type,'-i']];
  return new Promise((resolve,reject)=>{const child=spawn(file,args,{stdio:['pipe','ignore','ignore']});child.on('error',reject);child.on('exit',code=>code?reject(new Error('external copy failed')):resolve());child.stdin.end(bytes);});
}
function externalPaste(type,backend){
  if(backend==='x11'&&!xclip){const result=spawnSync(electronBinary(),[helper,'read',type],{timeout:15000,encoding:'utf8'});if(result.status!==0)throw new Error('X11 helper could not read '+type);return Buffer.from(result.stdout.trim(),'base64');}
  const result=backend==='wayland'?spawnSync(tools['wl-paste'],['--no-newline','--type',type],{timeout:5000}):spawnSync(xclip,['-selection','clipboard','-o','-t',type],{timeout:5000});
  if(result.status!==0)throw new Error('external paste failed: '+String(result.stderr).slice(0,200));return result.stdout;
}
async function main(){
  const args=['--test-mode','--test-data='+data];
  const application=await electron.launch({...(executable?{executablePath:executable,args}:{args:[path.resolve('.'),...args]}),timeout:60000});
  let second;
  try{
    const page=await application.firstWindow();await page.waitForFunction(()=>!!window.clipboardLine);
    await until(()=>application.evaluate(()=>!!global.__clipboardLineTest),Boolean);
    const test=(body,arg)=>application.evaluate(body,arg);
    const state=()=>test(()=>global.__clipboardLineTest.state());
    const initial=await state();report.linux=initial.linux;report.version=initial.version;report.build=initial.build;
    assert.equal(initial.platform,'linux');assert.ok(['wayland','x11'].includes(initial.linux.backend));assert.equal(initial.update.status,'manual');
    const backend=initial.linux.backend;
    check('Linux session, display backend and manual update channel are reported',{backend,session:initial.linux.session,clipboardMonitor:initial.linux.clipboardMonitor});
    assert.equal(await test(()=>{const window=global.__clipboardLineTest.getWindow();return window.isVisible();}),true);check('the shelf window opens on the Linux display');
    if(process.platform==='linux'&&fs.statSync(data).mode%0o1000!==0o700)throw new Error('Application data is not private to the user.');check('application data directory is owner-only (0700)');

    const externalClipboard=backend==='wayland'?!!(tools['wl-copy']&&tools['wl-paste']):!!(xclip||process.env.DISPLAY);
    if(!externalClipboard)skip('external clipboard round trips',backend==='wayland'?'wl-clipboard is not installed':'no X11 display');
    else{
      await test(()=>global.__clipboardLineTest.command('setSettings',{patch:{captureText:true,captureImages:true,captureLinks:true}}));
      const sequence=()=>test(()=>global.__clipboardLineTest.native.clipboardSequence());
      // A raced read is retried by the app itself; wait for the expected record.
      const listed=()=>test(()=>global.__clipboardLineTest.store.data.items.map(item=>({id:item.id,kind:item.kind,text:item.text,url:item.url})));
      const capture=async(type,bytes,expected)=>{const before=await sequence();await externalCopy(type,bytes,backend);await until(sequence,value=>value!==before,backend==='wayland'?15000:6000);return until(async()=>{await test(()=>global.__clipboardLineTest.readClipboard());return listed();},items=>items.some(expected));};
      const note='Synthetic Linux note '+crypto.randomUUID();
      let items=await capture('text/plain;charset=utf-8',Buffer.from(note),item=>item.kind==='text'&&item.text===note);check('text copied by another application is captured',{monitor:(await state()).linux.clipboardMonitor});
      items=await capture('text/plain;charset=utf-8',Buffer.from('https://example.com/linux-acceptance'),item=>item.kind==='link'&&item.url==='https://example.com/linux-acceptance');check('a copied standalone URL is captured as a link');
      items=await capture('image/png',PNG,item=>item.kind==='image');check('an image copied by another application is captured');
      const count=items.length,textItem=items.find(item=>item.kind==='text');
      await test((_electron,id)=>global.__clipboardLineTest.writeClipboard([global.__clipboardLineTest.store.item(id)]),textItem.id);
      assert.equal(externalPaste('text/plain;charset=utf-8',backend).toString('utf8'),note);
      await test(()=>global.__clipboardLineTest.readClipboard());
      assert.equal(await test(()=>global.__clipboardLineTest.store.data.items.length),count);check('ClipBoardLine copies reach other applications and are not captured again');
      const imageItem=items.find(item=>item.kind==='image');
      await test((_electron,id)=>global.__clipboardLineTest.writeClipboard([global.__clipboardLineTest.store.item(id)]),imageItem.id);
      const pastedImage=externalPaste('image/png',backend);assert.equal(pastedImage.subarray(0,8).toString('hex'),'89504e470d0a1a0a');check('an image copied by ClipBoardLine is offered as PNG',{bytes:pastedImage.length});
      const images=await test(({nativeImage})=>[1,2].map(shade=>global.__clipboardLineTest.store.insert('image',nativeImage.createFromBitmap(Buffer.alloc(4*4*4,shade*80),{width:4,height:4}).toPNG()).id));
      await test((_electron,ids)=>global.__clipboardLineTest.writeClipboard(ids.map(id=>global.__clipboardLineTest.store.item(id))),images);
      const uris=externalPaste('text/uri-list',backend).toString('utf8').trim().split(/\r?\n/);
      const paths=await test((_electron,ids)=>ids.map(id=>global.__clipboardLineTest.store.mediaPath(id)),images);
      assert.deepEqual(uris,paths.map(file=>pathToFileURL(file).href));check('several images are offered to file managers as a file list');
      await test(()=>global.__clipboardLineTest.command('show'));
      const pasted=await test((_electron,id)=>global.__clipboardLineTest.command('paste',{ids:[id]}),textItem.id);
      assert.equal(pasted.result?.error,undefined,JSON.stringify(pasted.result));
      assert.equal(await test(()=>global.__clipboardLineTest.getWindow().isVisible()),false);assert.equal(externalPaste('text/plain;charset=utf-8',backend).toString('utf8'),note);
      check('Ctrl+Enter paste copies, hides the shelves and returns focus',{automaticPaste:(await state()).linux.automaticPaste});
    }

    const video=path.join(data,'synthetic.mp4');
    if(tools.ffmpeg&&tools.ffprobe){
      // Synthetic test pattern and tone; distribution builds differ in encoders.
      const made=[['libx264','aac'],['libopenh264','aac'],['libvpx-vp9','libopus']].map(([videoCodec,audioCodec])=>spawnSync(tools.ffmpeg,['-v','error','-f','lavfi','-i','testsrc=size=320x240:rate=25:duration=2','-f','lavfi','-i','sine=frequency=440:duration=2','-shortest','-c:v',videoCodec,'-pix_fmt','yuv420p','-c:a',audioCodec,'-y',video],{timeout:60000})).find(result=>result.status===0);
      if(!made)skip('recording import and trim','the installed FFmpeg cannot encode a synthetic H.264 or VP9 fixture');
      else{
        const imported=await test(async(_electron,file)=>{const hooks=global.__clipboardLineTest,item=await hooks.importFile(file);return{id:item.id,durationMs:item.durationMs,width:item.width,height:item.height};},video);
        assert.ok(Math.abs(imported.durationMs-2000)<150);check('a recording is imported with FFmpeg metadata and poster',imported);
        const fingerprint=await test((_electron,id)=>{const item=global.__clipboardLineTest.store.item(id);return(item.renderedVideoFile||item.videoFile).slice(0,64);},imported.id);
        const trimmed=await test((_electron,{id,fingerprint})=>global.__clipboardLineTest.command('trimRecording',{id,sourceFingerprint:fingerprint,startMs:500,endMs:1500}),{id:imported.id,fingerprint});
        assert.equal(trimmed.result?.error,undefined,JSON.stringify(trimmed.result));
        assert.ok(Math.abs(await test((_electron,id)=>global.__clipboardLineTest.store.item(id).durationMs,imported.id)-1000)<150);check('a recording is trimmed into a new managed MP4');
      }
    }else{
      fs.writeFileSync(video,Buffer.alloc(64));
      const failure=await test(async(_electron,file)=>{try{await global.__clipboardLineTest.importFile(file);return null;}catch(error){return error.message;}},video);
      assert.match(failure,/Install FFmpeg/);check('recording import explains the missing FFmpeg dependency');
    }

    // A desktop shortcut command reaches the running instance.
    second=spawn(executable||require('electron'),[...(executable?[]:[path.resolve('.')]),...args,'--library'],{stdio:'ignore'});
    await until(state,value=>value.view==='library'&&value.windowVisible===true);check('a second launch with --library is forwarded to the running instance');
    await page.evaluate(()=>window.clipboardLine.command('settings'));
    const sources=await until(async()=>{await page.evaluate(()=>document.querySelector('[data-settings-tab="sources"],[data-section="sources"],[data-tab="sources"]')?.click());return page.evaluate(()=>document.body.innerText);},text=>text.includes('Linux integration'));
    assert.match(sources,/Linux integration/);check('Settings shows the Linux integration status');
    const updates=await until(async()=>{await page.evaluate(()=>document.querySelector('[data-tab="updates"]')?.click());return page.evaluate(()=>document.body.innerText);},text=>text.includes('Open releases page'));
    assert.doesNotMatch(updates,/Update and reopen/);check('Updates offers the releases page instead of an in-place installer');
  }finally{
    report.finishedAt=new Date().toISOString();fs.writeFileSync(path.join(output,'linux-runtime.json'),JSON.stringify(report,null,2)+'\n');
    second?.kill();releaseOwners();
    // The window hides instead of closing until the app is quitting.
    await Promise.race([application.evaluate(({app})=>{app.quit();}).catch(()=>{}),new Promise(resolve=>setTimeout(resolve,3000))]);
    await Promise.race([application.close().catch(()=>{}),new Promise(resolve=>setTimeout(resolve,10000))]);fs.rmSync(data,{recursive:true,force:true});
  }
}
main().then(()=>process.exit(0),error=>{console.error(error.stack||error.message);report.error=String(error.message).slice(0,2000);fs.writeFileSync(path.join(output,'linux-runtime.json'),JSON.stringify(report,null,2)+'\n');process.exit(1);});
