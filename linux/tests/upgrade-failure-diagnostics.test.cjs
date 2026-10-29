'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {boundedRead,updateState,observeInstallRequest,collectUpgradeFailure}=require('./upgrade-failure-diagnostics.cjs');
test('updater diagnostic projection retains phase metadata without credentials, envelopes or clipboard content',()=>{
 const result=updateState({status:'downloading',busy:true,currentBuild:65,availableBuild:66,error:null,message:'Downloading',envelope:'secret',publicKey:'secret',token:'secret',items:[{text:'private'}]});
 assert.deepEqual(result,{status:'downloading',message:'Downloading',error:null,currentBuild:65,availableBuild:66,busy:true});assert.equal(JSON.stringify(result).includes('secret'),false);assert.equal(updateState({error:'x'.repeat(2000)}).error.length,1200);
});
test('a blocked main-process diagnostic cannot lose observer, phase, process or request-settlement evidence',async()=>{
 const request={status:'pending'},result=await collectUpgradeFailure({timeout:5,requestState:()=>request,readMain:()=>new Promise(()=>{}),readPhase:()=>({beforeQuitAt:null}),readObserver:()=>({status:'waiting'}),readInstallation:()=>({version:'1.7.2'}),readProcesses:()=>{request.status='rejected';request.error='Target closed';return[{pid:123}];}});
 assert.deepEqual(result.requestBefore,{status:'pending'});assert.equal(result.candidate.error,'Diagnostic read timed out');assert.deepEqual(result.phase,{beforeQuitAt:null});assert.deepEqual(result.observer,{status:'waiting'});assert.deepEqual(result.processes,[{pid:123}]);assert.equal(result.requestAfter.status,'rejected');assert.equal(result.requestAfter.error,'Target closed');
});
test('individual diagnostic failures remain explicit while successful updater identity and other collectors survive',async()=>{
 const result=await collectUpgradeFailure({requestState:()=>({status:'fulfilled'}),readMain:()=>({pid:123,executable:'owned.exe',argv:['--test-mode'],update:{status:'installing',busy:true,token:'secret'},installer:{exists:true,bytes:99},window:{visible:true}}),readPhase:()=>({beforeQuitAt:1}),readObserver:()=>{throw new Error('Observer file missing');},readInstallation:()=>({version:'1.7.2'}),readProcesses:()=>[]});
 assert.equal(result.candidate.pid,123);assert.deepEqual(result.candidate.update,{status:'installing',busy:true});assert.equal(result.observer.error,'Observer file missing');assert.equal(result.installation.version,'1.7.2');assert.deepEqual(result.processes,[]);assert.equal(JSON.stringify(result).includes('secret'),false);
 await assert.doesNotReject(boundedRead(()=>{throw new Error('Synthetic metadata failure');}));
});
test('command settlement remains distinct from a later close timeout and preserves actual raw rejections',async()=>{
 let state;const result={update:{status:'installing',busy:true,token:'secret'}};
 await assert.rejects(observeInstallRequest(Promise.resolve(result),value=>state=value).then(()=>{throw new Error('Close timed out');}),/Close timed out/);assert.equal(state.status,'fulfilled');assert.equal(state.error,null);assert.deepEqual(state.update,{status:'installing',busy:true});
 const rejection=new Error('Target page closed');await assert.rejects(observeInstallRequest(Promise.reject(rejection),value=>state=value),value=>value===rejection);assert.equal(state.status,'rejected');assert.equal(state.error,rejection.message);assert.equal(state.closureLike,true);
});
