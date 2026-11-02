'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const contract=JSON.parse(fs.readFileSync(path.join(__dirname,'../../contracts/clipboard-admission.json'),'utf8'));
module.exports=async function clipboardAdmissionAcceptance({application,check}){
 const result=await application.evaluate(async({clipboard,ClipboardItem,nativeImage},{contract})=>{
  const api=global.__clipboardLineTest,baseline=api.store.data.items.length,originalRead=clipboard.read.bind(clipboard);
  // The private mode section below captures real copies. Remember what the line
  // held so they can be removed again: the checks that follow open the shelf and
  // expect the suite's own items to be the newest.
  const baselineIds=new Set(api.store.data.items.map(item=>item.id));
  const idle=async()=>{const end=Date.now()+5000;while(Date.now()<end){const value=api.getCaptureAdmissionState();if(!value.capturing&&!value.pendingClipboard)return;await new Promise(resolve=>setTimeout(resolve,25));}throw new Error('Clipboard admission did not settle.');};
  const snapshot=async()=>{await api.readClipboard();await idle();return api.store.data.items.length;};
  let privateCases=0,textCases=0,markerReads=0;
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
   // Drop the counting wrapper here: the sections below read real public copies,
   // and their payload reads are not part of the raced-replacement check.
   clipboard.read=originalRead;
   if(remaining!==baseline||readCalls<2||payloadReads!==0)throw new Error('Raced native private replacement was not discarded/retried.');
   // Private mode adopts the paused generation: the copy made while paused is
   // skipped on resume, while a later copy is admitted normally.
   const beforePause=api.store.data.items.length;
   api.store.modify('setSettings',{patch:{paused:true}});
   await clipboard.writeText('synthetic private mode pause');
   if(await snapshot()!==beforePause)throw new Error('Private mode admitted a paused copy.');
   api.store.modify('setSettings',{patch:{paused:false}});
   if(await snapshot()!==beforePause)throw new Error('Private mode replayed the paused copy on resume.');
   await clipboard.writeText('synthetic private mode resume');
   if(await snapshot()!==beforePause+1)throw new Error('Private mode blocked a copy after resume.');
   // Turning private mode on while the clipboard is being read must drop that
   // capture and adopt its generation instead of saving it.
   const beforePauseRace=api.store.data.items.length;
   let pauseOnRead=true;
   clipboard.read=async()=>{const entries=await originalRead();if(pauseOnRead){pauseOnRead=false;api.store.modify('setSettings',{patch:{paused:true}});}return entries;};
   await clipboard.writeText('synthetic pause during read');
   if(await snapshot()!==beforePauseRace)throw new Error('Private mode saved a copy that finished while pausing.');
   api.store.modify('setSettings',{patch:{paused:false}});
   if(await snapshot()!==beforePauseRace)throw new Error('Private mode replayed the copy captured while pausing.');
   await clipboard.writeText('synthetic copy after the pause race');
   if(await snapshot()!==beforePauseRace+1)throw new Error('Private mode blocked a copy after the pause race.');
   return{privateCases,textCases,nativeQueries:true,fallback:true,racedReadCalls:readCalls,payloadReads,historyUnchanged:remaining===baseline,privateMode:true,pauseRace:true};
  }finally{
   clipboard.read=originalRead;await idle();
   // Leave the line as it was found, so later shelf checks see their own items.
   try{
    const extra=api.store.data.items.filter(item=>!baselineIds.has(item.id)).map(item=>item.id);
    if(extra.length){api.store.modify('trash',{ids:extra});api.store.modify('delete',{ids:extra});}
   }catch(error){console.warn('Clipboard admission acceptance cleanup:',error?.message||error);}
  }
 },{contract});
 assert.equal(result.privateCases,contract.privateMarkers.length*2);assert.equal(result.textCases,contract.textCases.length);
 assert.ok(result.nativeQueries&&result.fallback&&result.historyUnchanged&&result.privateMode&&result.pauseRace);assert.ok(result.racedReadCalls>=2);assert.equal(result.payloadReads,0);
 check('native clipboard admission excludes private and blank copies, preserves exact text and rejects raced replacements',result);
};
