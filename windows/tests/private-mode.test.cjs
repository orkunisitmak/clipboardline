'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {Store,DEFAULTS}=require('../lib/model.cjs');
const {statusSummary}=require('../lib/status-summary.cjs');
function fixture(fn){const dir=fs.mkdtempSync(path.join(os.tmpdir(),'clipboardline-private-mode-'));let now=1000;try{const store=new Store(dir,{clock:()=>now});return fn(store,value=>{now=value;},dir);}finally{fs.rmSync(dir,{recursive:true,force:true});}}

test('private mode is an off-by-default persisted preference with an optional shortcut',()=>fixture((store,time,dir)=>{
  assert.equal(DEFAULTS.paused,false);
  assert.equal(DEFAULTS.shortcuts.pause,'');
  assert.equal(store.data.settings.paused,false);
  store.modify('setSettings',{patch:{paused:true}});
  store.modify('setSettings',{patch:{shortcuts:{pause:'Control+Alt+P'}}});
  assert.equal(store.data.settings.paused,true);
  assert.equal(store.data.settings.shortcuts.pause,'Control+Alt+P');
  assert.throws(()=>store.modify('setSettings',{patch:{paused:'on'}}),/Invalid preference/);
  assert.throws(()=>store.modify('setSettings',{patch:{shortcuts:{pause:42}}}),/Invalid shortcut/);
  assert.throws(()=>store.modify('setSettings',{patch:{shortcuts:{unknown:'Control+Alt+Z'}}}),/Invalid shortcut/);
  // A stale setting cannot leave the saved store on: the last accepted value is persisted.
  assert.equal(store.data.settings.paused,true);
  const reloaded=new Store(dir,{clock:()=>1000});
  assert.equal(reloaded.data.settings.paused,true);
  assert.equal(reloaded.data.settings.shortcuts.pause,'Control+Alt+P');
}));

test('private mode is visible in the tray tooltip and keeps the tray menu in sync',()=>{
  const settings={language:'en',visibleKinds:['text'],paused:false};
  const idle=statusSummary({items:[{kind:'text'}],settings});
  const paused=statusSummary({items:[{kind:'text'}],settings:{...settings,paused:true}});
  assert.equal(idle.paused,false);
  assert.equal(paused.paused,true);
  assert.notEqual(paused.menuKey,idle.menuKey);
  assert.match(paused.tooltip,/Private mode is on\. New captures are paused\./);
  assert.doesNotMatch(idle.tooltip,/Private mode/);
  assert.equal(paused.dim,true);
});
