'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {GlobalShortcuts}=require('../lib/global-shortcuts.cjs');
const recordingContract=require('../../contracts/shortcut-recording.json');
function fixture(){const callbacks=new Map(),events=[],blocked=new Set(),fired=[];const registry={register(key,callback){events.push(['register',key]);if(blocked.has(key)||callbacks.has(key))return false;callbacks.set(key,callback);return true;},unregister(key){events.push(['unregister',key]);callbacks.delete(key);}};const shortcuts=new GlobalShortcuts(registry,Object.fromEntries(['toggle','search','library','copyLatest','pause','screenshot'].map(action=>[action,()=>fired.push(action)])));return{callbacks,events,blocked,fired,shortcuts};}
test('every global action has a dedicated callback and optional Library/copy-latest never dispatch toggle',async()=>{const f=fixture();assert.deepEqual(f.shortcuts.update({toggle:'Control+Alt+T',search:'Control+Alt+S',library:'Control+Alt+L',copyLatest:'Control+Alt+C',pause:'Control+Alt+P',screenshot:'Control+Alt+A'}),[]);for(const callback of f.callbacks.values())callback();await Promise.resolve();assert.deepEqual(f.fired,['toggle','search','library','copyLatest','pause','screenshot']);assert.equal(f.fired.filter(action=>action==='toggle').length,1);f.shortcuts.dispose();assert.equal(f.callbacks.size,0);});
test('replacements register before releasing a working shortcut and a rejected key retains its previous callback',()=>{const f=fixture();f.shortcuts.update({toggle:'Control+Alt+T'});f.blocked.add('Control+Alt+X');assert.deepEqual(f.shortcuts.update({toggle:'Control+Alt+X'}),[{action:'toggle',shortcut:'Control+Alt+X',previous:'Control+Alt+T'}]);assert.equal(f.callbacks.has('Control+Alt+T'),true);f.events.length=0;assert.deepEqual(f.shortcuts.update({toggle:'Control+Alt+Y'}),[]);assert.deepEqual(f.events,[['register','Control+Alt+Y'],['unregister','Control+Alt+T']]);});
test('an in-use combination cannot steal another action and Off unregisters only its own binding',()=>{const f=fixture();f.shortcuts.update({toggle:'Control+Alt+T',library:'Control+Alt+L'});assert.equal(f.shortcuts.update({toggle:'Control+Alt+T',library:'Control+Alt+T'}).length,1);assert.equal(f.callbacks.has('Control+Alt+L'),true);f.shortcuts.update({toggle:'Control+Alt+T',library:''});assert.equal(f.callbacks.has('Control+Alt+L'),false);assert.equal(f.callbacks.has('Control+Alt+T'),true);assert.deepEqual(f.shortcuts.update({toggle:'Control+Alt+T',unknown:'Control+Alt+Z'}),[]);assert.equal(f.callbacks.has('Control+Alt+Z'),false);});
test('a synchronous or asynchronous shortcut action failure reports once instead of escaping the OS callback',async()=>{const f=fixture(),errors=[];f.shortcuts.failed=error=>errors.push(error.message);f.shortcuts.handlers.library=()=>{throw new Error('Library unavailable');};f.shortcuts.handlers.copyLatest=async()=>{throw new Error('Image unavailable');};f.shortcuts.update({library:'Control+Alt+L',copyLatest:'Control+Alt+C'});f.callbacks.get('Control+Alt+L')();f.callbacks.get('Control+Alt+C')();await Promise.resolve();assert.deepEqual(errors,['Library unavailable','Image unavailable']);});

test('a pair of owned global shortcuts can swap atomically without leaving old callbacks active',async()=>{
 const f=fixture();
 assert.deepEqual(f.shortcuts.update({toggle:'Control+Alt+T',search:'Control+Alt+S'}),[]);
 const stale=[...f.callbacks.values()];
 assert.deepEqual(f.shortcuts.update({toggle:'Control+Alt+S',search:'Control+Alt+T'}),[]);
 assert.deepEqual([...f.shortcuts.registered],[['toggle','Control+Alt+S'],['search','Control+Alt+T']]);
 for(const callback of stale)callback();await Promise.resolve();assert.deepEqual(f.fired,[]);
 f.callbacks.get('Control+Alt+S')();f.callbacks.get('Control+Alt+T')();await Promise.resolve();
 assert.deepEqual(f.fired,['toggle','search']);
});

test('failed atomic swap restores each previous working registration',async()=>{
 const f=fixture(),errors=[];f.shortcuts.failed=error=>errors.push(error.message);
 f.shortcuts.update({toggle:'Control+Alt+T',search:'Control+Alt+S'});
 const original=f.shortcuts.registry.register;let failOnce=true;
 f.shortcuts.registry.register=(key,callback)=>{if(failOnce&&key==='Control+Alt+S'){failOnce=false;return false;}return original(key,callback);};
 const rejected=f.shortcuts.update({toggle:'Control+Alt+S',search:'Control+Alt+T'});
 assert.equal(failOnce,false,'the registry should actually attempt the swap before rolling back');
 assert.ok(f.events.filter(event=>event[0]==='unregister').length>=2,'an owned pair must be released before trying the new bindings');
 assert.deepEqual(rejected.map(value=>value.action).sort(),['search','toggle']);
 assert.deepEqual([...f.shortcuts.registered],[['toggle','Control+Alt+T'],['search','Control+Alt+S']]);
 assert.deepEqual([...f.callbacks.keys()].sort(),['Control+Alt+S','Control+Alt+T']);
 f.callbacks.get('Control+Alt+T')();f.callbacks.get('Control+Alt+S')();
 assert.deepEqual(f.fired,['toggle','search']);assert.deepEqual(errors,[]);
});

test('recording leases release every owned shortcut and suppress stale callbacks until the final recorder closes',async()=>{
 const f=fixture(),values={toggle:'Control+Alt+T',search:'Control+Alt+S',library:'Control+Alt+L',copyLatest:'Control+Alt+C',pause:'Control+Alt+P',screenshot:'Control+Alt+A'};
 assert.deepEqual(Object.keys(values),[...recordingContract.commonGlobalActions,...recordingContract.windowsAdditionalGlobalActions]);f.shortcuts.update(values);const stale=[...f.callbacks.values()];f.callbacks.set('Control+Alt+Unrelated',()=>{});
 const first=f.shortcuts.suspend(),second=f.shortcuts.suspend();assert.deepEqual([...f.callbacks.keys()],['Control+Alt+Unrelated']);
 for(const callback of stale)callback();await Promise.resolve();assert.deepEqual(f.fired,[]);
 first();first();assert.equal(f.shortcuts.suspended,true);assert.equal(f.callbacks.size,1);second();assert.equal(f.shortcuts.suspended,false);assert.equal(f.callbacks.size,Object.keys(values).length+1);for(const callback of stale)callback();await Promise.resolve();assert.deepEqual(f.fired,[]);
 for(const key of Object.values(values))f.callbacks.get(key)();await Promise.resolve();assert.deepEqual(f.fired,['toggle','search','library','copyLatest','pause','screenshot']);f.shortcuts.dispose();assert.equal(f.callbacks.has('Control+Alt+Unrelated'),true);
});
test('recording cancellation restores the old key before a conflicting replacement is considered',()=>{
 const f=fixture();f.shortcuts.update({toggle:'Control+Alt+T'});const finish=f.shortcuts.suspend();finish();f.blocked.add('Control+Alt+X');
 assert.deepEqual(f.shortcuts.update({toggle:'Control+Alt+X'}),[{action:'toggle',shortcut:'Control+Alt+X',previous:'Control+Alt+T'}]);assert.equal(f.callbacks.has('Control+Alt+T'),true);
});
test('a disposed registry and stale recorder completion cannot resurrect registrations',()=>{
 const f=fixture();f.shortcuts.update({toggle:'Control+Alt+T'});const finish=f.shortcuts.suspend();f.shortcuts.dispose();finish();assert.equal(f.callbacks.size,0);assert.equal(f.shortcuts.suspended,false);
});
test('OS registration conflicts during suspension are reported without stealing the unrelated owner',()=>{
 const f=fixture(),errors=[];f.shortcuts.failed=error=>errors.push(error.message);f.shortcuts.update({search:'Control+Alt+S'});const finish=f.shortcuts.suspend();f.blocked.add('Control+Alt+S');finish();assert.equal(f.callbacks.size,0);assert.equal(errors.length,1);assert.match(errors[0],/could not be restored/);assert.equal(f.shortcuts.suspended,false);
});

test('an exception during OS suspension restores every previously released owned binding',()=>{
 const f=fixture();f.shortcuts.update({toggle:'Control+Alt+T',search:'Control+Alt+S'});const original=f.shortcuts.registry.unregister;let calls=0;
 f.shortcuts.registry.unregister=key=>{if(++calls===2)throw new Error('Synthetic OS unregister failure');original(key);};
 assert.throws(()=>f.shortcuts.suspend(),/unregister failure/);assert.equal(f.shortcuts.suspended,false);assert.equal(f.callbacks.size,2);assert.equal(f.callbacks.has('Control+Alt+T'),true);assert.equal(f.callbacks.has('Control+Alt+S'),true);for(const callback of f.callbacks.values())callback();assert.deepEqual(f.fired.sort(),['search','toggle']);
});


test('reassigning a released shortcut in the same update does not spuriously conflict',async()=>{
 const f=fixture();
 assert.deepEqual(f.shortcuts.update({toggle:'Control+Alt+T',search:'Control+Alt+S'}),[]);
 const old=[...f.callbacks.values()];
 assert.deepEqual(f.shortcuts.update({toggle:'Control+Alt+S',search:''}),[]);
 assert.deepEqual([...f.shortcuts.registered],[['toggle','Control+Alt+S']]);
 assert.deepEqual([...f.callbacks.keys()],['Control+Alt+S']);
 for(const callback of old)callback();
 await Promise.resolve();
 assert.deepEqual(f.fired,[]);
 f.callbacks.get('Control+Alt+S')();await Promise.resolve();
 assert.deepEqual(f.fired,['toggle']);
});


test('three owned shortcuts rotate in one settings update without losing their callbacks',async()=>{
 const f=fixture(),before={toggle:'Control+Alt+T',search:'Control+Alt+S',library:'Control+Alt+L'};
 assert.deepEqual(f.shortcuts.update(before),[]);
 const stale=[...f.callbacks.values()];
 const after={toggle:'Control+Alt+S',search:'Control+Alt+L',library:'Control+Alt+T'};
 assert.deepEqual(f.shortcuts.update(after),[]);
 assert.deepEqual(Object.fromEntries(f.shortcuts.registered),after);
 for(const callback of stale)callback();await Promise.resolve();assert.deepEqual(f.fired,[]);
 for(const action of ['toggle','search','library'])f.callbacks.get(after[action])();
 await Promise.resolve();assert.deepEqual(f.fired,['toggle','search','library']);
});

test('failed three-way rotation restores all owned registrations',async()=>{
 const f=fixture(),before={toggle:'Control+Alt+T',search:'Control+Alt+S',library:'Control+Alt+L'},after={toggle:'Control+Alt+S',search:'Control+Alt+L',library:'Control+Alt+T'};
 f.shortcuts.update(before);
 const stale=[...f.callbacks.values()];
 const unregister=f.shortcuts.registry.unregister;
 f.shortcuts.registry.unregister=key=>{const callback=f.callbacks.get(key);if(callback)stale.push(callback);unregister(key);};
 const original=f.shortcuts.registry.register;let deny=true;
 f.shortcuts.registry.register=(key,callback)=>{if(deny&&key===after.search){deny=false;return false;}return original(key,callback);};
 assert.deepEqual(f.shortcuts.update(after).map(item=>item.action).sort(),['library','search','toggle']);
 assert.equal(deny,false);
 assert.deepEqual(Object.fromEntries(f.shortcuts.registered),before);
 assert.deepEqual([...f.callbacks.keys()].sort(),Object.values(before).sort());
 for(const callback of new Set(stale))callback();await Promise.resolve();assert.deepEqual(f.fired,[]);
 for(const action of ['toggle','search','library'])f.callbacks.get(before[action])();
 await Promise.resolve();assert.deepEqual(f.fired,['toggle','search','library']);
});


test('failed cycle rollback identifies a previously owned key that the OS could not restore',()=>{
 const f=fixture(),errors=[];
 f.shortcuts.failed=error=>errors.push(error.message);
 const before={toggle:'Control+Alt+T',search:'Control+Alt+S',library:'Control+Alt+L'};
 const after={toggle:'Control+Alt+S',search:'Control+Alt+L',library:'Control+Alt+T'};
 f.shortcuts.update(before);
 const original=f.shortcuts.registry.register;
 let failNew=true,failRestore=true;
 f.shortcuts.registry.register=(key,callback)=>{
  if(key===after.search&&failNew){failNew=false;return false;}
  if(key===before.toggle&&failRestore){failRestore=false;return false;}
  return original(key,callback);
 };
 const rejected=f.shortcuts.update(after);
 assert.equal(failNew,false);assert.equal(failRestore,false);
 assert.deepEqual(rejected.filter(value=>value.restorationFailed).map(value=>value.action),['toggle']);
 assert.equal(f.shortcuts.registered.has('toggle'),false);
 assert.deepEqual([...f.callbacks.keys()].sort(),[before.search,before.library].sort());
 assert.equal(errors.length,1);
});
