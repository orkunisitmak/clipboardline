'use strict';
const assert=require('node:assert/strict');
const crypto=require('node:crypto');
const fs=require('node:fs');
const path=require('node:path');
const {spawn}=require('node:child_process');
const {windowsEnvironment}=require('../lib/windows-environment.cjs');

// This consumer test never replaces the app's native paste with fixture input.
// The PowerShell helper only opens/selects/observes its own UUID-named document.
module.exports=async function notepadAcceptance({page,application,textItem,check,until,report,data}){
  const results=report.consumerApplications||(report.consumerApplications=[]);
  if(process.platform!=='win32'){
    const result={application:'Notepad',status:'unavailable',reason:'Actual Windows Notepad acceptance requires Windows.'};results.push(result);return result;
  }
  const directory=fs.mkdtempSync(path.join(data,'notepad-'));
  const token='ClipBoardLine-Notepad-'+crypto.randomUUID();
  const document=path.join(directory,token+'.txt'),output=path.join(directory,'state.json'),commands=path.join(directory,'commands.json');
  const seed='Replace only this synthetic Notepad selection '+token;
  fs.writeFileSync(document,seed,{encoding:'utf8',mode:0o600});
  const config=path.join(directory,'config.json');
  fs.writeFileSync(config,JSON.stringify({document,token,seed,output,commands}),{mode:0o600});
  const ps=path.win32.join(process.env.SystemRoot||process.env.SYSTEMROOT||'C:\\Windows','System32','WindowsPowerShell','v1.0','powershell.exe');
  // UIA tree traversal belongs on a non-window-owning MTA client thread.
  // https://learn.microsoft.com/en-us/windows/win32/winauto/uiauto-threading
  const helper=spawn(ps,['-NoProfile','-MTA','-ExecutionPolicy','Bypass','-File',path.join(__dirname,'notepad-fixture.ps1'),'-Config',config],{stdio:['ignore','ignore','pipe'],windowsHide:false,env:windowsEnvironment()});
  let helperError='',spawnError,exited=false;helper.stderr.on('data',bytes=>{helperError=(helperError+String(bytes)).slice(-3000);});helper.on('error',error=>{spawnError=error;});helper.on('exit',()=>{exited=true;});
  const state=()=>{
    if(spawnError)throw spawnError;
    if(!fs.existsSync(output)){
      if(exited)throw new Error('Notepad fixture exited before reporting: '+helperError);
      return null;
    }
    return JSON.parse(fs.readFileSync(output,'utf8'));
  };
  const command=async action=>{
    const serial=crypto.randomUUID();fs.writeFileSync(commands+'.tmp',JSON.stringify({action,serial}));fs.renameSync(commands+'.tmp',commands);
    const value=await until(state,next=>!!next&&(next.lastSerial===serial||next.status==='failed'),15000);
    assert.notEqual(value.status,'failed',value.reason);assert.equal(value.commandError||'','',value.commandError);return value;
  };
  let result,primaryError;
  try{
    await application.evaluate(()=>global.__clipboardLineTest.command('hide'));
    const ready=await until(state,value=>!!value&&['ready','unavailable','failed'].includes(value.status),35000);
    if(ready.status==='unavailable'){
      result={application:'Notepad',status:'unavailable',reason:ready.reason};results.push(result);console.log('UNAVAILABLE Notepad: '+ready.reason);return result;
    }
    assert.equal(ready.status,'ready',JSON.stringify({reason:ready.reason,traversal:ready.traversal,discovery:ready.discovery,discoveryErrors:ready.discoveryErrors,windows:ready.windows,processes:ready.notepadProcesses}));
    const focused=await command('focus');assert.equal(focused.text,seed);if(focused.selectionMethod==='UIA TextPattern')assert.equal(focused.selectedText,seed);else assert.equal(focused.selectionMethod,'Native CtrlA');assert.equal(focused.foreground,true);assert.equal(focused.editorFocused,true);
    await application.evaluate(()=>global.__clipboardLineTest.command('show'));
    const target=await application.evaluate(()=>global.__clipboardLineTest.getTarget());
    assert.equal(target?.handle,focused.handle,JSON.stringify({target,notepad:focused.handle}));assert.equal(target?.processId,focused.processId);assert.equal(target?.runtime,focused.runtime);assert.ok(target.editable&&!target.secure,JSON.stringify(target));
    // Ctrl-click is deliberately selection-only on shelves. Remove any initial
    // selection first, including the target if opening selected it already.
    for(const id of await page.locator('.card[aria-selected="true"]').evaluateAll(cards=>cards.map(card=>card.dataset.itemId)))await page.locator(`[data-item-id="${id}"]`).click({modifiers:['Control']});
    const card=page.locator(`[data-shelf="text"] [data-item-id="${textItem.id}"]`);
    await card.click({modifiers:['Control']});assert.equal(await card.getAttribute('aria-selected'),'true');assert.equal(await page.locator('.card[aria-selected="true"]').count(),1);await page.keyboard.press('Control+Enter');
    const pasted=await until(state,value=>!!value&&(value.status==='failed'||value.text===textItem.text),15000);
    assert.notEqual(pasted.status,'failed',pasted.reason);assert.equal(pasted.text,textItem.text);
    await until(()=>application.evaluate(()=>global.__clipboardLineTest.getWindow().isVisible()),visible=>visible===false);
    assert.equal(pasted.foreground,true);assert.equal(pasted.editorFocused,true);
    await command('save');
    const saved=await until(()=>fs.readFileSync(document,'utf8').replace(/^\uFEFF/,''),value=>value===textItem.text,10000);assert.equal(saved,textItem.text);
    result={application:'Notepad',status:'passed',version:ready.version||'',processHandoff:!!ready.processHandoff,selectionMethod:ready.selectionMethod,verification:'Exact UIA document text and saved synthetic file',selectionReplaced:true,windowHidden:true};results.push(result);
    return result;
  }catch(error){primaryError=error;results.push({application:'Notepad',status:'failed',reason:error.message});throw error;}
  finally{
    // No taskkill / process-tree termination: Store Notepad may share a process
    // with unrelated tabs. Only the helper's exact document can be closed.
    try{
      const current=state();
      if(current?.status==='ready'){
        await application.evaluate(()=>global.__clipboardLineTest.command('hide'));
        const closed=await command('close');
        if(result)result.cleanup=closed.documentClosed?'closed-owned-document':'close-not-confirmed';
        if(!closed.documentClosed&&!primaryError)throw new Error('Notepad fixture document did not close.');
        if(result?.status==='passed')check('actual Notepad CtrlEnter replaces the selected document text, saves exact content and hides ClipboardLine',{application:'Notepad',version:result.version});
      }
    }catch(error){if(result)result.cleanupError=error.message;if(!primaryError&&result?.status==='passed'){result.status='failed';throw error;}}
    finally{
      // This is our observer process, never the consumer's process.
      if(!exited)helper.kill();
    }
  }
};
