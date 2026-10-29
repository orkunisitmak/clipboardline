'use strict';
const fs=require('node:fs');const path=require('node:path');const assert=require('node:assert/strict');
const {chromium}=require('playwright');
const {TITLE,pointerPoint,createWin32Observer}=require('./consumer-win32-focus.cjs');

async function browserConsumer({page,application,textItem,imageItem,check,until,report,output},observer,name,vendor,relative){
  const roots=[process.env['ProgramFiles(x86)'],process.env.ProgramFiles,process.env.LOCALAPPDATA].filter(Boolean);
  const executable=roots.map(root=>path.join(root,...relative)).find(file=>fs.existsSync(file));
  report.consumers??={};const consumer=report.consumers[name]={available:!!executable,passed:false};
  if(!executable)throw new Error(vendor+' is not installed; actual consumer-browser acceptance cannot run.');
  await page.evaluate(()=>window.clipboardLine.command('hide'));
  const browser=await chromium.launch({executablePath:executable,headless:false,args:['--force-renderer-accessibility','--no-first-run','--disable-background-networking','--disable-component-update','--disable-sync']});
  let target,cdp;
  const expected={executable:fs.realpathSync.native(executable),pid:null};
  const domFocus=()=>target.evaluate(()=>{const element=document.activeElement;return{documentFocused:document.hasFocus(),activeTag:element?.tagName||'',activeRole:element?.getAttribute('role')||'',activeID:element?.id||'',isContentEditable:!!element?.isContentEditable,enabled:!element?.disabled,secure:element?.type==='password'};});
  const nativeFocus=()=>application.evaluate(async()=>{const native=global.__clipboardLineTest.native;return native.captureDiagnostics?await native.captureDiagnostics():await native.capture();});
  async function readyForCapture(id){const dom=await domFocus();assert.equal(dom.activeID,id);assert.equal(dom.documentFocused,true);return{dom,win32:await observer.read(expected)};}
  function matchesOwnedWindow(captured){assert.equal(captured?.processId,expected.pid);assert.equal(captured?.handle,expected.window);}
  async function pointerFocus(id,stage){
    await target.bringToFront();
    const field=target.locator('#'+id);await field.scrollIntoViewIfNeeded();
    const metrics=await field.evaluate(element=>{const rect=element.getBoundingClientRect();return{screenX,screenY,outerHeight,outerWidth,innerHeight,innerWidth,devicePixelRatio,rect:{x:rect.x,y:rect.y,width:rect.width,height:rect.height}};});
    const point=pointerPoint(metrics);await observer.read(expected,point);
    // No locator.fill/press/focus is allowed to supply this precondition. The
    // OS pointer event must have focused this editor with emulation disabled.
    await target.waitForFunction(id=>document.hasFocus()&&document.activeElement?.id===id,id,{timeout:3000});
    const {dom,win32}=await readyForCapture(id);expected.window??=win32.window;
    const result={stage,point,metrics,domBeforeKeyboard:dom,win32};(consumer.focusPreconditions??=[]).push(result);return{dom,win32};
  }
  try{
    consumer.version=browser.version();
    const browserCDP=await browser.newBrowserCDPSession();
    try{const processes=(await browserCDP.send('SystemInfo.getProcessInfo')).processInfo.filter(value=>value.type==='browser');assert.equal(processes.length,1);expected.pid=processes[0].id;assert.ok(Number.isSafeInteger(expected.pid)&&expected.pid>0);}finally{await browserCDP.detach();}
    target=await browser.newPage({viewport:null});
    cdp=await target.context().newCDPSession(target);await cdp.send('Emulation.setFocusEmulationEnabled',{enabled:false});
    await target.goto('data:text/html,'+encodeURIComponent('<!doctype html><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src \'none\'; style-src \'unsafe-inline\'; img-src data: blob:"><title>'+TITLE+'</title><style>body{font:20px sans-serif;margin:30px}.rich{border:2px solid #777;min-height:50px;margin:12px 0;padding:12px}#editor{min-height:150px}input{display:block;margin-top:14px;padding:10px}</style><h1>Local consumer-browser paste fixture</h1><div id="editor" class="rich" contenteditable="true" role="textbox" aria-label="Synthetic rich editor">Original browser fixture selection</div><div id="alternate" class="rich" contenteditable="true" role="textbox" aria-label="Synthetic alternate editor">Alternate untouched</div><input id="readonly" readonly value="Read-only untouched" aria-label="Synthetic read-only field"><input id="password" type="password" aria-label="Synthetic password field">'));
    consumer.beforeShow=await pointerFocus('editor','first-cold-capture');await target.keyboard.press('Control+a');
    consumer.beforeShow.afterKeyboard=await readyForCapture('editor');
    await application.evaluate(()=>global.__clipboardLineTest.command('show'));
    const captured=await application.evaluate(()=>global.__clipboardLineTest.getTarget());consumer.captured=captured;
    if(!captured?.editable||captured?.secure){
      // Diagnose only after the real first capture failed. A preflight UIA read
      // could warm a lazy provider and hide a cold-capture production failure.
      await page.evaluate(()=>window.clipboardLine.command('hide'));await target.bringToFront();
      consumer.failedTargetDiagnostics={dom:await domFocus(),native:await nativeFocus()};
    }
    assert.ok(captured?.editable&&!captured?.secure,vendor+' editable UIA target: '+JSON.stringify({captured,beforeShow:consumer.beforeShow,diagnostics:consumer.failedTargetDiagnostics}));
    matchesOwnedWindow(captured);
    assert.equal(captured.processId,consumer.beforeShow.win32.owner);assert.equal(captured.handle,consumer.beforeShow.win32.window);
    await page.locator(`[data-shelf="text"] [data-item-id="${textItem.id}"]`).click({modifiers:['Control']});await page.keyboard.press('Control+Enter');
    await until(()=>target.locator('#editor').innerText(),value=>value===textItem.text);assert.equal((await page.evaluate(()=>window.clipboardLine.state())).windowVisible,false);
    consumer.textPaste=true;const returnedTextFocus=await application.evaluate(()=>global.__clipboardLineTest.native.capture());assert.equal(returnedTextFocus.processId,captured.processId);assert.equal(returnedTextFocus.handle,captured.handle);assert.ok(returnedTextFocus.editable&&!returnedTextFocus.secure);assert.equal(await target.locator('#editor').evaluate(element=>element===document.activeElement),true);check('actual '+vendor+' contenteditable accepts native CtrlEnter text replacement and regains native focus');

    await pointerFocus('editor','image-paste-destination');await target.keyboard.press('Control+a');await target.keyboard.press('Backspace');
    consumer.beforeImageLibrary=await readyForCapture('editor');
    await application.evaluate(()=>global.__clipboardLineTest.command('library'));
    await page.locator('[data-action="scope"][data-scope="recent"]').click();
    await page.locator(`[data-item-id="${imageItem.id}"]`).click();await page.keyboard.press('Space');await page.locator('#preview-dialog').waitFor({state:'visible'});await page.keyboard.press('Control+Enter');
    await target.locator('#editor img').first().waitFor({state:'visible'});const image=await until(()=>target.locator('#editor img').first().evaluate(element=>({complete:element.complete,width:element.naturalWidth,height:element.naturalHeight})),value=>value.complete&&value.width>0&&value.height>0);
    assert.equal((await page.evaluate(()=>window.clipboardLine.state())).windowVisible,false);consumer.imagePaste=image;const returnedImageFocus=await application.evaluate(()=>global.__clipboardLineTest.native.capture());assert.equal(returnedImageFocus.processId,captured.processId);assert.equal(returnedImageFocus.handle,captured.handle);assert.ok(returnedImageFocus.editable&&!returnedImageFocus.secure);assert.equal(await target.locator('#editor').evaluate(element=>element===document.activeElement),true);check('actual '+vendor+' contenteditable accepts native Library preview image paste and regains native focus');

    // Pause exactly before production validation, then move focus to a second
    // real editor in the same browser. A generic window/pane identity cannot
    // satisfy this: the destination must identify the captured editable field.
    await pointerFocus('editor','changed-field-original');await target.keyboard.press('Control+a');await target.keyboard.insertText('Original field before canceled paste');await target.keyboard.press('Control+a');
    consumer.beforeChangedFieldShow=await readyForCapture('editor');
    await application.evaluate(()=>global.__clipboardLineTest.command('show'));
    const originalTarget=await application.evaluate(()=>global.__clipboardLineTest.getTarget());assert.ok(originalTarget?.editable&&!originalTarget.secure,JSON.stringify(originalTarget));
    matchesOwnedWindow(originalTarget);
    const fields=()=>target.evaluate(()=>({first:document.getElementById('editor').innerHTML,second:document.getElementById('alternate').innerHTML,readonly:document.getElementById('readonly').value,passwordLength:document.getElementById('password').value.length}));
    const beforeChanged=await fields();await application.evaluate(async({clipboard})=>await clipboard.writeText('Clipboard before browser field change'));
    await application.evaluate(()=>{const native=global.__clipboardLineTest.native;let release;const gate=new Promise(resolve=>{release=resolve;});global.__consumerChangedPaste={original:native.validatePaste,release,waiting:false};native.validatePaste=async target=>{global.__consumerChangedPaste.waiting=true;await gate;return global.__consumerChangedPaste.original(target);};});
    const changedRequest=page.evaluate(id=>window.clipboardLine.command('paste',{ids:[id]}),textItem.id);
    try{
      await until(()=>application.evaluate(()=>global.__consumerChangedPaste.waiting),Boolean);
      await pointerFocus('alternate','changed-field-alternate');
      const changedTarget=await application.evaluate(()=>global.__clipboardLineTest.native.capture());assert.ok(changedTarget?.editable&&!changedTarget.secure,JSON.stringify(changedTarget));assert.equal(changedTarget.handle,originalTarget.handle);assert.equal(changedTarget.processId,originalTarget.processId);assert.notEqual(changedTarget.runtime,originalTarget.runtime,'Separate browser editors require distinct stable native focus identities');
      consumer.fieldIdentities={first:originalTarget.runtime,second:changedTarget.runtime};
      await application.evaluate(()=>global.__consumerChangedPaste.release());const canceled=await changedRequest;assert.ok(canceled.result?.error,JSON.stringify(canceled.result));
      assert.equal(await application.evaluate(async({clipboard})=>await clipboard.readText()),'Clipboard before browser field change');assert.deepEqual(await fields(),beforeChanged);consumer.changedFieldRejected=true;
      check('actual '+vendor+' changed-field paste cancels before clipboard replacement or insertion into either editor');
    }finally{await application.evaluate(()=>{const pending=global.__consumerChangedPaste;if(pending){pending.release();global.__clipboardLineTest.native.validatePaste=pending.original;delete global.__consumerChangedPaste;}});await changedRequest.catch(()=>{});}
    await page.evaluate(()=>window.clipboardLine.command('hide'));

    for(const control of ['readonly','password']){
      await pointerFocus(control,control+'-guard');await application.evaluate(()=>global.__clipboardLineTest.command('show'));
      const guarded=await application.evaluate(()=>global.__clipboardLineTest.getTarget());assert.ok(control==='password'?guarded?.secure===true:guarded?.editable===false&&!guarded?.secure,vendor+' '+control+' native target: '+JSON.stringify(guarded));
      matchesOwnedWindow(guarded);
      const beforeFields=await fields(),sentinel='Clipboard before browser '+control+' rejection';await page.locator(`[data-shelf="text"] [data-item-id="${textItem.id}"]`).click({modifiers:['Control']});await application.evaluate(async({clipboard},text)=>await clipboard.writeText(text),sentinel);
      const blocked=await page.evaluate(id=>window.clipboardLine.command('paste',{ids:[id]}),textItem.id);assert.ok(blocked.result?.error);assert.deepEqual(await fields(),beforeFields);assert.equal(await application.evaluate(async({clipboard})=>await clipboard.readText()),sentinel);
      consumer[control==='password'?'passwordRejected':'readOnlyRejected']=true;check('actual '+vendor+' '+control+' target rejects paste without clipboard replacement or changing any editor');await page.evaluate(()=>window.clipboardLine.command('hide'));
    }
    consumer.passed=true;
  }catch(error){
    consumer.failure={error:String(error.stack||error),dom:target&&!target.isClosed()?await domFocus().catch(()=>null):null,native:await nativeFocus().catch(nativeError=>({error:nativeError.message}))};
    if(output&&target&&!target.isClosed())await target.screenshot({path:path.join(output,name+'-consumer-failure.png')}).catch(()=>{});
    console.error(vendor+' consumer failure diagnostics: '+JSON.stringify(consumer.failure));throw error;
  }finally{await browser.close();}
}
module.exports=async options=>{
  const observer=await createWin32Observer();
  try{
    await browserConsumer(options,observer,'edge','Microsoft Edge',['Microsoft','Edge','Application','msedge.exe']);
    await browserConsumer(options,observer,'chrome','Google Chrome',['Google','Chrome','Application','chrome.exe']);
  }finally{await observer.close();}
};
