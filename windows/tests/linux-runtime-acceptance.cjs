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
// mkdtemp already creates 0700; open it so the check below proves the app restricts it.
fs.chmodSync(data,0o755);
const tools=linuxTools(),executable=process.env.CLIPBOARDLINE_EXECUTABLE?path.resolve(process.env.CLIPBOARDLINE_EXECUTABLE):null;
const report={platform:process.platform,arch:process.arch,sourceRevision:process.env.GITHUB_SHA||'',packaged:!!executable,environment:{sessionType:process.env.XDG_SESSION_TYPE||'',desktop:process.env.XDG_CURRENT_DESKTOP||'',wayland:!!process.env.WAYLAND_DISPLAY,x11:!!process.env.DISPLAY},checks:[],skipped:[]};
const check=(name,details={})=>{report.checks.push({name,passed:true,...details});console.log('PASS '+name);};
const skip=(name,reason)=>{report.skipped.push({name,reason});console.log('SKIP '+name+': '+reason);};
async function until(reader,predicate,timeout=15000){const end=Date.now()+timeout;let value;while(Date.now()<end){try{value=await reader();if(predicate(value))return value;}catch{}await new Promise(resolve=>setTimeout(resolve,100));}throw new Error('Timed out waiting for Linux runtime state: '+JSON.stringify(value)?.slice(0,500));}
// A generated 8x8 PNG; no personal screenshots are used.
function syntheticPNG(width=8,height=8,{note}={}){
  const chunk=(type,data)=>{const length=Buffer.alloc(4),crc=Buffer.alloc(4),body=Buffer.concat([Buffer.from(type),data]);length.writeUInt32BE(data.length);crc.writeUInt32BE(zlib.crc32(body));return Buffer.concat([length,body,crc]);};
  const header=Buffer.alloc(13);header.writeUInt32BE(width,0);header.writeUInt32BE(height,4);header.set([8,6,0,0,0],8);
  const rows=Buffer.concat(Array.from({length:height},(_row,y)=>Buffer.concat([Buffer.from([0]),...Array.from({length:width},(_column,x)=>Buffer.from([x*30,y*30,180,255]))])));
  // A note chunk changes the encoded bytes without changing the pixels.
  return Buffer.concat([Buffer.from('89504e470d0a1a0a','hex'),chunk('IHDR',header),...(note?[chunk('tEXt',Buffer.from('Software\0'+note,'latin1'))]:[]),chunk('IDAT',zlib.deflateSync(rows,{level:note?9:6})),chunk('IEND',Buffer.alloc(0))]);
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
      // KDE's clipboard re-serves a screenshot re-encoded once its source exits.
      const imageCount=items.filter(item=>item.kind==='image').length,reencoded=syntheticPNG(8,8,{note:'clipboard manager'});assert.ok(!reencoded.equals(PNG));
      {const before=await sequence();await externalCopy('image/png',reencoded,backend);await until(sequence,value=>value!==before,backend==='wayland'?15000:6000);}
      for(let attempt=0;attempt<3;attempt++){await test(()=>global.__clipboardLineTest.readClipboard());await new Promise(resolve=>setTimeout(resolve,200));}
      items=await listed();assert.equal(items.filter(item=>item.kind==='image').length,imageCount);check('the same image served again with other PNG bytes is not captured twice');
      // A screenshot tool copies and quits at once (Spectacle does); its copy
      // must stay pasteable without a second shelf item. Under X11 only xclip
      // can abandon a read the quitting owner never answers.
      if(backend==='x11'&&!xclip)skip('a copy whose app quits stays pasteable','install xclip; Electron\'s X11 reader can stall when the owner quits');
      else{
        const quitting=syntheticPNG(12,12),images=()=>listed().then(value=>value.filter(item=>item.kind==='image').length),before=await images();
        const source=backend==='wayland'?spawn(tools['wl-copy'],['--foreground','--type','image/png'],{stdio:['pipe','ignore','ignore']}):spawn(electronBinary(),[helper,'write','image/png',quitting.toString('base64')],{stdio:['pipe','pipe','ignore']});
        if(backend==='wayland')source.stdin.end(quitting);else await new Promise(resolve=>source.stdout.once('data',resolve));
        await until(async()=>{await test(()=>global.__clipboardLineTest.readClipboard());return images();},count=>count===before+1);
        await new Promise(resolve=>{source.once('exit',resolve);if(backend==='wayland')source.kill();else source.stdin.end();});
        // A read sent as the owner quit can go unanswered until the app gives up on it.
        const served=await until(async()=>{await test(()=>global.__clipboardLineTest.readClipboard());try{return externalPaste('image/png',backend);}catch{return null;}},value=>!!value?.length,40000);
        const samePixels=await test(({nativeImage},[copied,pasted])=>{const left=nativeImage.createFromBuffer(Buffer.from(copied,'base64')),right=nativeImage.createFromBuffer(Buffer.from(pasted,'base64'));return !right.isEmpty()&&left.toBitmap().equals(right.toBitmap());},[quitting.toString('base64'),served.toString('base64')]);
        assert.ok(samePixels,'the pasted image is the copied screenshot');
        for(let attempt=0;attempt<3;attempt++){await test(()=>global.__clipboardLineTest.readClipboard());await new Promise(resolve=>setTimeout(resolve,200));}
        assert.equal(await images(),before+1);check('an image copied by an app that then quits stays pasteable and is captured once');
        // A copy deleted from the shelf is not served again, and copied text
        // never is: a password manager clears its copy on purpose. Later checks
        // use the shelf as it was before these two copies.
        const extra=new Set();
        for(const [label,type,bytes] of [['a deleted image','image/png',syntheticPNG(14,14)],['copied text','text/plain;charset=utf-8',Buffer.from('Synthetic text whose app quits '+crypto.randomUUID())]]){
          const known=new Set((await listed()).map(item=>item.id));
          const owner=backend==='wayland'?spawn(tools['wl-copy'],['--foreground','--type',type],{stdio:['pipe','ignore','ignore']}):spawn(electronBinary(),[helper,'write',type,bytes.toString('base64')],{stdio:['pipe','pipe','ignore']});
          if(backend==='wayland')owner.stdin.end(bytes);else await new Promise(resolve=>owner.stdout.once('data',resolve));
          const added=(await until(async()=>{await test(()=>global.__clipboardLineTest.readClipboard());return listed();},value=>value.some(item=>!known.has(item.id)))).find(item=>!known.has(item.id));extra.add(added.id);
          if(added.kind==='image')await test((_electron,id)=>global.__clipboardLineTest.command('trash',{ids:[id]}),added.id);
          await new Promise(resolve=>{owner.once('exit',resolve);if(backend==='wayland')owner.kill();else owner.stdin.end();});
          for(let attempt=0;attempt<5;attempt++){await test(()=>global.__clipboardLineTest.readClipboard());await new Promise(resolve=>setTimeout(resolve,300));}
          let served=null;try{served=externalPaste(type,backend);}catch{}
          assert.ok(!served?.length,label+' is not served again after its app quits');
        }
        check('a deleted image and copied text are not served again after their app quits');
        items=(await listed()).filter(item=>!extra.has(item.id));
      }
      const count=(await listed()).length,textItem=items.find(item=>item.kind==='text');
      await test((_electron,id)=>global.__clipboardLineTest.writeClipboard([global.__clipboardLineTest.store.item(id)]),textItem.id);
      assert.equal(externalPaste('text/plain;charset=utf-8',backend).toString('utf8'),note);
      await test(()=>global.__clipboardLineTest.readClipboard());
      assert.equal(await test(()=>global.__clipboardLineTest.store.data.items.length),count);check('ClipBoardLine copies reach other applications and are not captured again');
      // Copying an item must not move it to the front or add a re-encoded twin.
      const captured=()=>test(()=>global.__clipboardLineTest.store.data.items.map(item=>[item.id,item.createdAt]));
      const copiedImage=items.find(item=>item.kind==='image'),before=await captured();
      for(const id of [textItem.id,copiedImage.id]){await test((_electron,id)=>global.__clipboardLineTest.writeClipboard([global.__clipboardLineTest.store.item(id)]),id);for(let attempt=0;attempt<3;attempt++){await test(()=>global.__clipboardLineTest.readClipboard());await new Promise(resolve=>setTimeout(resolve,200));}}
      assert.deepEqual(await captured(),before);check('copying a text or image item keeps its place on the shelf');
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

    if(backend==='wayland'){
      // Wayland has no keep-above request, so the line must not stay buried. A
      // headless compositor without input devices gives no window keyboard focus.
      await test(()=>global.__clipboardLineTest.command('show'));
      const focused=await until(()=>test(()=>{const window=global.__clipboardLineTest.getWindow();return window.isVisible()&&window.isFocused();}),Boolean,5000).then(()=>true,()=>false);
      if(focused){
        await test(({BrowserWindow})=>{const other=new BrowserWindow({width:320,height:240,title:'Other application'});global.__clipboardLineOther=other;void other.loadURL('data:text/html,other');other.show();other.focus();});
        await until(()=>test(()=>global.__clipboardLineTest.getWindow().isVisible()),value=>value===false,5000);
        check('on Wayland the line is dismissed when another window takes focus');
      }else{
        skip('on Wayland the line is dismissed when another window takes focus','the compositor gives no keyboard focus (headless session without input devices)');
        await test(()=>global.__clipboardLineTest.command('hide'));await until(()=>test(()=>global.__clipboardLineTest.getWindow().isVisible()),value=>value===false,5000);
      }
      await page.evaluate(()=>{window.__clipboardLineMotion=[];new MutationObserver(()=>window.__clipboardLineMotion.push(document.body.dataset.shelfMotion||'')).observe(document.body,{attributes:true,attributeFilter:['data-shelf-motion']});});
      await test(()=>global.__clipboardLineTest.command('show'));
      const motion=await until(()=>page.evaluate(()=>window.__clipboardLineMotion),values=>values.includes('opening')&&values.at(-1)==='',5000);
      check('reopening the line slides it down',{motion});
      await test(()=>{global.__clipboardLineOther?.destroy();delete global.__clipboardLineOther;});
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
    // Started by a desktop shortcut command, the app does that action: --copy-latest
    // copies without opening the line, --screenshot captures the screen (X11 here;
    // Wayland asks the desktop's portal). Another data folder is another instance.
    for(const action of ['--copy-latest',...(backend==='x11'?['--screenshot']:[])]){
      const cold=fs.mkdtempSync(path.join(os.tmpdir(),'clipboardline-linux-cold-')),coldArgs=['--test-mode','--test-data='+cold,action];
      const started=await electron.launch({...(executable?{executablePath:executable,args:coldArgs}:{args:[path.resolve('.'),...coldArgs]}),timeout:60000});
      try{
        await until(()=>started.evaluate(()=>!!global.__clipboardLineTest),Boolean,30000);
        const after=await started.evaluate(()=>({visible:global.__clipboardLineTest.getWindow().isVisible(),images:global.__clipboardLineTest.store.data.items.filter(item=>item.kind==='image').length}));
        if(action==='--copy-latest'){assert.equal(after.visible,false,'--copy-latest leaves the line closed');check('a cold start with --copy-latest copies without opening the line');}
        else{assert.equal(after.images,1);assert.equal(after.visible,true);check('a cold start with --screenshot captures the screen into the crop preview');}
      }finally{
        await Promise.race([started.evaluate(({app})=>{app.quit();}).catch(()=>{}),new Promise(resolve=>setTimeout(resolve,3000))]);
        await Promise.race([started.close().catch(()=>{}),new Promise(resolve=>setTimeout(resolve,10000))]);fs.rmSync(cold,{recursive:true,force:true});
      }
    }
    await page.evaluate(()=>window.clipboardLine.command('settings'));
    const sources=await until(async()=>{await page.evaluate(()=>document.querySelector('[data-settings-tab="sources"],[data-section="sources"],[data-tab="sources"]')?.click());return page.evaluate(()=>document.body.innerText);},text=>text.includes('Linux integration'));
    assert.match(sources,/Linux integration/);check('Settings shows the Linux integration status');
    const updates=await until(async()=>{await page.evaluate(()=>document.querySelector('[data-tab="updates"]')?.click());return page.evaluate(()=>document.body.innerText);},text=>text.includes('Open releases page'));
    assert.doesNotMatch(updates,/Update and reopen/);check('Updates offers the releases page instead of an in-place installer');
    // Packages must carry the pinned model; a source checkout has it once
    // scripts/prepare-windows-search-models.py has run.
    if(executable||fs.existsSync(path.join(__dirname,'..','assets','CLIP','model-source.json')))await require('./semantic-image-acceptance.cjs')({page,application,check,until,output});
    else skip('offline image search','run scripts/prepare-windows-search-models.py first');
  }finally{
    report.finishedAt=new Date().toISOString();fs.writeFileSync(path.join(output,'linux-runtime.json'),JSON.stringify(report,null,2)+'\n');
    second?.kill();releaseOwners();
    // The window hides instead of closing until the app is quitting.
    await Promise.race([application.evaluate(({app})=>{app.quit();}).catch(()=>{}),new Promise(resolve=>setTimeout(resolve,3000))]);
    await Promise.race([application.close().catch(()=>{}),new Promise(resolve=>setTimeout(resolve,10000))]);fs.rmSync(data,{recursive:true,force:true});
  }
}
main().then(()=>process.exit(0),error=>{console.error(error.stack||error.message);report.error=String(error.message).slice(0,2000);fs.writeFileSync(path.join(output,'linux-runtime.json'),JSON.stringify(report,null,2)+'\n');process.exit(1);});
