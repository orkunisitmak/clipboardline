'use strict';
// This test intentionally fails outside Windows. A Mac cross-package is not
// accepted as proof that the real Windows application and clipboard work.
const assert=require('node:assert/strict');
const fs=require('node:fs');const path=require('node:path');const os=require('node:os');const crypto=require('node:crypto');const {spawn}=require('node:child_process');
const {_electron:electron}=require('playwright');
const {windowsEnvironment}=require('../lib/windows-environment.cjs');
const appIconAcceptance=require('./app-icon-acceptance.cjs');
const statusTrayAcceptance=require('./status-tray-acceptance.cjs');
const shelfPerformanceAcceptance=require('./shelf-performance-acceptance.cjs');
const expectedVersion=require('../package.json').version;
const keyboardLibrary=require('./keyboard-library-acceptance.cjs');
const shortcutParity=require('./shortcut-parity-acceptance.cjs');
const libraryPreview=require('./library-preview-acceptance.cjs');
const libraryKeyboardAcceptance=require('./library-keyboard-acceptance.cjs');
const imageEditorNativeAcceptance=require('./image-editor-native-acceptance.cjs');
const historyCleanupNativeAcceptance=require('./history-cleanup-native-acceptance.cjs');
const textPreview=require('./text-preview-acceptance.cjs');
const scrollStateAcceptance=require('./scroll-state-acceptance.cjs');
const libraryFolderDrag=require('./library-folder-drag-acceptance.cjs');
const nativeVideo=require('./native-video-acceptance.cjs');
const videoUI=require('./video-ui-acceptance.cjs');
const semanticImages=require('./semantic-image-acceptance.cjs');
const nativeDrag=require('./native-drag-acceptance.cjs');
const {waitForImageEditorRaster}=require('./image-editor-ready.cjs');
const edgeConsumer=require('./consumer-edge-acceptance.cjs');
const notepadConsumer=require('./notepad-acceptance.cjs');
if(process.platform!=='win32')throw new Error('Run native acceptance on the actual Windows runner.');
const output=path.resolve(process.env.CLIPBOARDLINE_VALIDATION||'validation');fs.mkdirSync(output,{recursive:true});
const data=fs.mkdtempSync(path.join(os.tmpdir(),'clipboardline-runtime-'));
const report={platform:process.platform,arch:process.arch,node:process.version,sourceRevision:process.env.GITHUB_SHA||'',packaged:!!process.env.CLIPBOARDLINE_EXECUTABLE,checks:[],startedAt:new Date().toISOString()};
let application,fixture,otherFixture,activePage;
const check=(name,details={})=>{report.checks.push({name,passed:true,...details});console.log('PASS '+name);};
async function until(reader,predicate,timeout=15000){const end=Date.now()+timeout;let value;while(Date.now()<end){try{value=await reader();if(predicate(value))return value;}catch{}await new Promise(resolve=>setTimeout(resolve,100));}throw new Error('Timed out waiting for native test state: '+JSON.stringify(value));}
async function waitForCropBox(page,viewport,raster={width:900,height:220}){
  let previous='';
  const ready=await until(async()=>{
    // Resolve the canvas and measure it in one renderer task. A clean-preview
    // resize can replace the DOM node between a locator check and box lookup.
    const value=await page.evaluate(({viewport,raster})=>{
      const canvas=document.getElementById('markup-canvas');if(!canvas)return{ready:false,reason:'canvas missing'};
      const rect=canvas.getBoundingClientRect(),style=getComputedStyle(canvas),box={x:rect.x,y:rect.y,width:rect.width,height:rect.height};
      const currentViewport={width:innerWidth,height:innerHeight},currentRaster={width:canvas.width,height:canvas.height};
      const hittable=document.elementFromPoint(rect.x+rect.width/2,rect.y+rect.height/2)===canvas;
      return{box,viewport:currentViewport,raster:currentRaster,display:style.display,visibility:style.visibility,hittable,ready:canvas.isConnected&&currentViewport.width===viewport.width&&currentViewport.height===viewport.height&&currentRaster.width===raster.width&&currentRaster.height===raster.height&&rect.width>100&&rect.height>30&&rect.left>=0&&rect.top>=0&&rect.right<=innerWidth&&rect.bottom<=innerHeight&&style.display!=='none'&&style.visibility==='visible'&&hittable};
    },{viewport,raster});
    const signature=JSON.stringify({box:value.box,viewport:value.viewport,raster:value.raster});const stable=value.ready&&previous===signature;previous=value.ready?signature:'';return{...value,stable};
  },value=>value.stable);
  return ready.box;
}
async function main(){
  const args=['--test-mode','--test-data='+data,'--test-tray'];
  application=await electron.launch({...(process.env.CLIPBOARDLINE_EXECUTABLE?{executablePath:path.resolve(process.env.CLIPBOARDLINE_EXECUTABLE)}:{args:[path.resolve('.'),...args]}),...(process.env.CLIPBOARDLINE_EXECUTABLE?{args}:{}),timeout:60000});
  const page=await application.firstWindow();activePage=page;await page.waitForFunction(()=>!!window.clipboardLine);
  report.rendererErrors=[];page.on('pageerror',error=>{if(report.rendererErrors.length<20)report.rendererErrors.push(String(error.stack||error.message).slice(0,2000));});
  report.rendererConsole=[];page.on('console',entry=>{if(entry.type()==='error'&&report.rendererConsole.length<20)report.rendererConsole.push(entry.text().slice(0,2000));});
  await until(()=>application.evaluate(()=>!!global.__clipboardLineTest),Boolean);
  const nativeInitialization=await application.evaluate(async()=>{try{return{focus:await global.__clipboardLineTest.native.capture()};}catch(error){return{error:error.message};}});assert.ok(!nativeInitialization.error,JSON.stringify(nativeInitialization));check('native UIA focus bridge initializes Microsoft system providers');
  const nativeFocusPolicy=await application.evaluate(()=>global.__clipboardLineTest.native.selfTestFocusPolicy());assert.equal(nativeFocusPolicy.ok,true);assert.equal(nativeFocusPolicy.passed,12);assert.equal(nativeFocusPolicy.capturePassed,30);check('native IA2 policy rejects readonly/protected/disabled/defunct and bounded BUSY-document capture keeps the first stable editable identity');
  await appIconAcceptance({application,check,output});
  await statusTrayAcceptance({page,application,check,until,output});
  await shelfPerformanceAcceptance({page,application,check,until,output});
  await nativeVideo.runNativeVideo({outputDirectory:path.join(output,'video-native')});check('native Windows MP4/MOV probe, precise trim, decoded audio, cancellation and unsupported-codec rejection preserve original recordings');
  const preferences=await page.evaluate(()=>window.clipboardLine.diagnostics());
  assert.equal(preferences.contextIsolated,true);assert.equal(preferences.sandboxed,true);
  assert.equal(await page.evaluate(()=>typeof require),'undefined');assert.equal(await page.evaluate(()=>typeof process),'undefined');check('sandbox and isolated, typed preload only');
  const before=await page.evaluate(()=>window.clipboardLine.state());assert.equal(before.version,expectedVersion);
  const licenses=await application.evaluate(({app})=>{if(!app.isPackaged)return null;const fs=process.getBuiltinModule('node:fs'),path=process.getBuiltinModule('node:path');return{mit:fs.readFileSync(path.join(process.resourcesPath,'LICENSE.txt'),'utf8').includes('Alejandro Buján'),notices:fs.existsSync(path.join(process.resourcesPath,'THIRD_PARTY_NOTICES.md')),apache:fs.readFileSync(path.join(process.resourcesPath,'licenses','LICENSE-Tesseract-core-and-data.txt'),'utf8').includes('Apache License'),chromium:fs.existsSync(path.join(process.resourcesPath,'..','LICENSES.chromium.html'))};});
  if(licenses){assert.ok(licenses.mit&&licenses.notices&&licenses.apache&&licenses.chromium,JSON.stringify(licenses));check('installed MIT/Apache/Electron/Chromium licensing notices are present');}
  assert.equal(before.settings.captureText,false);assert.equal(before.settings.captureImages,false);assert.equal(before.settings.captureLinks,true);assert.equal(before.settings.fetchLinkMetadata,true);
  await page.evaluate(()=>window.clipboardLine.command('setSettings',{patch:{captureText:true,captureImages:true,captureLinks:true,fetchLinkMetadata:false}}));
  await application.evaluate(async({clipboard})=>{await clipboard.writeText('Windows clipboard text acceptance');await global.__clipboardLineTest.readClipboard();});
  let state=await page.evaluate(()=>window.clipboardLine.state());const textItem=state.items.find(i=>i.text==='Windows clipboard text acceptance');assert.ok(textItem);check('real native text clipboard capture');
  await application.evaluate(async({clipboard})=>{await clipboard.writeText('A different copied text');await global.__clipboardLineTest.readClipboard();await clipboard.writeText('Windows clipboard text acceptance');await global.__clipboardLineTest.readClipboard();});
  state=await page.evaluate(()=>window.clipboardLine.state());assert.equal(state.items.filter(i=>i.text==='Windows clipboard text acceptance').length,1);assert.equal(state.items[0].id,textItem.id);check('exact text recopy deduplicates and moves newest first');
  await page.evaluate(id=>window.clipboardLine.command('name',{id,name:'Named synthetic key'}),textItem.id);
  const folderState=await page.evaluate(()=>window.clipboardLine.command('createFolder',{name:'Acceptance'}));const folder=folderState.result;
  await page.evaluate(({id,folderId})=>window.clipboardLine.command('folder',{ids:[id],folderId}),{id:textItem.id,folderId:folder.id});
  await page.evaluate(id=>window.clipboardLine.command('tag',{ids:[id],tags:['test','work']}),textItem.id);
  await page.evaluate(id=>window.clipboardLine.command('remove',{ids:[id]}),textItem.id);
  state=await page.evaluate(()=>window.clipboardLine.command('undo'));assert.equal(state.items.find(i=>i.id===textItem.id).hiddenFromShelf,false);check('pin/name/folder/tag/remove/undo persist through real IPC');
  const textCopy=await page.evaluate(id=>window.clipboardLine.command('copy',{ids:[id],keepOpen:true}),textItem.id);assert.ok(!textCopy.result?.error);
  assert.equal(await application.evaluate(async({clipboard})=>await clipboard.readText()),textItem.text);
  const count=textCopy.items.length;await application.evaluate(()=>global.__clipboardLineTest.readClipboard());assert.equal((await page.evaluate(()=>window.clipboardLine.state())).items.length,count);check('real text copy and own-copy loop suppression');
  await application.evaluate(async({clipboard,ClipboardItem})=>{await clipboard.write([new ClipboardItem({'text/plain':new Blob(['SYNTHETIC_PRIVATE_TEST']), 'electron application/osclipboard;format="ExcludeClipboardContentFromMonitorProcessing"':new Blob([Buffer.from([1])])})]);await global.__clipboardLineTest.readClipboard();});
  assert.ok(!(await page.evaluate(()=>window.clipboardLine.state())).items.some(i=>i.text==='SYNTHETIC_PRIVATE_TEST'));check('private clipboard marker is excluded');
  await require('./clipboard-admission-acceptance.cjs')({application,check});
  await page.evaluate(()=>window.clipboardLine.command('hide'));await page.evaluate(()=>window.clipboardLine.command('show'));
  await until(()=>page.locator('[data-shelf="text"] .card.focused').getAttribute('data-item-id'),id=>id===textItem.id);await page.keyboard.press('Space');await page.locator('#preview-dialog').waitFor({state:'visible'});assert.equal(await page.locator('#preview-dialog').getAttribute('aria-label'),'Named synthetic key');await page.keyboard.press('Escape');
  check('fresh opening focuses the first nonempty shelf and Space previews text when Images is empty');
  const dataUrl=await page.evaluate(()=>{const canvas=document.createElement('canvas');canvas.width=900;canvas.height=220;const c=canvas.getContext('2d');c.fillStyle='#ffffff';c.fillRect(0,0,900,220);c.fillStyle='#000000';c.font='bold 64px Arial';c.fillText('HELLO CLIPBOARDLINE 42',20,130);return canvas.toDataURL('image/png');});
  await application.evaluate(async({clipboard,ClipboardItem,nativeImage},value)=>{const image=nativeImage.createFromDataURL(value);await clipboard.write([new ClipboardItem({'image/png':new Blob([image.toPNG()],{type:'image/png'})})]);await global.__clipboardLineTest.readClipboard();},dataUrl);
  state=await page.evaluate(()=>window.clipboardLine.state());const imageItem=state.items.find(i=>i.kind==='image');assert.ok(imageItem);check('real native image clipboard capture');
  const media=await application.evaluate(async({net},url)=>{const response=await net.fetch(url);return{status:response.status,length:(await response.arrayBuffer()).byteLength,cors:response.headers.get('Access-Control-Allow-Origin')};},imageItem.mediaUrl);assert.equal(media.status,200);assert.ok(media.length>1000);assert.equal(media.cors,'null');
  const localMedia=await application.evaluate(async({net},url)=>{const response=await net.fetch(url,{headers:{Origin:'file://'}});return{status:response.status,cors:response.headers.get('Access-Control-Allow-Origin')};},imageItem.mediaUrl);assert.deepEqual(localMedia,{status:200,cors:'file://'});
  const blocked=await application.evaluate(async({net},url)=>({path:(await net.fetch('appmedia://media/../../library.json')).status,origin:(await net.fetch(url,{headers:{Origin:'https://example.com'}})).status,post:(await net.fetch(url,{method:'POST'})).status}),imageItem.mediaUrl);assert.deepEqual(blocked,{path:404,origin:404,post:404});check('managed media protocol serves images and rejects path traversal, remote origins and writes');
  await page.evaluate(id=>window.clipboardLine.command('copy',{ids:[id],keepOpen:true}),imageItem.id);
  const dimensions=await application.evaluate(async({clipboard,nativeImage})=>{const entries=await clipboard.read();const item=entries.find(i=>i.types.includes('image/png'));return nativeImage.createFromBuffer(Buffer.from(await(await item.getType('image/png')).arrayBuffer())).getSize();});assert.deepEqual(dimensions,{width:900,height:220});check('real image copy preserves full raster dimensions');
  const ocrState=await page.evaluate(id=>window.clipboardLine.command('ocr',{id}),imageItem.id);assert.ok(!ocrState.result?.error,ocrState.result?.error);assert.match(ocrState.result.text,/HELLO\s+CLIPBOARDLINE\s+42/i);check('bundled English/Turkish OCR worker recognizes real image locally');
  const edited=await page.evaluate(()=>{const c=document.createElement('canvas');c.width=400;c.height=100;const g=c.getContext('2d');g.fillStyle='orange';g.fillRect(0,0,400,100);g.fillStyle='red';g.fillRect(20,20,100,50);return c.toDataURL('image/png');});
  const editState=await page.evaluate(({id,dataUrl})=>window.clipboardLine.command('saveImage',{id,dataUrl,crop:{x:10,y:10,width:400,height:100},annotations:[{type:'rectangle',x:20,y:20,width:100,height:50,color:'#ff0000'}]}),{id:imageItem.id,dataUrl:edited});assert.ok(!editState.result?.error);assert.equal(editState.items.find(i=>i.id===imageItem.id).annotations.length,1);check('edited crop/markup output and original persist separately');
  await page.evaluate(()=>window.clipboardLine.command('show'));
  await page.locator(`[data-shelf="image"] [data-item-id="${imageItem.id}"]`).click();await page.keyboard.press('Space');await page.locator('#preview-dialog').waitFor({state:'visible'});await page.keyboard.press('c');
  const canvas=page.locator('#markup-canvas');await canvas.waitFor({state:'visible'});
  await waitForImageEditorRaster(page,{width:900,height:220});
  const previewBounds=await application.evaluate(()=>global.__clipboardLineTest.getWindow().getBounds());await application.evaluate(()=>global.__clipboardLineTest.getWindow().setBounds({x:0,y:0,width:760,height:680}));await page.waitForFunction(()=>innerWidth===760);
  const previewControls=await page.evaluate(()=>['previous','next','close-preview'].map(action=>{const element=document.querySelector('.preview-toolbar [data-action="'+action+'"]'),rect=element.getBoundingClientRect(),hit=document.elementFromPoint(rect.x+rect.width/2,rect.y+rect.height/2);return{action,left:rect.left,right:rect.right,top:rect.top,bottom:rect.bottom,visible:rect.left>=0&&rect.right<=innerWidth&&rect.top>=0&&rect.bottom<=innerHeight&&hit?.closest('[data-action]')===element};}));assert.ok(previewControls.every(control=>control.visible),JSON.stringify(previewControls));
  await application.evaluate((_electron,bounds)=>global.__clipboardLineTest.getWindow().setBounds(bounds),previewBounds);await page.waitForFunction(width=>innerWidth===width,previewBounds.width);
  // Resize rebuilds the clean preview. Wait for the replacement canvas to be
  // redrawn from the original before measuring or sending a crop gesture.
  await waitForImageEditorRaster(page,{width:900,height:220});check('narrow preview keeps navigation and close controls visible and hit-testable');
  const box=await waitForCropBox(page,previewBounds);assert.ok(box.width>100&&box.height>30,JSON.stringify(box));
  await page.evaluate(()=>{window.__cropPointerDiagnostics=[];window.__nativeCropCanvas=null;for(const type of ['pointerdown','pointermove','pointerup'])document.addEventListener(type,event=>{if(type==='pointerdown'&&event.target.id==='markup-canvas')window.__nativeCropCanvas=event.target;if(!window.__nativeCropCanvas)return;const canvas=document.getElementById('markup-canvas'),rect=canvas?.getBoundingClientRect();window.__cropPointerDiagnostics.push({type,x:event.clientX,y:event.clientY,sameCanvas:canvas===window.__nativeCropCanvas,raster:canvas?{width:canvas.width,height:canvas.height}:null,box:rect?{x:rect.x,y:rect.y,width:rect.width,height:rect.height}:null,viewport:{width:innerWidth,height:innerHeight}});},{capture:true});});
  await page.mouse.move(box.x+box.width*.60,box.y+box.height*.20);await page.mouse.down();
  // Semantic indexing and OCR can emit state while a real gesture is in flight.
  // Deliberately deliver one; the editor must retain its live canvas and size.
  await page.evaluate(()=>window.clipboardLine.command('setSettings',{patch:{captureText:true}}));
  assert.equal(await page.evaluate(()=>document.getElementById('markup-canvas')===window.__nativeCropCanvas),true,'State broadcasts must not replace a canvas during its pointer gesture');
  await page.mouse.move(box.x+box.width*.90,box.y+box.height*.80,{steps:6});await page.mouse.up();
  const cropPointerDiagnostics=await page.evaluate(()=>{const events=window.__cropPointerDiagnostics;window.__nativeCropCanvas=null;return events;});
  const exportable=await canvas.evaluate(element=>{try{return{png:element.toDataURL('image/png').startsWith('data:image/png;base64,')};}catch(error){return{error:error.name+': '+error.message};}});assert.equal(exportable.png,true,JSON.stringify(exportable));
  await page.screenshot({path:path.join(output,'synthetic-crop.png')});
  await page.keyboard.press('Enter');await canvas.waitFor({state:'hidden'});
  const cropped=(await page.evaluate(()=>window.clipboardLine.state())).items.find(value=>value.id===imageItem.id);assert.ok(cropped.crop);
  for(const [key,expected]of Object.entries({x:540,y:44,width:270,height:132}))assert.ok(Math.abs(cropped.crop[key]-expected)<=2,JSON.stringify({crop:cropped.crop,box,events:cropPointerDiagnostics}));
  const raster=await application.evaluate(async({net,nativeImage},{current,original})=>{const read=async url=>nativeImage.createFromBuffer(Buffer.from(await(await net.fetch(url)).arrayBuffer())).getSize();return{current:await read(current),original:await read(original)};},{current:cropped.mediaUrl,original:cropped.originalMediaUrl});
  assert.deepEqual(raster.current,{width:cropped.crop.width,height:cropped.crop.height});assert.deepEqual(raster.original,{width:900,height:220});
  await page.keyboard.press('Escape');await page.locator('#preview-dialog').waitFor({state:'hidden'});check('real crop canvas drag saves original-coordinate bounds and cropped raster');
  await imageEditorNativeAcceptance({page,application,until,check,output});
  await page.locator(`[data-shelf="image"] [data-item-id="${imageItem.id}"]`).click();await page.keyboard.press('Space');await page.locator('#preview-dialog').waitFor({state:'visible'});await page.keyboard.press('c');await canvas.waitFor({state:'visible'});await waitForImageEditorRaster(page,{width:900,height:220});
  const tabCropBox=await waitForCropBox(page,previewBounds);assert.ok(tabCropBox.width>100&&tabCropBox.height>30,JSON.stringify(tabCropBox));
  await page.mouse.move(tabCropBox.x+tabCropBox.width*.15,tabCropBox.y+tabCropBox.height*.25);await page.mouse.down();await page.mouse.move(tabCropBox.x+tabCropBox.width*.45,tabCropBox.y+tabCropBox.height*.75,{steps:6});await page.mouse.up();
  await page.keyboard.press('Tab');await until(()=>page.locator('#preview-dialog').getAttribute('aria-label'),label=>label==='Named synthetic key');
  assert.equal(await page.locator('#markup-canvas').count(),0);assert.equal(await page.locator('.preview-toolbar [data-action="image-tool"]').count(),0);
  const visibleText=await page.locator('#preview-dialog .preview-text').textContent();assert.equal(visibleText,textItem.text);
  const tabCropped=(await page.evaluate(()=>window.clipboardLine.state())).items.find(value=>value.id===imageItem.id);for(const [key,expected]of Object.entries({x:135,y:55,width:270,height:110}))assert.ok(Math.abs(tabCropped.crop[key]-expected)<=2,JSON.stringify(tabCropped.crop));
  const tabRaster=await application.evaluate(async({net,nativeImage},url)=>nativeImage.createFromBuffer(Buffer.from(await(await net.fetch(url)).arrayBuffer())).getSize(),tabCropped.mediaUrl);assert.deepEqual(tabRaster,{width:tabCropped.crop.width,height:tabCropped.crop.height});assert.equal(tabCropped.annotations.length,cropped.annotations.length);
  await page.screenshot({path:path.join(output,'dirty-crop-tab-text.png')});await page.keyboard.press('Enter');await until(()=>application.evaluate(()=>global.__clipboardLineTest.getWindow().isVisible()),visible=>visible===false);
  await page.locator('#preview-dialog').waitFor({state:'hidden'});assert.equal(await page.locator('#preview-dialog').count(),0);assert.equal(await application.evaluate(async({clipboard})=>await clipboard.readText()),visibleText);check('dirty crop Tab preserves the image edit, switches to clean text preview and Enter copies that visible text then dismisses');
  await application.evaluate(async()=>{const h=global.__clipboardLineTest;h.store.insert('link','https://example.com/reference');await h.command('show');});
  await page.locator(`[data-shelf="text"] [data-item-id="${textItem.id}"]`).click();
  await page.keyboard.press('Space');await page.locator('#preview-dialog').waitFor({state:'visible'});
  await page.keyboard.press('ArrowDown');await until(()=>page.locator('#preview-dialog').getAttribute('aria-label'),label=>label.includes('example.com/reference'));
  await page.keyboard.press('ArrowUp');await until(()=>page.locator('#preview-dialog').getAttribute('aria-label'),label=>label==='Named synthetic key');
  await page.keyboard.press('p');await until(()=>page.evaluate(()=>window.clipboardLine.state()),value=>value.items.find(i=>i.id===textItem.id).pinned===false);
  await page.keyboard.press('p');await until(()=>page.evaluate(()=>window.clipboardLine.state()),value=>value.items.find(i=>i.id===textItem.id).pinned===true);
  await page.keyboard.press('s');await until(()=>page.locator('#preview-dialog').getAttribute('aria-label'),label=>label!=='Named synthetic key');
  await page.keyboard.press('Backspace');await until(()=>page.locator('#preview-dialog').getAttribute('aria-label'),label=>label==='Named synthetic key');
  check('real Space/arrows/P/S/Backspace keyboard navigation preserves preview and undo');
  await page.keyboard.press('Enter');await until(()=>application.evaluate(()=>global.__clipboardLineTest.getWindow().isVisible()),visible=>visible===false);
  assert.equal(await application.evaluate(async({clipboard})=>await clipboard.readText()),textItem.text);check('real Enter key copies preview and dismisses the host window');
  await application.evaluate(()=>global.__clipboardLineTest.command('show'));
  await page.keyboard.press('l');await until(()=>page.evaluate(()=>window.clipboardLine.state()),value=>value.view==='library');
  assert.equal(await application.evaluate(()=>global.__clipboardLineTest.getWindow().isFullScreen()),false);await page.screenshot({path:path.join(output,'library.png')});
  await page.evaluate(()=>window.clipboardLine.command('show'));await page.waitForTimeout(250);await page.screenshot({path:path.join(output,'shelves.png')});check('three kinds render in shelves and normal library window');
  await keyboardLibrary({page,application,textItem,folder,check,until,output});
  await shortcutParity({page,application,check,until,output});
  await libraryPreview({page,application,check,until,output,waitForCropBox});
  await libraryKeyboardAcceptance({page,application,check,until,output});
  await textPreview({page,application,check,until,output});
  await scrollStateAcceptance({page,application,check,until,output});
  await libraryFolderDrag({page,application,check,until,output});
  await videoUI({page,application,check,until,output});
  await semanticImages({page,application,check,until,output});
  await nativeDrag({page,application,check});
  await edgeConsumer({page,application,textItem,imageItem,check,until,report,output});
  // An actual separate WinForms process owns the destination, so focus/paste
  // cannot pass by sending synthetic keys back to the Electron test window.
  await page.evaluate(()=>window.clipboardLine.command('hide'));
  const fixtureOutput=path.join(data,'native-target.json');const ps=path.join(process.env.SystemRoot,'System32','WindowsPowerShell','v1.0','powershell.exe');
  fixture=spawn(ps,['-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',path.resolve('tests/native-fixture.ps1'),'-Output',fixtureOutput],{windowsHide:false,stdio:'ignore',env:windowsEnvironment()});
  const fixtureState=()=>JSON.parse(fs.readFileSync(fixtureOutput,'utf8'));
  const fixtureCommand=async payload=>{const serial=crypto.randomUUID(),file=fixtureOutput+'.commands';fs.writeFileSync(file+'.tmp',JSON.stringify({...payload,serial}));for(let attempt=0;;attempt++){try{fs.renameSync(file+'.tmp',file);break;}catch(error){if(!['EPERM','EACCES','EBUSY'].includes(error.code)||attempt>=20)throw error;await new Promise(resolve=>setTimeout(resolve,25));}}const result=await until(fixtureState,value=>value.lastSerial===serial);assert.equal(result.commandError,'',result.commandError);return result;};
  await until(fixtureState,s=>s.ready);
  await application.evaluate(()=>global.__clipboardLineTest.command('show'));
  const target=await application.evaluate(()=>global.__clipboardLineTest.getTarget());assert.ok(target?.editable&&!target?.secure,JSON.stringify(target));
  await application.evaluate(async({clipboard})=>await clipboard.writeText('Clipboard before empty selection'));
  const emptyPaste=await page.evaluate(()=>window.clipboardLine.command('paste',{ids:[]}));assert.ok(emptyPaste.result?.error);
  assert.deepEqual(await application.evaluate(()=>({visible:global.__clipboardLineTest.getWindow().isVisible(),focused:global.__clipboardLineTest.getWindow().isFocused()})),{visible:true,focused:true});
  assert.equal(await application.evaluate(async({clipboard})=>await clipboard.readText()),'Clipboard before empty selection');
  check('empty paste selection leaves clipboard and source focus unchanged');

  // A second window owned by the same target process is still a new user
  // destination. Let the real helper inspect that HWND before any activation.
  {
    const captured=await application.evaluate(()=>global.__clipboardLineTest.getTarget());
    assert.equal(captured.processId,fixtureState().processId);assert.equal(captured.handle,fixtureState().handle);
    await application.evaluate(()=>{const native=global.__clipboardLineTest.native;let release;const gate=new Promise(resolve=>{release=resolve;});global.__differentWindowPreparation={original:native.preparePaste,release,waiting:false};native.preparePaste=async target=>{global.__differentWindowPreparation.waiting=true;await gate;return global.__differentWindowPreparation.original(target);};});
    await application.evaluate(async({clipboard})=>clipboard.writeText('Clipboard before same-process different-window race'));
    const request=page.evaluate(id=>window.clipboardLine.command('paste',{ids:[id]}),textItem.id);
    try{
      await until(()=>application.evaluate(()=>global.__differentWindowPreparation.waiting),Boolean);
      await fixtureCommand({action:'focus-second',seed:'Second same-process editor stays unchanged',selectAll:true});
      const second=await until(fixtureState,value=>value.secondFocused&&value.foreground===value.secondHandle&&value.secondHandle!==value.handle);
      const secondFocus=await application.evaluate(()=>global.__clipboardLineTest.native.capture());
      assert.equal(secondFocus.processId,captured.processId);assert.equal(secondFocus.handle,second.secondHandle);assert.ok(secondFocus.editable&&!secondFocus.secure,JSON.stringify(secondFocus));
      await application.evaluate(()=>global.__differentWindowPreparation.release());
      const rejected=await request;assert.ok(rejected.result?.error,JSON.stringify(rejected.result));assert.match(rejected.result.error,/another window became active/i);
      assert.equal(await application.evaluate(async({clipboard})=>clipboard.readText()),'Clipboard before same-process different-window race');
      // ClipboardLine may show its error UI, but it must never activate the
      // obsolete first Form or mutate either destination along the way.
      const sourceHandle=await application.evaluate(()=>global.__clipboardLineTest.getWindow().getNativeWindowHandle().readBigUInt64LE().toString());
      // Windows may keep the user's second Form in front when it refuses the
      // source error window's activation. Either is safe; the obsolete first
      // Form must never activate. Wait for a fresh fixture tick before checking.
      const observedAt=fs.statSync(fixtureOutput).mtimeMs;
      const after=await until(()=>fs.statSync(fixtureOutput).mtimeMs>observedAt?fixtureState():null,value=>value&&(value.foreground===sourceHandle||value.foreground===second.secondHandle));
      assert.equal(after.primaryActivations,second.primaryActivations);assert.equal(after.text,second.text);assert.equal(after.plainText,second.plainText);assert.equal(after.secondText,second.secondText);
      check('same-process different-window preparation rejects without activating the captured HWND or changing clipboard and editors');
    }finally{
      await application.evaluate(()=>{const value=global.__differentWindowPreparation;if(value){value.release();global.__clipboardLineTest.native.preparePaste=value.original;delete global.__differentWindowPreparation;}});
      await page.evaluate(()=>window.clipboardLine.command('hide'));await fixtureCommand({action:'focus',target:'rich'});await application.evaluate(()=>global.__clipboardLineTest.command('show'));
    }
  }

  // Hold a real native restore in flight so reopening races with Enter in a
  // deterministic way. No fake focus result or timeout can satisfy this case.
  await application.evaluate(()=>{const h=global.__clipboardLineTest,original=h.native.restore;let release;const gate=new Promise(resolve=>{release=resolve;});global.__rapidReopen={started:false,settled:false,original,release};h.native.restore=async target=>{global.__rapidReopen.started=true;await gate;return original(target);};});
  try{
    await page.keyboard.press('ArrowDown');await until(()=>page.locator('[data-shelf="text"] .card.focused').getAttribute('data-item-id'),id=>id===textItem.id);
    await page.keyboard.press('Enter');
    await until(()=>application.evaluate(()=>({started:global.__rapidReopen.started,visible:global.__clipboardLineTest.getWindow().isVisible()})),value=>value.started&&!value.visible);
    const blocked=await application.evaluate(()=>{const h=global.__clipboardLineTest;global.__rapidReopen.reopen=h.command('show').then(value=>{global.__rapidReopen.settled=true;return value;});return{visible:h.getWindow().isVisible(),settled:global.__rapidReopen.settled};});
    assert.deepEqual(blocked,{visible:false,settled:false});
    await application.evaluate(async()=>{global.__rapidReopen.release();await global.__rapidReopen.reopen;});
    await until(()=>application.evaluate(()=>({visible:global.__clipboardLineTest.getWindow().isVisible(),focused:global.__clipboardLineTest.getWindow().isFocused()})),value=>value.visible&&value.focused);
    await until(()=>page.evaluate(()=>document.hasFocus()),Boolean);
    assert.equal(await page.locator('.card.selected').count(),1);assert.equal(await page.locator('[data-shelf="image"] .card.selected').count(),1);
    await page.keyboard.press('Space');await page.locator('#preview-dialog').waitFor({state:'visible'});
    await page.keyboard.press('ArrowDown');await until(()=>page.locator('#preview-dialog').getAttribute('aria-label'),value=>value==='Named synthetic key');
    assert.equal(await page.locator('[data-shelf="text"] .card.focused').getAttribute('data-item-id'),textItem.id);
    await page.keyboard.press('Escape');
    check('rapid Enter close and reopen waits for native restoration and retains focus, selection and arrow navigation');
  }finally{await application.evaluate(()=>{const pending=global.__rapidReopen;if(pending){pending.release();global.__clipboardLineTest.native.restore=pending.original;delete global.__rapidReopen;}});}
  await page.locator(`[data-shelf="text"] [data-item-id="${textItem.id}"]`).click();await page.keyboard.press('Control+Enter');
  await until(fixtureState,s=>s.text.includes('Windows clipboard text acceptance'));await fixtureCommand({action:'keys',keys:' TEXT_FOCUS_OK'});await until(fixtureState,s=>s.text.endsWith(' TEXT_FOCUS_OK')&&s.focused==='rich'&&s.foreground===s.handle);check('CtrlEnter text paste restores prior external editable field and keeps typing focus');
  await application.evaluate(()=>global.__clipboardLineTest.command('show'));
  await page.locator(`[data-shelf="image"] [data-item-id="${imageItem.id}"]`).click();await page.keyboard.press('Control+Enter');
  await until(fixtureState,s=>s.hasImage);await fixtureCommand({action:'keys',keys:' IMAGE_FOCUS_OK'});await until(fixtureState,s=>s.text.endsWith(' IMAGE_FOCUS_OK')&&s.focused==='rich'&&s.foreground===s.handle);check('CtrlEnter image paste works in separate native rich-text editor and keeps typing focus');
  await application.evaluate(()=>global.__clipboardLineTest.enableShortcuts());await page.evaluate(()=>window.clipboardLine.command('hide'));await fixtureCommand({action:'focus',target:'plain',seed:'Held shortcut fixture selection',selectAll:true});
  await fixtureCommand({action:'keys',keys:'^%t'});await until(()=>page.evaluate(()=>window.clipboardLine.state()),value=>value.windowVisible===true);
  const hostHandle=await application.evaluate(()=>global.__clipboardLineTest.getWindow().getNativeWindowHandle().readBigUInt64LE().toString());await until(fixtureState,value=>value.foreground===hostHandle);
  const physicalHost=await application.evaluate(async()=>({focus:await global.__clipboardLineTest.native.capture(),processId:process.pid}));assert.equal(physicalHost.focus.processId,physicalHost.processId);assert.equal(physicalHost.focus.handle,hostHandle);
  await page.locator(`[data-shelf="text"] [data-item-id="${textItem.id}"]`).click({modifiers:['Control']});
  await application.evaluate(()=>{const native=global.__clipboardLineTest.native;global.__heldInputTrace=[];global.__heldOriginalNative={preparePaste:native.preparePaste,paste:native.paste};for(const mode of ['preparePaste','paste']){const original=native[mode];native[mode]=async target=>{const trace={mode,started:new Date().toISOString()};global.__heldInputTrace.push(trace);try{const result=await original(target);trace.result=result;return result;}catch(error){trace.error=error.message;throw error;}finally{trace.completed=new Date().toISOString();}};}});
  let repeated=[];
  try{
    const held=await fixtureCommand({action:'hold-paste',duration:1800,expectedForeground:hostHandle});assert.equal(held.shortcutHeld,true);await new Promise(resolve=>setTimeout(resolve,900));assert.equal(fixtureState().shortcutHeld,true);assert.equal(fixtureState().foreground,hostHandle);
    const protectedHost=await application.evaluate(()=>({visible:global.__clipboardLineTest.getWindow().isVisible(),focused:global.__clipboardLineTest.getWindow().isFocused()}));assert.deepEqual(protectedHost,{visible:true,focused:true});
    repeated=[page.evaluate(id=>window.clipboardLine.command('paste',{ids:[id]}),textItem.id),page.evaluate(id=>window.clipboardLine.command('paste',{ids:[id]}),textItem.id),page.evaluate(id=>window.clipboardLine.command('copy',{ids:[id],keepOpen:false}),textItem.id)];
    await page.waitForTimeout(80);assert.equal(fixtureState().shortcutHeld,true);assert.deepEqual(await application.evaluate(()=>({visible:global.__clipboardLineTest.getWindow().isVisible(),focused:global.__clipboardLineTest.getWindow().isFocused()})),{visible:true,focused:true});
  }finally{await fixtureCommand({action:'release-keys'});}
  const repeatedResults=await Promise.all(repeated);report.heldInputTrace=await application.evaluate(()=>{const trace=global.__heldInputTrace;Object.assign(global.__clipboardLineTest.native,global.__heldOriginalNative);return trace;});assert.ok(repeatedResults.every(result=>!result.result?.error));assert.deepEqual(report.heldInputTrace.map(value=>value.mode),['preparePaste','paste']);await until(fixtureState,value=>value.plainText===textItem.text);
  check('held OS CtrlEnter keeps the source focused until release and repeated paste requests insert once');
  await page.evaluate(()=>window.clipboardLine.command('hide'));await fixtureCommand({action:'focus',target:'plain',seed:'Original plain fixture value',selectAll:true});
  await application.evaluate(()=>global.__clipboardLineTest.command('library'));
  await page.locator('[data-action="scope"][data-scope="saved"]').click();
  const originalLibraryText=(await page.evaluate(()=>window.clipboardLine.state())).items.find(value=>value.id===textItem.id);assert.ok(originalLibraryText&&!originalLibraryText.trashedAt&&(originalLibraryText.retainedAt||originalLibraryText.pinned||originalLibraryText.folderIds.length||originalLibraryText.tags.length),'the original captured text must remain live and retained before the Library paste test');
  const clearLibraryPasteFilters=page.locator('.library-controls [data-action="clear-filters"]');if(await clearLibraryPasteFilters.count())await clearLibraryPasteFilters.click();await page.locator('[data-action="allTypes"]').click();await until(()=>page.locator('[data-action="allTypes"]').getAttribute('aria-pressed'),value=>value==='true');if(await page.locator('#search-mode-filter').count())await until(()=>page.locator('#search-mode-filter').inputValue(),value=>value==='all');
  await page.locator(`[data-item-id="${textItem.id}"]`).click();await page.keyboard.press('Control+Enter');
  await until(fixtureState,value=>value.plainText===textItem.text);assert.equal((await page.evaluate(()=>window.clipboardLine.state())).windowVisible,false);
  check('Library CtrlEnter replaces selected text in a second native plain editor');
  await fixtureCommand({action:'focus',target:'plain',seed:'Preview selected replacement',selectAll:true});await application.evaluate(()=>global.__clipboardLineTest.command('show'));
  await page.locator(`[data-shelf="text"] [data-item-id="${textItem.id}"]`).click();await page.keyboard.press('Space');await page.locator('#preview-dialog').waitFor({state:'visible'});await page.keyboard.press('Control+Enter');
  await until(fixtureState,value=>value.plainText===textItem.text);assert.equal((await page.evaluate(()=>window.clipboardLine.state())).windowVisible,false);
  check('preview CtrlEnter returns to and replaces the exact plain-text selection');
  // A normal Library can remain visible while another application is used.
  // Return by native window focus rather than command('library'): that path
  // must capture the newly visited editor, not the previous Library opening.
  await fixtureCommand({action:'focus',target:'rich'});await application.evaluate(()=>global.__clipboardLineTest.command('library'));
  await page.locator('[data-action="scope"][data-scope="saved"]').click();
  const originalLibraryTarget=await application.evaluate(()=>global.__clipboardLineTest.getTarget());assert.ok(originalLibraryTarget.editable);
  await fixtureCommand({action:'focus',target:'plain',seed:'Mouse reentry plain selection',selectAll:true});
  const observedReentryTarget=await until(()=>application.evaluate(()=>global.__clipboardLineTest.getObservedTarget()),value=>value?.editable&&value.runtime!==originalLibraryTarget.runtime&&value.processId===originalLibraryTarget.processId);
  // The foreground fixture can legitimately hand off native activation rights.
  // A background BrowserWindow.focus() request alone may be denied by Windows.
  // Validate the exact source HWND/PID in the fixture, without invoking any app
  // browsing command or substituting the target being tested.
  const reentrySource=await application.evaluate(()=>({handle:global.__clipboardLineTest.getWindow().getNativeWindowHandle().readBigUInt64LE().toString(),processId:process.pid}));
  await fixtureCommand({action:'activate-window',...reentrySource});
  // Require actual native activation and the exact observer identity. The paste
  // command must synchronize that identity even if Electron missed its focus
  // callback; no stale rich-editor target may be reused during reentry.
  const reentry=await until(async()=>({...(await application.evaluate(()=>{const h=global.__clipboardLineTest,w=h.getWindow();return{focused:w.isFocused(),sourceHandle:w.getNativeWindowHandle().readBigUInt64LE().toString(),observed:h.getObservedTarget()};})),foreground:fixtureState().foreground}),value=>value.focused&&value.foreground===value.sourceHandle&&value.observed?.handle===observedReentryTarget.handle&&value.observed?.processId===observedReentryTarget.processId&&value.observed?.runtime===observedReentryTarget.runtime);
  assert.deepEqual(reentry.observed,observedReentryTarget);const beforeReentry=fixtureState();
  await page.locator(`[data-item-id="${textItem.id}"]`).click();await page.keyboard.press('Control+Enter');
  const pastedReentry=await until(fixtureState,value=>value.plainText===textItem.text&&value.focused==='plain'&&value.foreground===value.handle);assert.equal(pastedReentry.text,beforeReentry.text);
  await fixtureCommand({action:'keys',keys:' REENTRY_FOCUS_OK'});await until(fixtureState,value=>value.plainText.endsWith(' REENTRY_FOCUS_OK'));
  check('returning to an already visible Library captures the newly visited native editor and retains focus after paste');
  const unchanged=value=>({rich:value.text,plain:value.plainText,readonly:value.readOnlyText,passwordLength:value.passwordLength});
  for(const control of ['readonly','password']){
    await fixtureCommand({action:'focus',target:control});await application.evaluate(()=>global.__clipboardLineTest.command('show'));
    const guarded=await application.evaluate(()=>global.__clipboardLineTest.getTarget());assert.ok(control==='password'?guarded.secure:!guarded.editable,JSON.stringify(guarded));
    const beforeTarget=unchanged(fixtureState());await page.locator(`[data-shelf="text"] [data-item-id="${textItem.id}"]`).click({modifiers:['Control']});await application.evaluate(async({clipboard})=>await clipboard.writeText('Clipboard before rejected target'));
    await page.keyboard.press('Control+Enter');await until(()=>page.evaluate(()=>window.clipboardLine.state()),value=>!!value.message);
    assert.equal(await application.evaluate(async({clipboard})=>await clipboard.readText()),'Clipboard before rejected target');assert.deepEqual(unchanged(fixtureState()),beforeTarget);
    assert.equal((await page.evaluate(()=>window.clipboardLine.state())).windowVisible,true);await page.evaluate(()=>window.clipboardLine.command('hide'));
  }
  check('readonly and password destinations reject paste without changing clipboard or field contents');
  await fixtureCommand({action:'focus',target:'rich'});await application.evaluate(()=>global.__clipboardLineTest.command('show'));
  await application.evaluate(()=>{const native=global.__clipboardLineTest.native;let release;const gate=new Promise(resolve=>{release=resolve;});global.__changedPaste={original:native.validatePaste,release,waiting:false};native.validatePaste=async target=>{global.__changedPaste.waiting=true;await gate;return global.__changedPaste.original(target);};});
  const beforeChanged=unchanged(fixtureState());await application.evaluate(async({clipboard})=>await clipboard.writeText('Clipboard before changed field'));
  const changedRequest=page.evaluate(id=>window.clipboardLine.command('paste',{ids:[id]}),textItem.id);
  try{
    await until(()=>application.evaluate(()=>global.__changedPaste.waiting),Boolean);
    await fixtureCommand({action:'focus',target:'plain'});await application.evaluate(()=>global.__changedPaste.release());
    const changed=await changedRequest;assert.ok(changed.result?.error,JSON.stringify(changed.result));
    assert.equal(await application.evaluate(async({clipboard})=>await clipboard.readText()),'Clipboard before changed field');assert.deepEqual(unchanged(fixtureState()),beforeChanged);
    check('changing the captured native field during paste cancels before overwriting the clipboard');
  }finally{await application.evaluate(()=>{const value=global.__changedPaste;if(value){value.release();global.__clipboardLineTest.native.validatePaste=value.original;delete global.__changedPaste;}});}
  await application.evaluate(()=>global.__clipboardLineTest.setTarget(null));await application.evaluate(async({clipboard})=>await clipboard.writeText('Clipboard before missing target'));
  const noTarget=await page.evaluate(id=>window.clipboardLine.command('paste',{ids:[id]}),textItem.id);assert.ok(noTarget.result?.error);assert.equal(await application.evaluate(async({clipboard})=>await clipboard.readText()),'Clipboard before missing target');
  check('missing paste target is explicit and leaves clipboard and app focus unchanged');
  await page.evaluate(()=>window.clipboardLine.command('hide'));await fixtureCommand({action:'focus',target:'plain'});await application.evaluate(()=>global.__clipboardLineTest.enableShortcuts());
  await fixtureCommand({action:'keys',keys:'^%t'});await until(()=>page.evaluate(()=>window.clipboardLine.state()),value=>value.windowVisible===true);
  await fixtureCommand({action:'keys',keys:'^%t'});await until(()=>page.evaluate(()=>window.clipboardLine.state()),value=>value.windowVisible===false);
  await fixtureCommand({action:'keys',keys:'^%s'});await page.locator('#search-input').waitFor({state:'visible'});await until(()=>page.locator('#search-input').evaluate(element=>element===document.activeElement),Boolean);
  await page.keyboard.press('Escape');check('real OS global toggle and search shortcuts activate the shelves and search field');
  const globalSettings=await page.evaluate(()=>window.clipboardLine.command('setSettings',{patch:{shortcuts:{library:'Control+Alt+L',copyLatest:'Control+Alt+C'}}}));assert.ok(!globalSettings.result?.error,JSON.stringify(globalSettings.result));
  await page.evaluate(()=>window.clipboardLine.command('hide'));await fixtureCommand({action:'focus',target:'plain'});
  const expectedLatestImage=await application.evaluate(({nativeImage})=>{const h=global.__clipboardLineTest,item=h.store.data.items.filter(item=>item.kind==='image'&&!item.trashedAt&&!item.hiddenFromShelf).sort((a,b)=>b.createdAt-a.createdAt)[0];return process.getBuiltinModule('node:crypto').createHash('sha256').update(nativeImage.createFromPath(h.store.mediaPath(item.id)).toBitmap()).digest('hex');});
  await fixtureCommand({action:'keys',keys:'^%c'});
  await until(()=>application.evaluate(async({clipboard,nativeImage})=>{const entries=await clipboard.read();for(const entry of entries)if(entry.types.includes('image/png'))return process.getBuiltinModule('node:crypto').createHash('sha256').update(nativeImage.createFromBuffer(Buffer.from(await(await entry.getType('image/png')).arrayBuffer())).toBitmap()).digest('hex');return null;}),value=>value===expectedLatestImage);
  assert.equal((await page.evaluate(()=>window.clipboardLine.state())).windowVisible,false);const globalCopyTarget=await application.evaluate(()=>global.__clipboardLineTest.native.capture()),globalCopyReceiver=fixtureState();assert.ok(Number.isInteger(globalCopyTarget?.processId)&&Number.isInteger(globalCopyReceiver.processId));assert.equal(globalCopyTarget.processId,globalCopyReceiver.processId);
  await fixtureCommand({action:'keys',keys:'^%l'});await until(()=>page.evaluate(()=>window.clipboardLine.state()),value=>value.view==='library'&&value.windowVisible===true);assert.equal((await page.evaluate(()=>window.clipboardLine.state())).windowMode,'normal');
  await page.evaluate(()=>window.clipboardLine.command('setSettings',{patch:{shortcuts:{library:'',copyLatest:''}}}));await page.evaluate(()=>window.clipboardLine.command('hide'));await fixtureCommand({action:'focus',target:'plain'});await application.evaluate(async({clipboard})=>clipboard.writeText('Disabled global copy sentinel'));
  await fixtureCommand({action:'keys',keys:'^%l'});await fixtureCommand({action:'keys',keys:'^%c'});await new Promise(resolve=>setTimeout(resolve,350));assert.equal((await page.evaluate(()=>window.clipboardLine.state())).windowVisible,false);assert.equal(await application.evaluate(async({clipboard})=>clipboard.readText()),'Disabled global copy sentinel');
  check('actual optional global Library and copy-latest-image shortcuts work from another app, preserve copy focus, and stop when switched Off');
  await require('./shortcut-recording-acceptance.cjs')({page,application,check,until,fixtureCommand});
  await page.evaluate(()=>window.clipboardLine.command('hide'));await fixtureCommand({action:'focus',target:'plain'});await application.evaluate(()=>global.__clipboardLineTest.command('show'));
  const protectedTarget=await application.evaluate(()=>global.__clipboardLineTest.getTarget()),otherOutput=path.join(data,'unrelated-target.json');
  otherFixture=spawn(ps,['-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',path.resolve('tests/native-fixture.ps1'),'-Output',otherOutput],{windowsHide:false,stdio:'ignore',env:windowsEnvironment()});
  const otherState=()=>JSON.parse(fs.readFileSync(otherOutput,'utf8'));await until(otherState,value=>value.ready&&value.foreground===value.handle);
  const unrelated=await application.evaluate(async(_electron,target)=>{try{await global.__clipboardLineTest.native.preparePaste(target);return{ok:true};}catch(error){return{error:error.message};}},protectedTarget);
  assert.match(unrelated.error||'',/Another (?:application|window)/);const unrelatedAfter=otherState();assert.equal(unrelatedAfter.foreground,unrelatedAfter.handle);assert.equal(unrelatedAfter.text,'');
  const otherExited=new Promise(resolve=>otherFixture.once('exit',resolve));otherFixture.kill();await otherExited;otherFixture=null;
  check('unrelated foreground application cancels native paste without stealing its focus');
  await application.evaluate(()=>global.__clipboardLineTest.command('show'));
  const secondImage=await application.evaluate(({nativeImage},value)=>{const h=global.__clipboardLineTest;return h.store.insert('image',nativeImage.createFromDataURL(value).crop({x:0,y:0,width:150,height:100}).toPNG()).id;},edited);
  // The original and this PNG are different managed originals, so the FileDrop
  // batch contains two actual files, with the first raster as an app fallback.
  const batch=await page.evaluate(ids=>window.clipboardLine.command('copy',{ids,keepOpen:true}),[imageItem.id,secondImage]);assert.ok(!batch.result?.error,batch.result?.error);
  await until(fixtureState,s=>s.dropCount===2&&s.pngAvailable);
  await application.evaluate(()=>global.__clipboardLineTest.readClipboard());assert.equal((await page.evaluate(()=>window.clipboardLine.state())).items.length,batch.items.length);
  check('multi-image copy supplies native Windows FileDrop batch and full-resolution PNG fallback without recapture');
  const copied=await page.evaluate(id=>window.clipboardLine.command('copy',{ids:[id]}),textItem.id);assert.ok(!copied.result?.error);assert.equal(await application.evaluate(()=>global.__clipboardLineTest.getWindow().isVisible()),false);check('plain Enter copy dismisses shelves/preview host and restores previous application');
  await fixtureCommand({action:'focus',target:'plain'});await application.evaluate(()=>global.__clipboardLineTest.command('show'));
  const closedTarget=await application.evaluate(()=>global.__clipboardLineTest.getTarget());assert.ok(closedTarget.editable);
  const exited=new Promise(resolve=>fixture.once('exit',resolve));fixture.kill();await exited;fixture=null;await application.evaluate(async({clipboard})=>await clipboard.writeText('Clipboard before closed target'));
  const closed=await page.evaluate(id=>window.clipboardLine.command('paste',{ids:[id]}),textItem.id);assert.ok(closed.result?.error);assert.equal(await application.evaluate(async({clipboard})=>await clipboard.readText()),'Clipboard before closed target');
  check('closed destination process fails safely before clipboard replacement or keyboard input');
  await notepadConsumer({page,application,textItem,check,until,report,data});
  await application.evaluate(()=>global.__clipboardLineTest.command('show'));
  const screenCapture=await page.evaluate(()=>window.clipboardLine.command('capture'));assert.ok(screenCapture.result?.id,screenCapture.result?.error);check('actual Windows desktop capture produces a managed image');
  await page.locator('#preview-dialog').waitFor({state:'visible'});await page.locator('#markup-canvas').waitFor({state:'visible'});
  await page.evaluate(()=>window.clipboardLine.command('settings'));await page.locator('#preview-dialog').waitFor({state:'hidden'});await page.locator('.settings-main').waitFor({state:'visible'});await page.locator('[data-action="settings-tab"][data-tab="general"]').click();await page.locator('[data-setting="theme"]').waitFor({state:'visible'});
  await page.locator('[data-action="settings-tab"][data-tab="sources"]').click();await page.locator('[data-setting="captureText"]').waitFor({state:'visible'});
  // The real capture is exercised above but never exported as a screenshot or
  // retained in the test library: published evidence contains only our own UI.
  await page.evaluate(id=>window.clipboardLine.command('trash',{ids:[id]}),screenCapture.result.id);const removedCapture=await page.evaluate(id=>window.clipboardLine.command('delete',{ids:[id]}),screenCapture.result.id);assert.ok(!removedCapture.result?.error,removedCapture.result?.error);assert.ok(!removedCapture.items.some(value=>value.id===screenCapture.result.id));
  await page.screenshot({path:path.join(output,'settings.png')});check('native Settings transition dismisses capture crop/preview and exposes usable controls');
  await historyCleanupNativeAcceptance({page,application,until,check,output});
  const persisted=JSON.parse(fs.readFileSync(path.join(data,'library.json'),'utf8'));assert.ok(persisted.items.some(i=>i.id===textItem.id&&i.pinned&&i.tags.includes('work')));check('real persisted library retains named pinned organization');
  if(fixture){fixture.kill();fixture=null;}
  await application.close();application=null;
  application=await electron.launch({...(process.env.CLIPBOARDLINE_EXECUTABLE?{executablePath:path.resolve(process.env.CLIPBOARDLINE_EXECUTABLE),args:[]}:{args:[path.resolve('.')]}),timeout:60000});
  const productionPage=await application.firstWindow();activePage=productionPage;await productionPage.waitForFunction(()=>!!window.clipboardLine);
  const production=await until(()=>productionPage.evaluate(()=>window.clipboardLine.state()),value=>value.windowVisible===true);
  assert.equal(production.settings.captureText,false);assert.equal(production.settings.captureImages,false);assert.equal(production.settings.captureLinks,true);assert.equal(production.settings.fetchLinkMetadata,true);
  assert.equal(await application.evaluate(()=>typeof global.__clipboardLineTest),'undefined');
  assert.equal(await productionPage.evaluate(async()=>{try{await fetch('https://example.com');return false;}catch{return true;}}),true);
  await productionPage.screenshot({path:path.join(output,'production-startup.png')});check('normal production startup creates tray/services, keeps image/text opt-in, matches Mac link defaults and blocks renderer network');
  assert.equal(report.rendererErrors.length,0,JSON.stringify(report.rendererErrors));
  report.completedAt=new Date().toISOString();report.passed=true;
}
main().catch(async error=>{report.passed=false;report.error=error.stack;console.error(error.stack);process.exitCode=1;
  if(application){report.mediaRequests=await application.evaluate(()=>global.__clipboardLineTest?.getMediaDiagnostics?.()||[]).catch(()=>[]);report.failureWindow=await application.evaluate(()=>{const h=global.__clipboardLineTest,w=h?.getWindow();return w?{visible:w.isVisible(),focused:w.isFocused(),view:h.state().view}:null;}).catch(()=>null);}
  if(activePage&&!activePage.isClosed())report.failureUI=await activePage.evaluate(()=>({toast:document.getElementById('toast')?.textContent||'',preview:!!document.getElementById('preview-dialog'),canvas:!!document.getElementById('markup-canvas'),documentFocused:document.hasFocus(),activeElement:{tag:document.activeElement?.tagName,id:document.activeElement?.id},activeShelf:document.querySelector('.active-shelf')?.dataset.shelf,selected:[...document.querySelectorAll('.card.selected')].map(node=>node.dataset.itemId),focused:[...document.querySelectorAll('.card.focused')].map(node=>node.dataset.itemId),visibleShelves:[...document.querySelectorAll('[data-shelf]')].map(node=>({kind:node.dataset.shelf,count:node.querySelectorAll('.card').length})),viewport:{width:innerWidth,height:innerHeight},geometry:[...document.querySelectorAll('#markup-canvas,.image-document,.image-stage,.preview-body,.preview-toolbar,.preview-dialog')].map(node=>{const r=node.getBoundingClientRect(),s=getComputedStyle(node);return{node:node.id||node.className,x:r.x,y:r.y,width:r.width,height:r.height,display:s.display,flex:s.flex,heightStyle:s.height,minHeight:s.minHeight,maxHeight:s.maxHeight};})})).catch(()=>null);
  if(activePage&&!activePage.isClosed()&&!report.checks.some(value=>value.name==='actual Windows desktop capture produces a managed image'))await activePage.screenshot({path:path.join(output,'failure.png')}).catch(()=>{});
  console.error('Native failure diagnostics: '+JSON.stringify({mediaRequests:report.mediaRequests,rendererErrors:report.rendererErrors,rendererConsole:report.rendererConsole,failureWindow:report.failureWindow,failureUI:report.failureUI}));
}).finally(async()=>{if(fixture)fixture.kill();if(otherFixture)otherFixture.kill();if(application)await application.close().catch(()=>{});fs.writeFileSync(path.join(output,'windows-runtime.json'),JSON.stringify(report,null,2));fs.rmSync(data,{recursive:true,force:true,maxRetries:4});});
