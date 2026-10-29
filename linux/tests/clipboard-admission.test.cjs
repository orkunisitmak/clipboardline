'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),path=require('node:path'),fs=require('node:fs');
const {privateClipboard,readClipboardContent}=require('../lib/clipboard-policy.cjs');
const {ClipboardSequenceQueries}=require('../lib/clipboard-sequence.cjs');
const contract=JSON.parse(fs.readFileSync(path.join(__dirname,'../../contracts/clipboard-admission.json'),'utf8'));
const marker=Buffer.from('synthetic-own-marker');
const {plainURL}=require('../lib/model.cjs');
function board(values,options={}){
 let reads=0,formatReads=0,sequence=10;const requests=[];
 const entries=values.map(value=>({types:Object.keys(value),getType:async type=>{reads++;requests.push(type);if(options.duringRead)await options.duringRead(type,api);return new Blob([value[type]]);}}));
 const api={get reads(){return reads;},get formatReads(){return formatReads;},requests,advance(){sequence++;},sequence:async()=>sequence,
 clipboard:{read:async()=>{formatReads++;options.duringFormats?.(api);return entries;},readText:async()=>{throw new Error('A second live text read is forbidden.');}}};return api;
}
const read=api=>readClipboardContent({...api,marker,plainURL});
test('shared external private-marker contract rejects any item before requesting payload',async()=>{
 for(const marker of contract.privateMarkers){
  for(const format of [marker,'electron application/osclipboard;format="'+marker+'"']){
   assert.equal(privateClipboard(['text/plain',format]),true,format);
   for(const same of [false,true]){
    for(const content of [{'text/plain':'synthetic private'},{'image/png':Buffer.from([1,2,3])}]){
     const api=board(same?[{...content,[format]:''}]:[content,{[format]:''}]);
     assert.equal(await read(api),null,format);assert.equal(api.reads,0,format);
    }
   }
  }
 }
});
test('shared clipboard text contract rejects only whitespace and preserves accepted bytes',async()=>{
 for(const row of contract.textCases){const api=board([{'text/plain':row.value}]),result=await read(api);assert.equal(!!result,row.capture,row.name);if(row.capture)assert.deepEqual(Buffer.from(result.value),Buffer.from(row.value),row.name);}
});
test('changed generation before payload never reads content and requests a fresh attempt',async()=>{
 const api=board([{'text/plain':'stale public'}],{duringFormats:value=>value.advance()});
 assert.deepEqual(await read(api),{raced:true});assert.equal(api.reads,0);
});
test('replacement during text or image payload cannot be admitted',async()=>{
 for(const type of ['text/plain','image/png']){
  const api=board([{[type]:'stale public'}],{duringRead:(_type,value)=>value.advance()});
  assert.deepEqual(await read(api),{raced:true});assert.equal(api.reads,1);
 }
});
test('fresh read after a race rejects private replacement and later accepts exact public content',async()=>{
 const raced=board([{'text/plain':'stale public'}],{duringRead:(_type,value)=>value.advance()});assert.deepEqual(await read(raced),{raced:true});
 const secret=board([{'text/plain':'synthetic secret'},{'com.agilebits.onepassword':''}]);assert.equal(await read(secret),null);assert.equal(secret.reads,0);
 assert.equal((await read(board([{'text/plain':' latest public\n'}]))).value,' latest public\n');
});
test('missing or failed native generation query safely admits nothing',async()=>{
 for(const value of [null,undefined,0,-1,NaN,2**32]){const api=board([{'text/plain':'unverified'}]);api.sequence=async()=>value;assert.equal(await read(api),null);assert.equal(api.formatReads,0);}
 const api=board([{'text/plain':'unverified'}]);api.sequence=async()=>{throw new Error('monitor unavailable');};assert.equal(await read(api),null);assert.equal(api.reads,0);
});
test('native history opt-out and own copies never request text or image payload',async()=>{
 for(const bytes of [Buffer.alloc(0),Buffer.from([0,0,0,0])]){
  const api=board([{'text/plain':'private','electron application/osclipboard;format="CanIncludeInClipboardHistory"':bytes}]);assert.equal(await read(api),null);assert.equal(api.requests.includes('text/plain'),false);
 }
 const api=board([{'image/png':'unused','web application/x.clipboardline':marker}]);assert.equal(await read(api),null);assert.deepEqual(api.requests,['web application/x.clipboardline']);
});
test('bounded UTF8 byte payload and invalid UTF8 cannot enter history',async()=>{
 for(const value of [Buffer.alloc(1024*1024+1,65),Buffer.from([0xff])])assert.equal(await read(board([{'text/plain':value}])),null);
});
test('native sequence replies are nonce-bound and cannot masquerade as change notifications',async()=>{
 const sent=[],queries=new ClipboardSequenceQueries(value=>sent.push(value));
 const first=queries.read(),second=queries.read();assert.deepEqual(sent,['clipboard-sequence:1\n','clipboard-sequence:2\n']);
 assert.equal(queries.receive({sequence:5}),false);assert.equal(queries.receive({clipboardQuery:1,sequence:-1}),false);assert.equal(queries.receive({clipboardQuery:1,sequence:0}),false);
 assert.equal(queries.receive({clipboardQuery:2,sequence:21}),true);assert.equal(await second,21);
 assert.equal(queries.receive({clipboardQuery:99,sequence:9}),false);queries.receive({clipboardQuery:1,sequence:20});assert.equal(await first,20);queries.close();
});
test('native sequence channel timeout, send failure and shutdown reject bounded outstanding queries',async()=>{
 const timed=new ClipboardSequenceQueries(()=>{},{timeout:1});await assert.rejects(timed.read(),/timed out/);assert.equal(timed.pending.size,0);timed.close();
 const failed=new ClipboardSequenceQueries(()=>{throw new Error('pipe closed');});await assert.rejects(failed.read(),/pipe closed/);assert.equal(failed.pending.size,0);failed.close();
 const stopped=new ClipboardSequenceQueries(()=>{});const pending=stopped.read();stopped.close();await assert.rejects(pending,/stopped/);await assert.rejects(stopped.read(),/unavailable/);
});

test('oversized native metadata is rejected before allocating its buffer',async()=>{
 for(const format of ['web application/x.clipboardline','electron application/osclipboard;format="CanIncludeInClipboardHistory"']){
  let buffers=0;const clipboard={read:async()=>[{types:[format,'text/plain'],getType:async()=>({size:64*1024*1024,arrayBuffer:async()=>{buffers++;throw new Error('Oversized metadata buffer must not be allocated.');}})}]};
  assert.equal(await readClipboardContent({clipboard,sequence:async()=>1,marker,plainURL}),null);assert.equal(buffers,0);
 }
});
