'use strict';
// Test-only, metadata-only diagnostics. A blocked Electron main process must
// not prevent the observer/process evidence from being retained before cleanup.
async function boundedRead(read,timeout=4000){
 let timer;try{return await Promise.race([Promise.resolve().then(read),new Promise(resolve=>{timer=setTimeout(()=>resolve({error:'Diagnostic read timed out',timeoutMs:timeout}),timeout);})]);}
 catch(error){return{error:String(error?.message||error).slice(0,1200)};}
 finally{clearTimeout(timer);}
}
function updateState(value){
 const result={};for(const key of ['status','message','error','checkedAt','lastAttemptAt','currentVersion','currentBuild','availableVersion','availableBuild','busy','canInstall']){
  const entry=value?.[key];if(entry===null||['string','number','boolean'].includes(typeof entry))result[key]=typeof entry==='string'?entry.slice(0,1200):entry;
 }return result;
}
function observeInstallRequest(promise,changed){
 const pending={status:'pending',startedAt:new Date().toISOString()};changed(pending);
 return Promise.resolve(promise).then(result=>{changed({...pending,status:'fulfilled',settledAt:new Date().toISOString(),update:updateState(result?.update),error:typeof result?.result?.error==='string'?result.result.error.slice(0,1200):null});return result;},error=>{const message=String(error?.message||error).slice(0,1200);changed({...pending,status:'rejected',settledAt:new Date().toISOString(),error:message,closureLike:/closed|Target|destroyed/i.test(message)});throw error;});
}
async function collectUpgradeFailure({readMain,readObserver,readPhase,readInstallation,readProcesses,requestState,timeout=4000}){
 const snapshot={capturedAt:new Date().toISOString(),requestBefore:structuredClone(requestState())};
 const [main,phase,observer]=await Promise.all([
  boundedRead(readMain,timeout),boundedRead(readPhase,timeout),boundedRead(readObserver,timeout)
 ]);
 snapshot.candidate=!main||typeof main!=='object'?{error:'Candidate metadata was unavailable'}:main.error?main:{pid:main.pid,executable:main.executable,argv:main.argv,update:updateState(main.update),installer:main.installer,window:main.window};
 // Native WMI readers have their own 20/15-second subprocess timeouts. Run
 // them after the main deadline so their synchronous work cannot delay it.
 const installation=await boundedRead(readInstallation,timeout),processes=await boundedRead(readProcesses,timeout);
 Object.assign(snapshot,{phase,observer,installation,processes,requestAfter:structuredClone(requestState())});return snapshot;
}
module.exports={boundedRead,updateState,observeInstallRequest,collectUpgradeFailure};
