'use strict';
const {test}=require('node:test');const assert=require('node:assert/strict');
const {PasteTargetTracker}=require('../lib/paste-target.cjs');
const field=(runtime='42.17',extra={})=>({handle:'1002',processId:200,runtime,editable:true,secure:false,...extra});
test('visible-window reentry follows the latest exact external editor without reading its contents',()=>{
  const tracker=new PasteTargetTracker(100);tracker.capture(field());
  tracker.observe(field('42.18',{name:'not retained',value:'not retained',selectedText:'not retained'}));
  tracker.observe(field('90.1',{handle:'1001',processId:100}));
  assert.deepEqual(tracker.reenter(),field('42.18'));assert.ok(Object.isFrozen(tracker.reenter()));
});
test('secure, read-only, missing and malformed external focus cannot reuse the previous editable target',()=>{
  const tracker=new PasteTargetTracker(100);
  for(const target of [field('42.18',{secure:true}),field('42.18',{editable:false}),field(''),null,field('invalid'),field('42.18',{handle:'../1002'}),field('42.18',{processId:-1})]){
    tracker.capture(field());tracker.observe(target);assert.ok(!tracker.reenter()?.editable,JSON.stringify(target));
  }
  tracker.capture(field());tracker.clear();assert.equal(tracker.reenter(),null);
});
test('fresh explicit capture replaces stale state and own events preserve only an already captured external identity',()=>{
  const tracker=new PasteTargetTracker(100);tracker.observe(field('90.1',{processId:100}));assert.equal(tracker.reenter(),null);
  tracker.capture(field());assert.equal(tracker.capture(null),null);tracker.observe(field('90.1',{processId:100}));assert.equal(tracker.reenter(),null);
  tracker.capture(field());assert.deepEqual(tracker.capture(field('90.1',{processId:100})),field());
});

test('a paste command resolves the latest exact external field even when a visible Library missed its focus callback',()=>{
  const tracker=new PasteTargetTracker(100),captured=tracker.capture(field('42.17'));
  tracker.observe(field('42.18',{name:'never retained',value:'never retained'}));
  tracker.observe(field('90.1',{handle:'1001',processId:100}));
  const target=tracker.resolve(captured);assert.deepEqual(target,field('42.18'));assert.ok(Object.isFrozen(target));
  // Once the operation starts, later focus events cannot retarget its snapshot;
  // the native prepare/validation gate must reject that changed destination.
  tracker.observe(field('42.19'));assert.deepEqual(target,field('42.18'));assert.deepEqual(tracker.resolve(captured),field('42.19'));
});

test('command-boundary resolution never upgrades missing, readonly, password or invalid external focus into an old eligible target',()=>{
  const tracker=new PasteTargetTracker(100);
  for(const observed of [field('42.18',{editable:false}),field('42.18',{secure:true}),null,field('invalid')]){
    const captured=tracker.capture(field());tracker.observe(observed);assert.ok(!tracker.resolve(captured)?.editable,JSON.stringify(observed));
  }
  tracker.capture(field());assert.equal(tracker.resolve(null),null);assert.equal(tracker.resolve(field('invalid')),null);
  const captured=tracker.capture(field());tracker.clear();assert.equal(tracker.resolve(captured),null);
});

test('canceling a paste terminates its native helpers without interrupting ordinary focus restoration',async()=>{
  const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
  const file=path.resolve(__dirname,'../lib/native.cjs'),requireFrom=require('node:module').createRequire(file),children=[];
  const execFile=(_executable,args,_options,done)=>{
    const child={mode:args.at(-1),killed:false,stdin:{end(){}},kill(){this.killed=true;done(new Error('canceled'),'');}};
    child.complete=()=>done(null,'{"ok":true}');children.push(child);return child;
  };
  const sandbox={module:{exports:{}},__dirname:path.dirname(file),process:{platform:'win32',env:{},pid:100},Buffer,
    require:name=>name==='node:child_process'?{execFile,spawn(){throw new Error('No monitor in this test');}}:requireFrom(name)};
  vm.runInNewContext(fs.readFileSync(file,'utf8'),sandbox,{filename:file});const native=sandbox.module.exports;
  const canceled=[native.preparePaste(field()),native.validatePaste(field()),native.paste(field()),native.copyImages({files:['synthetic.png']})].map(promise=>assert.rejects(promise,/did not respond/));
  const restored=native.restore(field());native.cancelPaste();
  assert.deepEqual(children.map(child=>child.killed),[true,true,true,true,false]);children.at(-1).complete();await restored;await Promise.all(canceled);
});

test('native startup stderr is bounded and visible only in an explicitly isolated acceptance process',async()=>{
  const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
  const file=path.resolve(__dirname,'../lib/native.cjs'),requireFrom=require('node:module').createRequire(file);
  for(const [argv,exposed]of [[[],false],[['--test-mode'],false],[['--test-mode','--test-data=C:\\synthetic-fixture'],true]]){
    const sandbox={module:{exports:{}},__dirname:path.dirname(file),process:{platform:'win32',env:{},pid:100,argv},Buffer,
      require:name=>name==='node:child_process'?{execFile(_file,_args,_options,done){queueMicrotask(()=>done(new Error('compiler'),'', 'Synthetic compiler diagnostic '+ 'x'.repeat(6000)));return{stdin:{end(){}}};}}:requireFrom(name)};
    vm.runInNewContext(fs.readFileSync(file,'utf8'),sandbox,{filename:file});
    await assert.rejects(sandbox.module.exports.capture(),error=>{assert.equal(error.message.includes('Synthetic compiler diagnostic'),exposed);assert.ok(error.message.length<2600);return true;});
  }
});

test('native capture diagnostics retain bounded readiness metadata after rejection without exposing provider payloads or changing target schema',async()=>{
  const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
  const file=path.resolve(__dirname,'../lib/native.cjs'),requireFrom=require('node:module').createRequire(file);
  const failed={reason:'sample-limit',samples:80,loadingSamples:79,missingSamples:1,elapsedMs:2430};
  const succeeded={reason:'stable-editor',samples:4,loadingSamples:1,missingSamples:1,elapsedMs:95};
  const replies=[{ok:false,error:'Synthetic capture rejected',captureTrace:{...failed,value:'never retained',name:'never retained'}},
    {ok:true,chain:[]},{...field(),captureTrace:succeeded},{ok:true,chain:[]},
    {...field(),captureTrace:{...failed,samples:81,value:'never retained'}},{ok:true,chain:[]}];
  const sandbox={module:{exports:{}},__dirname:path.dirname(file),process:{platform:'win32',env:{},pid:100,argv:[]},Buffer,
    require:name=>name==='node:child_process'?{execFile(_file,_args,_options,done){const reply=replies.shift();queueMicrotask(()=>done(reply.ok===false?new Error('rejected'):null,JSON.stringify(reply),''));return{stdin:{end(){}}};}}:requireFrom(name)};
  vm.runInNewContext(fs.readFileSync(file,'utf8'),sandbox,{filename:file});const native=sandbox.module.exports;
  await assert.rejects(native.capture(),/Synthetic capture rejected/);
  const diagnostic=JSON.parse(JSON.stringify(await native.captureDiagnostics()));assert.deepEqual(diagnostic.captureTrace,failed);assert.ok(!JSON.stringify(diagnostic).includes('never retained'));
  assert.deepEqual(JSON.parse(JSON.stringify(await native.capture())),field());
  assert.deepEqual(JSON.parse(JSON.stringify(await native.captureDiagnostics())).captureTrace,succeeded);
  assert.deepEqual(JSON.parse(JSON.stringify(await native.capture())),field());
  assert.equal((await native.captureDiagnostics()).captureTrace,undefined,'Invalid metadata must not retain an earlier capture trace');
  assert.equal(replies.length,0);
});
