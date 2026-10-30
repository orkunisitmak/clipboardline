'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const contract=JSON.parse(fs.readFileSync(path.join(__dirname,'../../contracts/clipboard-admission.json'),'utf8'));
const walletContract=JSON.parse(fs.readFileSync(path.join(__dirname,'../../contracts/wallet-guard.json'),'utf8'));
module.exports=async function clipboardAdmissionAcceptance({application,check}){
 const result=await application.evaluate(async({clipboard,ClipboardItem,nativeImage},{contract,walletContract})=>{
  const api=global.__clipboardLineTest,baseline=api.store.data.items.length,originalRead=clipboard.read.bind(clipboard);
  const idle=async()=>{const end=Date.now()+5000;while(Date.now()<end){const value=api.getCaptureAdmissionState();if(!value.capturing&&!value.pendingClipboard)return;await new Promise(resolve=>setTimeout(resolve,25));}throw new Error('Clipboard admission did not settle.');};
  const snapshot=async()=>{await api.readClipboard();await idle();return api.store.data.items.length;};
  let privateCases=0,textCases=0,markerReads=0,secretsWithheld=0;
  try{
   // This wraps real native ClipboardItems solely to count payload requests.
   clipboard.read=async()=>{const entries=await originalRead();return entries.map(entry=>({types:entry.types,getType:async type=>{markerReads++;return entry.getType(type);}}));};
   const png=nativeImage.createFromBitmap(Buffer.alloc(4,255),{width:1,height:1}).toPNG();
   for(const marker of contract.privateMarkers){
    const raw='electron application/osclipboard;format="'+marker+'"';
    for(const payload of [{'text/plain':new Blob(['synthetic private'])},{'image/png':new Blob([png],{type:'image/png'})}]){
     await clipboard.write([new ClipboardItem({...payload,[raw]:new Blob([new Uint8Array([1])])})]);
     const reads=markerReads;if(await snapshot()!==baseline||markerReads!==reads)throw new Error('Native private marker was admitted: '+marker);privateCases++;
    }
   }
   clipboard.read=originalRead;
   for(const row of contract.textCases){
    await clipboard.writeText(row.value);
    if(!row.capture){if(await snapshot()!==baseline)throw new Error('Blank native copy was admitted: '+row.name);}
    else{const content=await api.clipboardContent();if(!content||content.kind!=='text'||Buffer.compare(Buffer.from(content.value),Buffer.from(row.value))!==0)throw new Error('Native copied text bytes changed: '+row.name);}
    textCases++;
   }
   // Wallet Guard on the production readClipboard path: text capture is on
   // and the guard is on by default, so a recognized secret never reaches the Store.
   if(api.store.data.settings.captureText!==true||api.store.data.settings.walletGuard!==true)throw new Error('Wallet Guard acceptance needs text capture and the guard on.');
   for(const row of walletContract.classify.filter(value=>value.expect.kind==='secret').slice(0,2)){
    await clipboard.writeText(row.value);
    if(await snapshot()!==baseline||api.store.data.items.some(item=>item.text===row.value||item.text===row.value.trim()))throw new Error('Recognized Wallet Guard secret was admitted: '+row.name);
    secretsWithheld++;
   }
   const first=await api.native.clipboardSequence();await clipboard.writeText('native sequence probe');const second=await api.native.clipboardSequence();
   const fallback=await api.native.clipboardSequence({standalone:true});
   if(!Number.isInteger(first)||!Number.isInteger(second)||first===second||fallback!==second)throw new Error('Native clipboard sequence query failed.');
   await clipboard.writeText('synthetic public before replacement');
   let readCalls=0,payloadReads=0;
   clipboard.read=async()=>{
    const entries=await originalRead();readCalls++;
    if(readCalls===1)await clipboard.write([new ClipboardItem({'text/plain':new Blob(['synthetic private replacement']),'electron application/osclipboard;format="com.agilebits.onepassword"':new Blob([new Uint8Array([1])])})]);
    return entries.map(entry=>({types:entry.types,getType:async type=>{payloadReads++;return entry.getType(type);}}));
   };
   const remaining=await snapshot();
   if(remaining!==baseline||readCalls<2||payloadReads!==0)throw new Error('Raced native private replacement was not discarded/retried.');
   return{privateCases,textCases,secretsWithheld,nativeQueries:true,fallback:true,racedReadCalls:readCalls,payloadReads,historyUnchanged:remaining===baseline};
  }finally{clipboard.read=originalRead;await idle();}
 },{contract,walletContract});
 assert.equal(result.privateCases,contract.privateMarkers.length*2);assert.equal(result.textCases,contract.textCases.length);assert.equal(result.secretsWithheld,2);
 assert.ok(result.nativeQueries&&result.fallback&&result.historyUnchanged);assert.ok(result.racedReadCalls>=2);assert.equal(result.payloadReads,0);
 check('native clipboard admission excludes private, blank and Wallet Guard secret copies, preserves exact text and rejects raced replacements',result);
};
