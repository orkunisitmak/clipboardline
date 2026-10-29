'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),os=require('node:os');
const {_electron}=require('../../windows/node_modules/playwright');
if(process.platform!=='linux'||process.env.CLIPBOARDLINE_ISOLATED_DISPLAY!=='1')throw new Error('Run in an isolated Xvfb desktop with CLIPBOARDLINE_ISOLATED_DISPLAY=1; never use your personal clipboard.');
const root=path.resolve(__dirname,'../..'),data=fs.mkdtempSync(path.join(os.tmpdir(),'clipboardline-linux-'));
const output=path.join(root,'validation/linux',process.env.CLIPBOARDLINE_EXECUTABLE?'packaged':'source');fs.mkdirSync(output,{recursive:true});
const checks=[],errors=[];
const key=keys=>require('node:child_process').execFileSync(process.env.CLIPBOARDLINE_XDOTOOL||'xdotool',['key','--clearmodifiers',keys]);let application,fixture,page;
const report={sourceRevision:process.env.GITHUB_SHA||require('node:child_process').execFileSync('git',['rev-parse','HEAD'],{cwd:root,encoding:'utf8'}).trim(),platform:'linux',hostPlatform:process.platform,mode:process.env.CLIPBOARDLINE_EXECUTABLE?'packaged':'source',checks,errors};
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function until(read,predicate=Boolean,timeout=15000){const deadline=Date.now()+timeout;let value;do{value=await read();if(predicate(value))return value;await delay(50);}while(Date.now()<deadline);throw new Error('Timed out waiting for test state: '+JSON.stringify(value));}
const check=name=>{checks.push(name);console.log('PASS '+name);};
const command=(action,payload={})=>page.evaluate(({action,payload})=>window.clipboardLine.command(action,payload),{action,payload});
async function start(){
 application=await _electron.launch({...(process.env.CLIPBOARDLINE_EXECUTABLE?{executablePath:path.resolve(process.env.CLIPBOARDLINE_EXECUTABLE)}:{}),args:[...(process.env.CLIPBOARDLINE_EXECUTABLE?[]:['--ozone-platform=x11',path.join(root,'windows')]),'--test-mode','--test-tray','--test-data='+path.join(data,'library')],timeout:60000});
 page=await application.firstWindow();page.on('pageerror',error=>errors.push(error.message));
 await until(()=>application.evaluate(()=>!!global.__clipboardLineTest));
 await page.waitForFunction(()=>!!window.clipboardLine);
}
async function writeText(text){await fixture.evaluate(async({clipboard},value)=>clipboard.writeText(value),text);}
async function capture(){await application.evaluate(()=>global.__clipboardLineTest.readClipboard());return page.evaluate(()=>window.clipboardLine.state());}
async function main(){
 fixture=await _electron.launch({args:['--ozone-platform=x11',path.join(__dirname,'clipboard-fixture.cjs'),'--test-data='+path.join(data,'receiver')],timeout:30000});
 const receiver=await fixture.firstWindow();await writeText('Synthetic text before collection starts');
 await start();let state=await page.evaluate(()=>window.clipboardLine.state());assert.equal(state.platform,'linux');assert.equal(state.settings.captureText,false);assert.equal(state.settings.captureImages,false);assert.equal(state.items.length,0);assert.equal(state.update.status,'manual');assert.equal(await application.evaluate(()=>!!global.__clipboardLineTest.getTray().tray),true);
 assert.deepEqual(await page.evaluate(()=>window.clipboardLine.diagnostics()),{sandboxed:true,contextIsolated:true});
 check('Linux application starts with isolated data, opt-in image/text capture and sandboxed renderer');
 await command('setSettings',{patch:{captureText:true,captureImages:true,captureLinks:true,fetchLinkMetadata:false,indexImages:false,openAfterScreenshot:false}});
 state=await capture();assert.equal(state.items.length,0);check('enabling a watcher skips the previous clipboard');
 await fixture.evaluate(async({clipboard})=>clipboard.selection.writeText('Synthetic PRIMARY selection only'));
 assert.equal((await capture()).items.length,0);check('PRIMARY selection is never collected');
 const sequence=await application.evaluate(()=>global.__clipboardLineTest.native.clipboardSequence());
 const text='Synthetic Linux UTF-8: Türkçe 🌿\nSecond line';await writeText(text);
 await until(()=>application.evaluate(()=>global.__clipboardLineTest.native.clipboardSequence()),value=>value!==sequence);
 state=await capture();const item=state.items.find(value=>value.text===text);assert.ok(item);
 check('external X11 clipboard ownership advances the native generation and preserves UTF-8 text');
 const count=state.items.length;
 for(const format of ['x-kde-passwordManagerHint','org.nspasteboard.ConcealedType','ExcludeClipboardContentFromMonitorProcessing']){
  await fixture.evaluate(async({clipboard,ClipboardItem},{format})=>{await clipboard.write([new ClipboardItem({'text/plain':new Blob(['Synthetic private sentinel']),['electron application/osclipboard;format="'+format+'"']:new Blob(['1'])})]);},{format});
  assert.equal((await capture()).items.length,count);
 }
 check('external password/concealed/history-excluded clipboard formats never enter history');
 await writeText('https://example.com/synthetic-linux');state=await capture();assert.ok(state.items.some(value=>value.kind==='link'&&value.url==='https://example.com/synthetic-linux'));
 const png=await page.evaluate(()=>{const canvas=document.createElement('canvas');canvas.width=320;canvas.height=240;const context=canvas.getContext('2d');context.fillStyle='#198c4d';context.fillRect(0,0,320,240);context.fillStyle='#fff';context.font='32px sans-serif';context.fillText('LINUX TEST',20,120);return canvas.toDataURL();});
 await fixture.evaluate(async({clipboard,ClipboardItem,nativeImage},url)=>{await clipboard.write([new ClipboardItem({'image/png':new Blob([nativeImage.createFromDataURL(url).toPNG()],{type:'image/png'})})]);},png);
 state=await capture();const image=state.items.find(value=>value.kind==='image');assert.ok(image);assert.equal(await application.evaluate((_electron,id)=>process.getBuiltinModule('node:fs').existsSync(global.__clipboardLineTest.store.mediaPath(id)),image.id),true);
 check('standalone links and full-resolution external images enter their correct shelves');
 const recognized=await command('ocr',{id:image.id});assert.match(recognized.result?.text||'',/LINUX.*TEST/i);check('offline English/Turkish Tesseract recognizes actual image pixels');
 await command('copy',{ids:[item.id],keepOpen:true});assert.equal(await fixture.evaluate(({clipboard})=>clipboard.readText()),text);const ownCount=(await capture()).items.length;
 assert.equal((await capture()).items.length,ownCount);check('copy reaches another process and own copies are not recaptured');
 await application.evaluate(()=>global.__clipboardLineTest.enableShortcuts());await command('hide');
 await fixture.evaluate(({BrowserWindow})=>{const window=BrowserWindow.getAllWindows()[0];window.show();window.focus();});
 key('ctrl+alt+t');await until(()=>page.evaluate(()=>window.clipboardLine.state()),value=>value.windowVisible);
 await command('copy',{ids:[item.id]});await until(()=>fixture.evaluate(({BrowserWindow})=>BrowserWindow.getAllWindows()[0].isFocused()));
 await receiver.locator('textarea').focus();key('ctrl+v');await until(()=>receiver.locator('textarea').inputValue(),value=>value===text);
 key('ctrl+alt+s');await page.locator('#search-input').waitFor({state:'visible'});await page.keyboard.press('Escape');
 check('real X11 global shortcuts open shelves/search and normal copy returns focus for manual Ctrl-V');
 await command('pin',{ids:[item.id]});await command('tag',{ids:[item.id],tags:['linux-test']});
 await command('library');await page.locator('[data-item-id="'+item.id+'"]').first().waitFor({state:'visible'});
 await page.screenshot({path:path.join(output,'library.png')});check('Library renders captured content, pins and tags in a normal window');
 const beforePaste=await fixture.evaluate(({clipboard})=>clipboard.readText());const rejected=await command('paste',{ids:[item.id]});assert.ok(rejected.result?.error);assert.equal(await fixture.evaluate(({clipboard})=>clipboard.readText()),beforePaste);
 check('unsupported direct paste refuses before changing the clipboard or sending input');
 const second=await application.evaluate(({nativeImage})=>global.__clipboardLineTest.store.insert('image',nativeImage.createFromDataURL('data:image/png;base64,'+process.getBuiltinModule('node:fs').readFileSync(process.getBuiltinModule('node:path').join(global.__clipboardLineTest.store.directory,'media',global.__clipboardLineTest.store.data.items.find(value=>value.kind==='image').imageFile)).toString('base64')).resize({width:100}).toPNG()).id);
 const batch=await command('copy',{ids:[image.id,second],keepOpen:true});assert.ok(!batch.result?.error,batch.result?.error);
 const fileCopy=await fixture.evaluate(async({clipboard})=>{const entries=await clipboard.read(),entry=entries.find(value=>value.types.some(type=>type.includes('text/uri-list')));return{types:entries.flatMap(value=>value.types),uris:entry?await(await entry.getType(entry.types.find(type=>type.includes('text/uri-list')))).text():''};});
 assert.equal(fileCopy.uris.trim().split('\r\n').length,2);assert.ok(fileCopy.types.includes('image/png'));assert.equal((await capture()).items.length,batch.items.length);
 check('multi-image copy publishes two file URIs plus a raster fallback without recapture');
 // Exercise the same real editor acceptance used by Windows, including pixel comparisons.
 await command('show');await command('copy',{ids:[image.id],keepOpen:true});
 await require('../../windows/tests/image-editor-compositor-acceptance.cjs').exerciseEditor({page,id:image.id,width:320,height:240,until});
 check('real canvas markup/crop exports exact pixels and preserves immutable originals');
 await page.locator('[data-action="close-preview"]').click();await page.locator('#preview-dialog').waitFor({state:'hidden'});
 const recorded=await application.evaluate(async(_electron,file)=>{const h=global.__clipboardLineTest,item=await h.importFile(file);await h.command('show');return h.state().items.find(value=>value.id===item.id);},path.join(root,'windows/tests/fixtures/recordings/synthetic-rgb-tone.mp4'));
 await page.locator('[data-shelf="image"] [data-item-id="'+recorded.id+'"]').click();await page.keyboard.press('Space');
 const video=page.locator('#preview-video');await video.waitFor({state:'visible'});await until(()=>video.evaluate(player=>({ready:player.readyState,duration:player.duration,error:player.error?.code})),value=>value.ready>=2&&Math.abs(value.duration-6)<.3);
 await video.evaluate(async player=>{player.muted=true;await player.play();});await until(()=>video.evaluate(player=>player.currentTime),value=>value>.1);await video.evaluate(player=>player.pause());
 const trimmed=await command('trimRecording',{id:recorded.id,sourceFingerprint:recorded.sourceFingerprint,startMs:2000,endMs:4000});assert.ok(!trimmed.result?.error,trimmed.result?.error);assert.ok(Math.abs(trimmed.items.find(value=>value.id===recorded.id).durationMs-2000)<200);
 await page.keyboard.press('Escape');check('recording imports, plays through Electron, and trims to a managed derivative');
 const screenshot=await command('capture');assert.ok(screenshot.result?.id,screenshot.result?.error);await page.keyboard.press('Escape');check('desktop capture produces an image from the isolated X11 desktop');
 await require('../../windows/tests/semantic-image-acceptance.cjs')({page,application,check,until,output});
 await command('show');await page.screenshot({path:path.join(output,'shelves.png')});
 await command('settings');await page.locator('[data-action="settings-tab"][data-tab="updates"]').click();assert.match(await page.locator('.settings-main').innerText(),/Linux packages are updated manually/);
 await command('checkUpdates');assert.equal((await page.evaluate(()=>window.clipboardLine.state())).update.status,'manual');
 assert.equal(await page.evaluate(async()=>{try{await fetch('https://example.com');return false;}catch{return true;}}),true);
 check('Linux updates stay manual and renderer network access remains blocked');
 await application.close();application=null;await start();state=await page.evaluate(()=>window.clipboardLine.state());assert.ok(state.items.find(value=>value.id===item.id&&value.pinned&&value.tags.includes('linux-test')));assert.ok(state.items.find(value=>value.id===image.id&&value.crop));
 assert.equal(fs.statSync(path.join(data,'library')).mode&0o777,0o700);assert.equal(fs.statSync(path.join(data,'library/media')).mode&0o777,0o700);
 check('restart preserves organization and editable image metadata with private filesystem permissions');
 assert.deepEqual(errors,[]);report.passed=true;
}
main().catch(error=>{report.passed=false;report.error=error.stack;console.error(error);process.exitCode=1;}).finally(async()=>{
 await application?.close().catch(()=>{});await fixture?.close().catch(()=>{});fs.writeFileSync(path.join(output,'runtime.json'),JSON.stringify(report,null,2)+'\n');fs.rmSync(data,{recursive:true,force:true});
});
