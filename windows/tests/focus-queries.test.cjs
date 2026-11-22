'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {FocusQueries}=require('../lib/focus-queries.cjs');
test('focus capture uses the running monitor only after it reports ready',async()=>{
 const sent=[],queries=new FocusQueries(value=>sent.push(value));
 await assert.rejects(queries.capture(),/unavailable/);assert.deepEqual(sent,[]);
 queries.ready=true;const first=queries.capture(),second=queries.capture();
 assert.deepEqual(sent,['focus-capture:1\n','focus-capture:2\n']);
 const focus={handle:'42',processId:9,runtime:'1.2',editable:true,secure:false};
 assert.equal(queries.receive({focusQuery:2,ok:true,focus,captureTrace:{reason:'warm'}}),true);
 assert.equal(queries.receive({focusQuery:1,ok:true,focus:null,captureTrace:{reason:'deadline'}}),true);
 assert.deepEqual(await second,{focus,captureTrace:{reason:'warm'}});
 assert.deepEqual(await first,{focus:null,captureTrace:{reason:'deadline'}});
});
test('replies bind to their own pending ID; unknown, repeated or malformed replies are ignored',async()=>{
 const queries=new FocusQueries(()=>{});queries.ready=true;const pending=queries.capture();
 for(const value of [{focusQuery:9,ok:true},{focusQuery:'1',ok:true},{focusQuery:1},null,{clipboardQuery:1,sequence:3}])assert.equal(queries.receive(value),false);
 assert.equal(queries.receive({focusQuery:1,ok:false,error:'The focused element changed while it was being inspected.'}),true);
 await assert.rejects(pending,/focused element changed/);assert.equal(queries.receive({focusQuery:1,ok:true}),false);
 const array=queries.capture();queries.receive({focusQuery:2,ok:true,focus:[1,2]});assert.deepEqual(await array,{focus:null,captureTrace:null});
});
test('a silent, broken or stopped monitor rejects so the caller can use its one-shot helper',async()=>{
 const timed=new FocusQueries(()=>{},{timeout:1});timed.ready=true;await assert.rejects(timed.capture(),/timed out/);assert.equal(timed.pending.size,0);
 const broken=new FocusQueries(()=>{throw new Error('pipe closed');});broken.ready=true;await assert.rejects(broken.capture(),/pipe closed/);assert.equal(broken.pending.size,0);
 const stopped=new FocusQueries(()=>{});stopped.ready=true;const pending=stopped.capture();stopped.close();
 await assert.rejects(pending,/stopped/);assert.equal(stopped.available(),false);await assert.rejects(stopped.capture(),/unavailable/);
});
