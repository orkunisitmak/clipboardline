'use strict';
const assert=require('node:assert/strict');
const {waitForImageEditorRaster}=require('./image-editor-ready.cjs');

// Every assertion uses the shipped renderer's genuine keyboard/click handlers.
// Only throwaway records and preferences are seeded through the isolated model.
module.exports=async function shortcutParity({page,application,check,until}){
 const original=await page.evaluate(()=>window.clipboardLine.state());
 const fixtures=await application.evaluate(({nativeImage})=>{
  const h=global.__clipboardLineTest,now=Date.now()+60000;
  const bitmap=Buffer.alloc(96*64*4);for(let i=0;i<bitmap.length;i+=4){bitmap[i]=76;bitmap[i+1]=164;bitmap[i+2]=223;bitmap[i+3]=255;}
  const image=h.store.insert('image',nativeImage.createFromBitmap(bitmap,{width:96,height:64}).toPNG());image.createdAt=now+3;image.name='Shortcut parity image';image.pinned=true;
  const first=h.store.insert('text','Shortcut parity first text'),second=h.store.insert('text','Shortcut parity second text');first.createdAt=now+2;second.createdAt=now+1;first.pinned=second.pinned=true;
  h.store.persist();return{image:image.id,first:first.id,second:second.id,ids:[image.id,first.id,second.id]};
 });
 const set=async patch=>{const result=await page.evaluate(patch=>window.clipboardLine.command('setSettings',{patch}),patch);assert.ok(!result.result?.error,result.result?.error);return result;};
 const show=async()=>{await page.evaluate(()=>window.clipboardLine.command('hide'));await page.evaluate(()=>window.clipboardLine.command('show'));await page.locator('.shelves').waitFor({state:'visible'});};
 const focus=()=>page.locator('.card.focused').first().getAttribute('data-item-id');
 const navigationSnapshot=()=>page.evaluate(async()=>{const state=await window.clipboardLine.state();const rows=Object.fromEntries(['image','text','link'].map(kind=>{const pinned=document.querySelector('[data-action="pinned-kind"][data-kind="'+kind+'"]')?.getAttribute('aria-pressed')==='true';return[kind,state.items.filter(value=>value.kind===kind&&!value.trashedAt&&!value.hiddenFromShelf&&(!pinned||value.pinned)).sort((a,b)=>b.createdAt-a.createdAt).map(value=>value.id)];}));return{rows,focus:document.querySelector('.card.focused')?.dataset.itemId,active:document.querySelector('.active-shelf')?.dataset.shelf,preview:document.querySelector('#preview-dialog')?.getAttribute('aria-label'),windowVisible:state.windowVisible,editor:{id:document.activeElement?.id,tag:document.activeElement?.tagName}};});
 const expectFocus=async id=>{try{return await until(focus,value=>value===id);}catch(error){throw new Error(error.message+'; expected navigation '+JSON.stringify({expected:id,...await navigationSnapshot()}));}};
 const palette=async query=>{await page.keyboard.press('Control+k');await page.locator('#modal-query').fill(query);};
 try{
  await set({visibleKinds:['image','text','link'],localShortcuts:Object.fromEntries(Object.keys(original.settings.localShortcuts||{}).map(action=>[action,null]))});await show();
  await page.keyboard.press('ArrowDown');await expectFocus(fixtures.first);await page.keyboard.press('ArrowRight');await expectFocus(fixtures.second);
  await set({localShortcuts:{previous:'P'}});await page.keyboard.press('p');await expectFocus(fixtures.first);
  assert.equal((await page.evaluate(()=>window.clipboardLine.state())).items.find(value=>value.id===fixtures.first).pinned,true);
  await palette('Previous item');assert.equal(await page.locator('[data-command="previous"] kbd').textContent(),'P');await page.keyboard.press('Escape');
  check('custom browsing shortcuts override new defaults and the action bar displays the key that actually wins');

  await set({localShortcuts:{previous:null,copy:'',pin:'',select2:'Q',extendNext:'Shift+J'}});
  await page.keyboard.press('Enter');await page.keyboard.press('Control+c');await page.keyboard.press('p');await page.keyboard.press('Control+p');
  assert.equal((await page.evaluate(()=>window.clipboardLine.state())).windowVisible,true);assert.equal((await page.evaluate(()=>window.clipboardLine.state())).items.find(value=>value.id===fixtures.first).pinned,true);
  await page.keyboard.press('q');await expectFocus(fixtures.second);await page.keyboard.press('ArrowLeft');await page.keyboard.press('Shift+ArrowRight');await expectFocus(fixtures.first);
  await page.keyboard.press('Shift+j');await expectFocus(fixtures.second);assert.equal(await page.locator('[data-shelf="text"] .card.selected').count(),2);
  check('disabled copy/pin aliases do not run; quick-number and Shift-arrow actions honor their recorded replacements');

  await set({localShortcuts:{copy:null,pin:null,select2:null,extendNext:null}});
  await palette('Preview');await page.keyboard.press('Enter');await until(()=>page.locator('#preview-dialog').getAttribute('aria-label'),name=>name==='Shortcut parity second text');
  await page.keyboard.press('e');await page.locator('#text-editor').fill('Shortcut parity edited text');await page.keyboard.press('Control+Enter');await page.locator('#text-editor').waitFor({state:'hidden'});
  assert.equal((await page.evaluate(()=>window.clipboardLine.state())).windowVisible,true);assert.equal((await page.evaluate(()=>window.clipboardLine.state())).items.find(value=>value.id===fixtures.second).text,'Shortcut parity edited text');
  const beforeUp=await navigationSnapshot(),column=beforeUp.rows.text.indexOf(fixtures.second);assert.equal(column,1,JSON.stringify(beforeUp));const expectedImage=beforeUp.rows.image[Math.min(column,beforeUp.rows.image.length-1)];assert.ok(expectedImage,JSON.stringify(beforeUp));await page.keyboard.press('ArrowUp');await expectFocus(expectedImage);assert.equal((await navigationSnapshot()).active,'image');
  // Up preserves the column; explicitly move to column zero to exercise the
  // deliberately tiny first image's markup workspace as well.
  await page.keyboard.press('Control+ArrowLeft');await expectFocus(fixtures.image);await page.keyboard.press('m');await waitForImageEditorRaster(page,{width:96,height:64});await page.keyboard.press('Control+Enter');await page.locator('#markup-canvas').waitFor({state:'hidden'});assert.equal(await page.locator('#preview-dialog').isVisible(),true);
  check('action-bar Preview uses the focused batch member and CtrlEnter finishes text/image editing while preserving preview');

  await palette('Marker');await page.keyboard.press('Enter');await waitForImageEditorRaster(page,{width:96,height:64});assert.equal(await page.locator('[data-tool="marker"]').getAttribute('aria-pressed'),'true');await page.keyboard.press('Control+Enter');await page.locator('#markup-canvas').waitFor({state:'hidden'});
  await page.keyboard.press('Escape');await page.keyboard.press('l');await page.locator('.library-grid').waitFor({state:'visible'});
  await palette('List view');await page.keyboard.press('Enter');await page.locator('.library-grid.list').waitFor({state:'visible'});
  await palette('Settings · History');await page.keyboard.press('Enter');await page.locator('[data-retention="text"]').waitFor({state:'visible'});await page.locator('[data-retention="link"]').waitFor({state:'visible'});
  check('action bar opens image tools, Library views and real Settings destinations through semantic commands');

  await page.locator('[data-action="settings-tab"][data-tab="shortcuts"]').click();await page.locator('[data-action="record-local"][data-key-action="pin"]').click();await page.keyboard.press('s');await page.locator('[data-action="confirm-modal"]').click();
  await until(()=>page.locator('#toast').textContent(),message=>message.includes('already used for Move to Trash'));assert.equal(await page.locator('[aria-label="Record shortcut"]').isVisible(),true);
  await page.keyboard.press('o');await page.locator('[data-action="confirm-modal"]').click();await page.locator('[aria-label="Record shortcut"]').waitFor({state:'hidden'});await show();await page.keyboard.press('o');
  assert.equal((await page.evaluate(()=>window.clipboardLine.state())).items.find(value=>value.id===fixtures.image).pinned,false);
  await page.keyboard.press('Space');await page.keyboard.press('m');await waitForImageEditorRaster(page,{width:96,height:64});await page.keyboard.press('o');assert.equal(await page.locator('[data-tool="ellipse"]').getAttribute('aria-pressed'),'true');await page.keyboard.press('Control+Enter');await page.locator('#markup-canvas').waitFor({state:'hidden'});await page.keyboard.press('Escape');
  check('shortcut recorder rejects overlapping actions but permits the same letter in separate browsing and markup contexts');
 }finally{
  await page.keyboard.press('Escape').catch(()=>{});
  const current=await page.evaluate(()=>window.clipboardLine.state());
  const {watchFolders,...restorable}=original.settings;await set({...restorable,localShortcuts:{...Object.fromEntries(Object.keys(current.settings.localShortcuts||{}).map(action=>[action,null])),...original.settings.localShortcuts}});
  await page.evaluate(ids=>window.clipboardLine.command('trash',{ids}),fixtures.ids);await page.evaluate(ids=>window.clipboardLine.command('delete',{ids}),fixtures.ids);await show();
 }
};
