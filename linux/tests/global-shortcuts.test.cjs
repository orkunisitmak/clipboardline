'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {GlobalShortcuts}=require('../lib/global-shortcuts.cjs');
const recordingContract=require('../../contracts/shortcut-recording.json');
function fixture(){const callbacks=new Map(),events=[],blocked=new Set(),fired=[];const registry={register(key,callback){events.push(['register',key]);if(blocked.has(key)||callbacks.has(key))return false;callbacks.set(key,callback);return true;},unregister(key){events.push(['unregister',key]);callbacks.delete(key);}};const shortcuts=new GlobalShortcuts(registry,Object.fromEntries(['toggle','search','library','copyLatest','screenshot'].map(action=>[action,()=>fired.push(action)])));return{callbacks,events,blocked,fired,shortcuts};}
test('every global action has a dedicated callback and optional Library/copy-latest never dispatch toggle',async()=>{const f=fixture();assert.deepEqual(f.shortcuts.update({toggle:'Control+Alt+T',search:'Control+Alt+S',library:'Control+Alt+L',copyLatest:'Control+Alt+C',screenshot:'Control+Alt+A'}),[]);for(const callback of f.callbacks.values())callback();await Promise.resolve();assert.deepEqual(f.fired,['toggle','search','library','copyLatest','screenshot']);assert.equal(f.fired.filter(action=>action==='toggle').length,1);f.shortcuts.dispose();assert.equal(f.callbacks.size,0);});
test('replacements register before releasing a working shortcut and a rejected key retains its previous callback',()=>{const f=fixture();f.shortcuts.update({toggle:'Control+Alt+T'});f.blocked.add('Control+Alt+X');assert.deepEqual(f.shortcuts.update({toggle:'Control+Alt+X'}),[{action:'toggle',shortcut:'Control+Alt+X',previous:'Control+Alt+T'}]);assert.equal(f.callbacks.has('Control+Alt+T'),true);f.events.length=0;assert.deepEqual(f.shortcuts.update({toggle:'Control+Alt+Y'}),[]);assert.deepEqual(f.events,[['register','Control+Alt+Y'],['unregister','Control+Alt+T']]);});
test('an in-use combination cannot steal another action and Off unregisters only its own binding',()=>{const f=fixture();f.shortcuts.update({toggle:'Control+Alt+T',library:'Control+Alt+L'});assert.equal(f.shortcuts.update({toggle:'Control+Alt+T',library:'Control+Alt+T'}).length,1);assert.equal(f.callbacks.has('Control+Alt+L'),true);f.shortcuts.update({toggle:'Control+Alt+T',library:''});assert.equal(f.callbacks.has('Control+Alt+L'),false);assert.equal(f.callbacks.has('Control+Alt+T'),true);assert.deepEqual(f.shortcuts.update({toggle:'Control+Alt+T',unknown:'Control+Alt+Z'}),[]);assert.equal(f.callbacks.has('Control+Alt+Z'),false);});
test('a synchronous or asynchronous shortcut action failure reports once instead of escaping the OS callback',async()=>{const f=fixture(),errors=[];f.shortcuts.failed=error=>errors.push(error.message);f.shortcuts.handlers.library=()=>{throw new Error('Library unavailable');};f.shortcuts.handlers.copyLatest=async()=>{throw new Error('Image unavailable');};f.shortcuts.update({library:'Control+Alt+L',copyLatest:'Control+Alt+C'});f.callbacks.get('Control+Alt+L')();f.callbacks.get('Control+Alt+C')();await Promise.resolve();assert.deepEqual(errors,['Library unavailable','Image unavailable']);});

test('recording leases release every owned shortcut and suppress stale callbacks until the final recorder closes',async()=>{
 const f=fixture(),values={toggle:'Control+Alt+T',search:'Control+Alt+S',library:'Control+Alt+L',copyLatest:'Control+Alt+C',screenshot:'Control+Alt+A'};
 assert.deepEqual(Object.keys(values),[...recordingContract.commonGlobalActions,...recordingContract.windowsAdditionalGlobalActions]);f.shortcuts.update(values);const stale=[...f.callbacks.values()];f.callbacks.set('Control+Alt+Unrelated',()=>{});
 const first=f.shortcuts.suspend(),second=f.shortcuts.suspend();assert.deepEqual([...f.callbacks.keys()],['Control+Alt+Unrelated']);
 for(const callback of stale)callback();await Promise.resolve();assert.deepEqual(f.fired,[]);
 first();first();assert.equal(f.shortcuts.suspended,true);assert.equal(f.callbacks.size,1);second();assert.equal(f.shortcuts.suspended,false);assert.equal(f.callbacks.size,6);for(const callback of stale)callback();await Promise.resolve();assert.deepEqual(f.fired,[]);
 for(const key of Object.values(values))f.callbacks.get(key)();await Promise.resolve();assert.deepEqual(f.fired,['toggle','search','library','copyLatest','screenshot']);f.shortcuts.dispose();assert.equal(f.callbacks.has('Control+Alt+Unrelated'),true);
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
