'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
// Resolve and mutate the live viewport in one renderer task. A locator's
// ElementHandle may detach between resolution and evaluation when an ordinary
// state packet rebuilds the view; detached nodes report zero scroll ranges.
function setViewportPosition({selector,top,left}){
 const node=document.querySelector(selector);if(!node?.isConnected)throw new Error('The current scroll viewport is unavailable.');
 if(top!==undefined)node.scrollTop=top;if(left!==undefined)node.scrollLeft=left;return{top:node.scrollTop,left:node.scrollLeft};
}
module.exports=async function scrollStateAcceptance({page,application,check,until,output}){
 const fixture=await application.evaluate(async()=>{
  const h=global.__clipboardLineTest,crypto=process.getBuiltinModule('node:crypto'),prefix='Viewport '+crypto.randomUUID(),ids=[],folders=[];
  const original=Object.fromEntries(['librarySidebarVisible','libraryInspectorVisible','libraryListMode','libraryListColumns'].map(key=>[key,h.store.data.settings[key]]));
  for(let index=0;index<24;index++)folders.push(h.store.modify('createFolder',{name:prefix+' folder '+String(index).padStart(2,'0')}).id);
  for(let index=0;index<28;index++){const value=h.store.insert('text',prefix+' body '+index+'\n'+('Synthetic long content row\n'.repeat(30)));h.store.modify('details',{id:value.id,name:prefix+' note '+index,note:prefix+' note body '+index});ids.push(value.id);}
  h.store.modify('retain',{ids});const primary=ids.at(-1),secondary=ids.at(-2);for(const folderId of folders)h.store.modify('folder',{ids:[primary],folderId,pinning:false});h.store.modify('tag',{ids:[primary],tags:Array.from({length:16},(_,index)=>prefix+' tag '+index)});
  const originals=Object.fromEntries([primary,secondary].map(id=>{const value=h.store.item(id);return[id,{name:value.name,text:value.text,note:value.note}];}));
  await h.command('setSettings',{patch:{librarySidebarVisible:true,libraryInspectorVisible:true,libraryListMode:false,libraryListColumns:{title:480,kind:120,tags:240,created:180}}});await h.command('library');return{prefix,ids,folders,primary,secondary,original,originals};
 });
 async function packet(selectId=null){
  const token=fixture.prefix+':'+Math.random();
  await page.evaluate(token=>{window.__viewportPacket?.cleanup?.();const value={token,received:false};const unsubscribe=window.clipboardLine.subscribe(state=>{if(state.__scrollStateAcceptancePacket!==token)return;value.received=true;unsubscribe();});value.cleanup=unsubscribe;window.__viewportPacket=value;},token);
  await application.evaluate((_electron,{token,selectId})=>{const h=global.__clipboardLineTest,snapshot=h.state();if(selectId)snapshot.viewEvent={selectId,kind:'text',serial:token};h.getWindow().webContents.send('clipboardline:changed',{...snapshot,__scrollStateAcceptancePacket:token});},{token,selectId});
  await until(()=>page.evaluate(()=>window.__viewportPacket.received),Boolean);
 }
 const positions=selectors=>page.evaluate(selectors=>Object.fromEntries(selectors.map(selector=>{const node=document.querySelector(selector);return[selector,{top:node.scrollTop,left:node.scrollLeft}];})),selectors);
 const stored=id=>page.evaluate(id=>window.clipboardLine.state().then(state=>state.items.find(value=>value.id===id)),id);
 async function switchListMode(expected){
  await page.locator('[data-action="view-mode"]').click();
  await until(()=>page.evaluate(()=>window.clipboardLine.state().then(value=>value.settings.libraryListMode)),value=>value===expected);
  await until(()=>page.evaluate(()=>{const grid=document.querySelector('.library-grid'),results=document.querySelector('.library-results');return{list:grid?.classList.contains('list'),width:results?.clientWidth,scrollWidth:results?.scrollWidth,height:results?.clientHeight,scrollHeight:results?.scrollHeight};}),value=>value.list===expected&&(!expected||(value.scrollWidth-value.width>=100&&value.scrollHeight-value.height>=160)));
  // The mode transition is itself a context change. Project its committed state
  // before measuring preservation across the following same-context packet.
  await packet();
 }
 try{
  await page.locator('[data-action="scope"][data-scope="saved"]').click();const clear=page.locator('[data-action="clear-filters"]').first();if(await clear.count()&&await clear.isVisible())await clear.click();await page.locator('[data-action="allTypes"]').click();await page.locator('#sort-filter').selectOption('newest');await page.locator('#search-input').fill(fixture.prefix);
  await page.locator('.library-grid [data-item-id="'+fixture.primary+'"]').click();await until(()=>page.locator('#detail-name').inputValue(),value=>value===fixture.originals[fixture.primary].name);
  const selectors=['.library-results','.sidebar','.inspector'];await page.evaluate(selectors=>{for(const selector of selectors){const node=document.querySelector(selector);node.scrollTop=200;}},selectors);const before=await positions(selectors);for(const selector of selectors)assert.ok(before[selector].top>0,selector+' fixture must overflow');await packet();assert.deepEqual(await positions(selectors),before);
  await page.locator('#search-input').fill(fixture.originals[fixture.primary].name);assert.equal((await positions(['.library-results']))['.library-results'].top,0);await page.locator('#search-input').fill(fixture.prefix);
  await switchListMode(true);const horizontal={'.library-results':await page.evaluate(setViewportPosition,{selector:'.library-results',top:160,left:100})};assert.deepEqual(horizontal['.library-results'],{top:160,left:100});await packet();assert.deepEqual(await positions(['.library-results']),horizontal);
  await switchListMode(false);await page.locator('.library-grid [data-item-id="'+fixture.primary+'"]').click();
  for(const [field,key]of [['detail-name','name'],['detail-text','text'],['detail-note','note']]){
   const editor=page.locator('#'+field),original=fixture.originals[fixture.primary][key],suffix='_Edited'+key,draft=original+suffix;
   assert.equal(await editor.inputValue(),original,'The '+field+' editor must initially show this record’s own value');await editor.focus();await page.waitForFunction(id=>document.activeElement?.id===id,field);await editor.evaluate(node=>{window.__inspectorAcceptance={field:node,inspector:node.closest('.inspector'),library:node.closest('.library'),shell:node.closest('.shell')};});
   // Use one native text/IME commit for the strict single-Undo assertion.
   // Separate synthetic keystrokes may form several valid Chromium undo groups
   // if an ordinary autosave/state render occurs between their input events.
   await page.keyboard.press('Control+End');await page.keyboard.insertText(suffix);await page.keyboard.press('Control+z');await until(()=>editor.inputValue(),value=>value===original);await until(()=>stored(fixture.primary),value=>value[key]===original);await page.keyboard.press('Control+Shift+z');await until(()=>editor.inputValue(),value=>value===draft);await until(()=>stored(fixture.primary),value=>value[key]===draft);
   await editor.evaluate(node=>node.setSelectionRange(2,6));await packet();assert.deepEqual(await editor.evaluate(node=>{const saved=window.__inspectorAcceptance;return{same:node===saved.field,inspector:node.closest('.inspector')===saved.inspector,library:node.closest('.library')===saved.library,shell:node.closest('.shell')===saved.shell,focused:document.activeElement===node,start:node.selectionStart,end:node.selectionEnd};}),{same:true,inspector:true,library:true,shell:true,focused:true,start:2,end:6});
   await page.keyboard.press('Control+z');await until(()=>editor.inputValue(),value=>value===original);await until(()=>stored(fixture.primary),value=>value[key]===original);await page.keyboard.press('Control+Shift+z');await until(()=>editor.inputValue(),value=>value===draft);await until(()=>stored(fixture.primary),value=>value[key]===draft);
   if(key==='text'){await application.evaluate((_electron,id)=>global.__clipboardLineTest.store.modify('pin',{ids:[id],value:true}),fixture.primary);await packet();assert.match(await page.locator('.inspector-primary-actions [data-action="pin"]').innerText(),/Unpin/);assert.equal(await editor.evaluate(node=>node===window.__inspectorAcceptance.field),true);}
  }
  await packet(fixture.secondary);await until(()=>page.locator('#detail-name').inputValue(),value=>value===fixture.originals[fixture.secondary].name);assert.equal(await page.locator('#detail-text').inputValue(),fixture.originals[fixture.secondary].text);assert.equal(await page.locator('#detail-note').inputValue(),fixture.originals[fixture.secondary].note);const secondary=await stored(fixture.secondary);for(const key of ['name','text','note'])assert.equal(secondary[key],fixture.originals[fixture.secondary][key]);
  await application.evaluate(()=>global.__clipboardLineTest.command('settings'));await page.locator('[data-action="settings-tab"][data-tab="shortcuts"]').click();await page.locator('#shortcut-filter').fill('');await page.evaluate(setViewportPosition,{selector:'.settings-main',top:250});const settingsBefore=await positions(['.settings-main']);assert.ok(settingsBefore['.settings-main'].top>0);await packet();assert.deepEqual(await positions(['.settings-main']),settingsBefore);await page.locator('[data-action="settings-tab"][data-tab="general"]').click();assert.equal((await positions(['.settings-main']))['.settings-main'].top,0);
  check('ordinary native state packets preserve overflowing Library, sidebar, inspector and settings viewports; query/tab contexts reset and list horizontal scrolling survives');
  check('all three inspector fields retain native undo/redo, caret and connected editing ancestors through autosave and packets; new-record bodies and generated controls stay current');
 }catch(error){
  await page.screenshot({path:path.join(output,'scroll-state-failure.png')}).catch(()=>{});fs.writeFileSync(path.join(output,'scroll-state-failure.json'),JSON.stringify({sourceRevision:process.env.GITHUB_SHA||'',error:String(error),ui:await page.evaluate(()=>({active:document.activeElement?.id,list:document.querySelector('.library-grid')?.classList.contains('list'),detailID:document.querySelector('#detail-name')?.dataset.detailId,scroll:Array.from(document.querySelectorAll('.library-results,.sidebar,.inspector,.settings-main')).map(node=>({className:node.className,top:node.scrollTop,left:node.scrollLeft,clientHeight:node.clientHeight,scrollHeight:node.scrollHeight,clientWidth:node.clientWidth,scrollWidth:node.scrollWidth}))})).catch(()=>null)},null,2)+'\n');throw error;
 }finally{
  await page.evaluate(()=>{window.__viewportPacket?.cleanup?.();document.activeElement?.blur();}).catch(()=>{});
  await application.evaluate(async(_electron,value)=>{const h=global.__clipboardLineTest;h.store.modify('trash',{ids:value.ids});h.store.modify('delete',{ids:value.ids});for(const id of value.folders)h.store.modify('removeFolder',{id});await h.command('setSettings',{patch:value.original});await h.command('hide');},fixture);
 }
};

module.exports.setViewportPosition=setViewportPosition;
