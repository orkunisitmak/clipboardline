'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const os=require('node:os');
const path=require('node:path');
const {readJsonRetry}=require('./read-json-retry.cjs');

const fail=code=>Object.assign(new Error(code+': synthetic'),{code});
const sequence=(...steps)=>{const calls=[];return{calls,read(){calls.push(1);const step=steps[Math.min(calls.length-1,steps.length-1)];if(step instanceof Error)throw step;return step;}};};

test('a sharing violation or a half-written state file is retried until the fixture finishes writing',()=>{
  const slept=[],s=sequence(fail('EBUSY'),fail('EPERM'),fail('EACCES'),'{"ready":tr','{"ready":true}');
  assert.deepEqual(readJsonRetry('state.json',{read:s.read,sleep:ms=>slept.push(ms)}),{ready:true});
  assert.equal(s.calls.length,5);assert.deepEqual(slept,[25,25,25,25]);
});
test('a persistent lock is reported after the bounded attempts',()=>{
  const s=sequence(fail('EBUSY'));
  assert.throws(()=>readJsonRetry('state.json',{read:s.read,sleep(){},attempts:4}),{code:'EBUSY'});assert.equal(s.calls.length,4);
});
test('a missing file and unrelated errors are not retried so until() can keep polling',()=>{
  for(const code of ['ENOENT','EISDIR']){const s=sequence(fail(code),'{}');assert.throws(()=>readJsonRetry('state.json',{read:s.read,sleep(){}}),{code});assert.equal(s.calls.length,1);}
});
test('reads a real file',()=>{
  const directory=fs.mkdtempSync(path.join(os.tmpdir(),'clipboardline-json-retry-')),file=path.join(directory,'state.json');
  try{fs.writeFileSync(file,'{"a":1}');assert.deepEqual(readJsonRetry(file),{a:1});}finally{fs.rmSync(directory,{recursive:true,force:true});}
});
