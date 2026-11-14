'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const os=require('node:os');
const path=require('node:path');
const {spawn}=require('node:child_process');
const {once}=require('node:events');
const {renameRetry}=require('./rename-retry.cjs');

const fail=code=>Object.assign(new Error(code+': synthetic'),{code});
async function fixture(run){
  const directory=fs.mkdtempSync(path.join(os.tmpdir(),'clipboardline-rename-retry-'));
  const destination=path.join(directory,'commands.json'),source=destination+'.tmp';
  const previous=JSON.stringify({action:'focus',serial:'previous'}),next=JSON.stringify({action:'save',serial:'next'});
  fs.writeFileSync(destination,previous);fs.writeFileSync(source,next);
  try{return await run({source,destination,previous,next});}
  finally{fs.rmSync(directory,{recursive:true,force:true});}
}

test('sharing violations retry the same complete command without replacing the old one early',()=>fixture(async({source,destination,previous,next})=>{
  const codes=['EPERM','EACCES','EBUSY'],pauses=[];let calls=0;
  await renameRetry(source,destination,{
    rename(from,to){
      assert.equal(from,source);assert.equal(to,destination);
      assert.equal(fs.readFileSync(source,'utf8'),next);assert.equal(fs.readFileSync(destination,'utf8'),previous);
      if(calls++<codes.length)throw fail(codes[calls-1]);
      fs.renameSync(from,to);
    },
    pause:async ms=>{pauses.push(ms);assert.equal(fs.readFileSync(destination,'utf8'),previous);}
  });
  assert.equal(calls,4);assert.deepEqual(pauses,[25,25,25]);
  assert.equal(fs.existsSync(source),false);assert.equal(fs.readFileSync(destination,'utf8'),next);
}));

test('persistent sharing violations stop at the default bound and preserve both files',()=>fixture(async({source,destination,previous,next})=>{
  const error=fail('EPERM');let calls=0,pauses=0;
  await assert.rejects(renameRetry(source,destination,{rename(){calls++;throw error;},pause:async()=>{pauses++;}}),value=>value===error);
  assert.equal(calls,20);assert.equal(pauses,19);
  assert.equal(fs.readFileSync(source,'utf8'),next);assert.equal(fs.readFileSync(destination,'utf8'),previous);
}));

test('missing files and unrelated failures propagate immediately',async()=>{
  for(const code of ['ENOENT','EISDIR','ENOSPC','EIO']){
    const error=fail(code);let calls=0;
    await assert.rejects(renameRetry('source','destination',{rename(){calls++;throw error;},pause:async()=>assert.fail('must not pause')}),value=>value===error);
    assert.equal(calls,1);
  }
});

test('an uncontended real rename publishes once without a delay',()=>fixture(async({source,destination,next})=>{
  await renameRetry(source,destination,{pause:async()=>assert.fail('must not pause')});
  assert.equal(fs.existsSync(source),false);assert.equal(fs.readFileSync(destination,'utf8'),next);
}));

test('a real Windows reader without delete sharing can release the destination during retries',{skip:process.platform!=='win32',timeout:15000},()=>fixture(async({source,destination,next})=>{
  const powershell=path.win32.join(process.env.SystemRoot||process.env.SYSTEMROOT||'C:\\Windows','System32','WindowsPowerShell','v1.0','powershell.exe');
  const script="$ErrorActionPreference='Stop'; $file=[IO.File]::Open('"+destination.replace(/'/g,"''")+"',[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read); try { [Console]::Out.WriteLine('locked'); [Console]::Out.Flush(); [void][Console]::In.ReadLine() } finally { $file.Dispose() }";
  const reader=spawn(powershell,['-NoProfile','-NonInteractive','-Command',script],{stdio:['pipe','pipe','pipe'],windowsHide:true});
  const lifetime=setTimeout(()=>reader.kill(),10000);
  const exited=once(reader,'exit');let stderr='';reader.stderr.on('data',bytes=>{stderr+=String(bytes);});
  try{
    await new Promise((resolve,reject)=>{
      let output='';
      reader.stdout.on('data',bytes=>{output+=String(bytes);if(output.includes('locked'))resolve();});
      reader.once('error',reject);reader.once('exit',code=>reject(new Error('Reader exited before taking the lock: '+code+' '+stderr)));
    });
    let collisions=0;
    await renameRetry(source,destination,{
      rename(from,to){
        try{fs.renameSync(from,to);}
        catch(error){collisions++;if(collisions===1)reader.stdin.end('\n');throw error;}
      }
    });
    assert.ok(collisions>0,'the actual Windows sharing lock must reject the first rename');
    assert.equal(fs.readFileSync(destination,'utf8'),next);assert.equal(fs.existsSync(source),false);
    const [code]=await exited;assert.equal(code,0,stderr);
  }finally{
    clearTimeout(lifetime);
    if(reader.exitCode===null){reader.kill();await exited;}
  }
}));
