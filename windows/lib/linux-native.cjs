'use strict';
const {spawn,execFile}=require('node:child_process');
const path=require('node:path');
const {ClipboardSequenceQueries}=require('./clipboard-sequence.cjs');
const helper=__dirname.includes('app.asar')?path.join(process.resourcesPath,'native','clipboardline-x11'):path.join(__dirname,'../../linux/build/clipboardline-x11');
let sequenceQueries=null;
function monitor(changed,failed){
 const child=spawn(helper,[],{stdio:['pipe','pipe','ignore']});
 const queries=new ClipboardSequenceQueries(value=>child.stdin.write(value));sequenceQueries=queries;
 let buffer='',stopped=false;
 const stop=()=>{queries.close();if(sequenceQueries===queries)sequenceQueries=null;};
 child.stdin.on('error',stop);
 child.stdout.on('data',chunk=>{
  buffer+=chunk.toString();if(buffer.length>64000){child.kill();return;}
  let index;while((index=buffer.indexOf('\n'))>=0){const line=buffer.slice(0,index);buffer=buffer.slice(index+1);try{const value=JSON.parse(line);if(value.clipboardQuery!==undefined)queries.receive(value);else if(Number.isInteger(value.sequence))changed(value.sequence);}catch{}}
 });
 const fail=()=>{stop();if(!stopped){stopped=true;failed(new Error('Linux clipboard monitoring is unavailable. Build the X11 helper and run under X11/XWayland; capture is paused.'));}};
 child.on('error',fail);child.on('exit',fail);return child;
}
function run(args){return new Promise((resolve,reject)=>execFile(helper,args,{timeout:3000,maxBuffer:64000},(error,stdout)=>error?reject(new Error('The previous X11 window is unavailable.')):resolve(stdout)));}
const unsupported=()=>Promise.reject(new Error('Direct paste is unavailable on Linux because a secure editable destination cannot be verified. Copy, switch to your app, then press Ctrl+V.'));
module.exports={monitor,clipboardSequence:()=>sequenceQueries?sequenceQueries.read():Promise.reject(new Error('Clipboard monitor is unavailable.')),
 capture:async()=>JSON.parse(await run(['capture'])),restore:async target=>{
  if(!target||!/^\d{1,20}$/.test(target.handle)||!Number.isSafeInteger(target.processId)||target.processId<=0)throw new Error('Invalid focus target.');
  await run(['restore',target.handle,String(target.processId),String(process.pid)]);
 },preparePaste:unsupported,validatePaste:unsupported,paste:unsupported,cancelPaste:()=>{},
 copyImages:payload=>require('./linux-files.cjs').copyFiles(payload),captureDiagnostics:async()=>({platform:'linux',directPaste:false})};
