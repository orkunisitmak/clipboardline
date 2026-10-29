'use strict';
const assert=require('node:assert/strict');
async function rejectRecordedSettings(api=window.clipboardLine){
 const {shortcutRecordingToken}=await api.state();
 if(typeof shortcutRecordingToken!=='string'||!shortcutRecordingToken)throw new Error('An active shortcut recorder token is required for the exception test.');
 return api.command('setSettings',{recordingToken:shortcutRecordingToken,patch:{watchFolders:[]}});
}
module.exports=async function shortcutRecordingAcceptance({page,application,check,until,fixtureCommand}){
 const original=(await page.evaluate(()=>window.clipboardLine.state())).settings.shortcuts;
 const blocked='Control+Alt+Shift+F11';
 const nativeState=()=>application.evaluate(({globalShortcut})=>({recording:global.__clipboardLineTest.getShortcutRecordingState(),search:globalShortcut.isRegistered('Control+Alt+S'),unrelated:globalShortcut.isRegistered('Control+Alt+Shift+F11')}));
 const open=async(action,global=true)=>{
  await page.evaluate(()=>window.clipboardLine.command('settings'));
  await application.evaluate(()=>global.__clipboardLineTest.getWindow().focus());
  await page.locator('[data-action="settings-tab"][data-tab="shortcuts"]').click();
  await page.locator('[data-action="record-'+(global?'global':'local')+'"][data-key-action="'+action+'"]').click();
  await page.locator('.record-wait[data-recording-ready="true"]').waitFor();
  const state=await nativeState();assert.equal(state.recording.suspended,true);assert.equal(state.search,false);assert.equal(state.unrelated,true);
 };
 const ended=async()=>{await until(nativeState,value=>!value.recording.suspended&&value.search&&value.unrelated);await page.locator('[aria-label="Record shortcut"]').waitFor({state:'hidden'});};
 const extra=await application.evaluate(({globalShortcut},key)=>globalShortcut.register(key,()=>{}),blocked);assert.equal(extra,true,'Isolated unrelated shortcut must be available.');
 try{
  await open('search');await fixtureCommand({action:'keys',keys:'^%s'});
  await until(()=>page.locator('.record-wait').textContent(),value=>value==='Ctrl+Alt+S');
  assert.equal((await page.evaluate(()=>window.clipboardLine.state())).view,'settings');
  await page.locator('[data-action="confirm-modal"]').click();await ended();
  assert.equal((await page.evaluate(()=>window.clipboardLine.state())).settings.shortcuts.search,original.search);
  await open('pin',false);await fixtureCommand({action:'keys',keys:'^%s'});
  await until(()=>page.locator('.record-wait').textContent(),value=>value==='Ctrl+Alt+S');
  await fixtureCommand({action:'keys',keys:'{ESC}'});await ended();
  await open('search');// An unrelated OS owner correctly intercepts its own key; inject just this
  // candidate through Chromium, then test the real conflicting OS registration.
  await page.keyboard.press('Control+Alt+Shift+F11');
  await until(()=>page.locator('.record-wait').textContent(),value=>value==='Ctrl+Alt+Shift+F11');
  await page.locator('[data-action="confirm-modal"]').click();await ended();
  assert.equal((await page.evaluate(()=>window.clipboardLine.state())).settings.shortcuts.search,original.search);
  await until(()=>page.locator('#toast').textContent(),value=>value.includes('unavailable'));
  await open('pin',false);await page.evaluate(()=>window.clipboardLine.command('windowClose'));await ended();
  await open('pin',false);const rejected=await page.evaluate(rejectRecordedSettings);assert.equal(rejected.result?.error,'Choose watched folders with the folder picker.');await ended();
  await open('pin',false);await fixtureCommand({action:'focus',target:'plain'});await ended();
  await fixtureCommand({action:'keys',keys:'^%s'});await page.locator('#search-input').waitFor({state:'visible'});
  check('native shortcut recorders capture existing combinations, preserve unrelated bindings and restore on save, cancel, conflict, close, exception and focus loss');
 }finally{
  await application.evaluate(({globalShortcut},key)=>globalShortcut.unregister(key),blocked);
  await application.evaluate(async()=>{const api=global.__clipboardLineTest,token=api.getShortcutRecordingState().token;if(token)await api.command('endShortcutRecording',{token});}).catch(()=>{});
  await page.evaluate(shortcuts=>window.clipboardLine.command('setSettings',{patch:{shortcuts}}),original);
 }
};
module.exports.rejectRecordedSettings=rejectRecordedSettings;
