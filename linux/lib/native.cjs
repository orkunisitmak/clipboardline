'use strict';
const {spawn,execFile} = require('node:child_process');
const path = require('node:path');
const {ClipboardSequenceQueries}=require('./clipboard-sequence.cjs');
const {windowsEnvironment}=require('./windows-environment.cjs');
const script = __dirname.includes('app.asar') ? path.join(process.resourcesPath,'native','windows-bridge.ps1') : path.join(__dirname, '..', 'native', 'windows-bridge.ps1');
const pasteChildren=new Set();
let lastCaptureTrace=null,sequenceQueries=null;
function captureTrace(value){
  const reasons=['deadline','query-deadline','host-changed','host-changed-during-query','missing-before-loading','warm','secure','noneditable','editor-changed','stable-editor','sample-limit'];
  if(!value||!reasons.includes(value.reason)||!['samples','loadingSamples','missingSamples','elapsedMs'].every(key=>Number.isInteger(value[key])&&value[key]>=0&&value[key]<=(key==='elapsedMs'?12000:80)))return null;
  return Object.freeze({reason:value.reason,samples:value.samples,loadingSamples:value.loadingSamples,missingSamples:value.missingSamples,elapsedMs:value.elapsedMs});
}
const powershell = path.join(process.env.SystemRoot || 'C:\\Windows','System32','WindowsPowerShell','v1.0','powershell.exe');
// UIA runs on a non-window-owning MTA thread. WinForms clipboard ownership is
// the one mode that requires STA; it does not traverse UI Automation elements.
function invocation(mode) { return ['-NoLogo','-NoProfile',mode==='CopyImages'?'-STA':'-MTA','-NonInteractive','-ExecutionPolicy','Bypass','-File',script,'-Mode',mode]; }
function run(mode, target) {
  if (process.platform !== 'win32') return mode === 'Capture' ? Promise.resolve(null) : Promise.reject(new Error('External application focus is supported on Windows.'));
  if(mode==='Capture')lastCaptureTrace=null;
  return new Promise((resolve,reject) => {
    const child=execFile(powershell, invocation(mode), {windowsHide:true,timeout:12000,maxBuffer:64000,env:windowsEnvironment()},(error,stdout,stderr) => {
      pasteChildren.delete(child);
      let value; try { value=JSON.parse(stdout.trim()); } catch {
        const isolated=process.argv?.includes('--test-mode')&&process.argv.some(value=>value.startsWith('--test-data='));
        const diagnostic=isolated&&stderr?' Native helper startup: '+String(stderr).replace(/\x1b\[[0-9;]*m/g,'').slice(0,2500):'';
        reject(new Error('Windows focus helper did not respond.'+diagnostic)); return;
      }
      if(!value||typeof value!=='object'){reject(new Error('Windows focus helper did not respond.'));return;}
      if(mode==='Capture'){lastCaptureTrace=captureTrace(value.captureTrace);delete value.captureTrace;}
      if (error || value.ok === false) reject(new Error(value.error || 'Windows focus operation failed.')); else resolve(value);
    });
    if(['PreparePaste','ValidatePaste','Paste','CopyImages'].includes(mode))pasteChildren.add(child);
    child.stdin.end(target?JSON.stringify({...target,sourceProcessId:process.pid}):'');
  });
}
function monitor(changed, failed, focused = () => {}) {
  if (process.platform !== 'win32') return null;
  const child = spawn(powershell, invocation('Monitor'), {windowsHide:true,stdio:['pipe','pipe','pipe'],env:windowsEnvironment()});
  const queries=new ClipboardSequenceQueries(value=>child.stdin.write(value));sequenceQueries=queries;
  const stopped=()=>{queries.close();if(sequenceQueries===queries)sequenceQueries=null;};
  child.stdin.on('error',stopped);
  let buffer=''; child.stdout.on('data',chunk => {
    buffer += chunk.toString(); if (buffer.length > 64000) { child.kill(); return; }
    let newline;
    while ((newline=buffer.indexOf('\n')) >= 0) { const line=buffer.slice(0,newline);buffer=buffer.slice(newline+1);try { const v=JSON.parse(line); if(v.clipboardQuery!==undefined){queries.receive(v);}else if(Number.isInteger(v.sequence)) changed(v.sequence); if(v.focus) focused(v.focus); } catch {} }
  });
  child.on('error',error=>{stopped();failed(error);}); child.on('exit',code => { stopped();if(code) failed(new Error('Native clipboard monitor stopped.')); }); return child;
}
module.exports = {clipboardSequence:async({standalone=false}={})=>{if(!standalone&&sequenceQueries)return sequenceQueries.read();if(process.platform!=='win32')return null;const value=await run('ClipboardSequence');return value.sequence;},cancelPaste:()=>{for(const child of pasteChildren)child.kill();pasteChildren.clear();},capture:()=>run('Capture'),captureDiagnostics:async()=>{const trace=lastCaptureTrace,details=await run('CaptureDiagnostics');return trace?{...details,captureTrace:trace}:details;},selfTestFocusPolicy:()=>run('FocusPolicySelfTest'), restore:target=>run('Restore',target),preparePaste:target=>run('PreparePaste',target),validatePaste:target=>run('ValidatePaste',{...target,prepared:true}),paste:target=>run('Paste',target),copyImages:payload=>run('CopyImages',payload),monitor};
