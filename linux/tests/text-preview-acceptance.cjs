'use strict';
const assert=require('node:assert/strict');

// Runs on actual Windows source, packaged and installed Electron sessions. The
// controlled-clock suite covers IPC failures; this verifies the real textarea
// remains the same browser editor through saves, undo and native state packets.
module.exports=async function textPreview({page,application,check,until}){
 const original=(await page.evaluate(()=>window.clipboardLine.state())).settings;
 const source='Native text preview source',draft='Native text preview edited\nUnicode: Çığ café';
 const fixture=await application.evaluate(async(_electron,text)=>{
  const h=global.__clipboardLineTest,item=h.store.insert('text',text);item.createdAt=Date.now()+3600000;h.store.persist();
  await h.command('setSettings',{patch:{visibleKinds:['image','text','link'],localShortcuts:{up:null,down:null,preview:null,edit:null,finishEditing:null,pin:null,pinnedOnly:null}}});
  await h.command('hide');await h.command('show');return item.id;
 },source);
 const stored=()=>page.evaluate(id=>window.clipboardLine.state().then(state=>state.items.find(value=>value.id===id)),fixture);
 try{
  await page.locator('[data-shelf="text"] [data-item-id="'+fixture+'"]').click();await until(()=>page.locator('[data-shelf="text"] .card.focused').getAttribute('data-item-id'),id=>id===fixture);
  await page.keyboard.press('Space');await page.locator('.preview-text').click();const editor=page.locator('#text-editor');await editor.waitFor({state:'visible'});
  await page.waitForFunction(()=>document.activeElement===document.getElementById('text-editor'));
  await editor.evaluate(node=>{window.__textPreviewAcceptanceEditor=node;});
  await page.keyboard.press('Control+a');await page.keyboard.insertText(draft);
  await until(stored,value=>value?.text===draft);
  assert.equal(await editor.evaluate(node=>node===window.__textPreviewAcceptanceEditor),true,'Autosave must preserve the browser editor and undo session');
  await editor.evaluate(node=>node.setSelectionRange(3,8));
  await page.evaluate(value=>window.clipboardLine.command('setSettings',{patch:{sounds:value}}),original.sounds);
  assert.deepEqual(await editor.evaluate(node=>({same:node===window.__textPreviewAcceptanceEditor,start:node.selectionStart,end:node.selectionEnd,focused:node===document.activeElement})),{same:true,start:3,end:8,focused:true});
  await page.keyboard.press('Control+z');await until(()=>editor.inputValue(),value=>value===source);
  await page.keyboard.press('Control+Shift+z');await until(()=>editor.inputValue(),value=>value===draft);await until(stored,value=>value?.text===draft);
  await page.keyboard.press('Control+p');await until(stored,value=>value?.pinned===true);assert.equal(await editor.isVisible(),true);
  await page.keyboard.press('Control+Shift+f');await editor.waitFor({state:'hidden'});assert.equal(await page.locator('#preview-dialog').isVisible(),true);assert.equal((await stored()).text,draft);
  check('actual text preview click-edit autosaves while preserving the editor, native undo/redo, selection and focus; modified Pin works and filtering safely finishes editing');
 }finally{
  await page.keyboard.press('Escape').catch(()=>{});await page.keyboard.press('Escape').catch(()=>{});
  const current=(await page.evaluate(()=>window.clipboardLine.state())).settings.localShortcuts||{};
  const reset=Object.fromEntries([...new Set([...Object.keys(current),...Object.keys(original.localShortcuts||{})])].map(key=>[key,original.localShortcuts?.[key]??null]));
  await page.evaluate(patch=>window.clipboardLine.command('setSettings',{patch}),{visibleKinds:original.visibleKinds,localShortcuts:reset});
  await page.evaluate(id=>window.clipboardLine.command('trash',{ids:[id]}),fixture);await page.evaluate(id=>window.clipboardLine.command('delete',{ids:[id]}),fixture);
  await page.evaluate(()=>window.clipboardLine.command('show'));
 }
};
