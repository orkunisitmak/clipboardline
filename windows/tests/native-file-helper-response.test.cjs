'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {spawnSync}=require('node:child_process');
const fs=require('node:fs'),os=require('node:os'),path=require('node:path');

test('a scalar native file-helper reply rejects without terminating the main process',t=>{
 const directory=fs.mkdtempSync(path.join(os.tmpdir(),'clipboardline-file-helper-reply-'));
 t.after(()=>fs.rmSync(directory,{recursive:true,force:true}));
 const source=path.join(directory,'synthetic.txt');
 fs.writeFileSync(source,'synthetic file bytes');
 const helper=String.raw`
 const file=process.argv[1],source=process.argv[2];
 const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
 const requireFrom=require('node:module').createRequire(file);
 const execFile=(_exe,_args,_opts,done)=>{
  const child={stdin:{on(){},end(){}},kill(){}};
  queueMicrotask(()=>done(null,'null'));
  return child;
 };
 const sandbox={module:{exports:{}},__dirname:path.dirname(file),process:{platform:'win32',env:{SystemRoot:'C:\\\\Windows'}},
  require:name=>name==='node:child_process'?{execFile}:requireFrom(name)};
 vm.runInNewContext(fs.readFileSync(file,'utf8'),sandbox,{filename:file});
 sandbox.module.exports.copyFiles({files:[source]}).then(
  ()=>{console.error('Unexpected native success');process.exitCode=2;},
  err=>{if(!/helper did not respond/.test(err.message)){console.error(err);process.exitCode=3;}else{console.log('expected-rejection');}}
 );
 `;
 const child=spawnSync(process.execPath,['-e',helper,require.resolve('../lib/native-files.cjs'),source],{encoding:'utf8',timeout:6000});
 assert.equal(child.status,0,'Main process should survive malformed native output: '+(child.stderr||child.error||''));
 assert.equal(child.stdout.trim(),'expected-rejection','the helper must reject, not simply exit with an unresolved promise');
});
