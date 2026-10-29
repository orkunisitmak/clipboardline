'use strict';
const assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path');
const {preparePreGestureLocator}=require('./pre-gesture-locator.cjs');

async function dragAcrossStatePacket({page,application,until,folderId,sourceId,expectedIds}){
 const resolveSource=()=>page.locator(`.library-grid [data-item-id="${sourceId}"]`),resolveTarget=()=>page.locator(`[data-action="folder-scope"][data-folder="${folderId}"]`),target=resolveTarget();
 await preparePreGestureLocator(resolveSource,'scrollIntoViewIfNeeded');await preparePreGestureLocator(resolveTarget,'scrollIntoViewIfNeeded');
 await page.evaluate(({sourceId,folderId})=>{
  window.__folderDragProbe?.unsubscribe?.();
  window.__folderDragProbe={active:true,sourceId,folderId,setupSource:document.querySelector(`.library-grid [data-item-id="${sourceId}"]`),setupTarget:document.querySelector(`[data-action="folder-scope"][data-folder="${folderId}"]`),source:null,target:null,started:false,startCount:0,beforeStartPacket:false,packet:false,events:[]};
  if(window.__folderDragListeners)return;window.__folderDragListeners=true;
  document.addEventListener('pointermove',event=>{const probe=window.__folderDragProbe;if(probe?.active)probe.pointer={x:event.clientX,y:event.clientY};});
  for(const type of ['dragstart','dragover','drop','dragend'])document.addEventListener(type,event=>{
   const probe=window.__folderDragProbe;if(!probe?.active)return;
   const source=event.target.closest('[data-item-id]'),folder=event.target.closest('[data-action="folder-scope"]');
   if(type==='dragstart'&&source?.dataset.itemId===probe.sourceId){probe.startCount++;if(!probe.started){probe.source=source;probe.target=document.querySelector(`[data-action="folder-scope"][data-folder="${probe.folderId}"]`);probe.started=true;try{probe.ids=JSON.parse(event.dataTransfer.getData('application/x-clipboardline-ids'));}catch{probe.ids=null;}}}
   if(probe.events.length<40)probe.events.push({type,sourceId:source?.dataset.itemId,folderId:folder?.dataset.folder,alt:event.altKey,types:event.dataTransfer?Array.from(event.dataTransfer.types):[],prevented:event.defaultPrevented});
  });
 },{sourceId,folderId});
 async function statePacket(flag){
  const token=`${sourceId}:${folderId}:${flag}`;
  await page.evaluate(({flag,token})=>{const probe=window.__folderDragProbe;probe.unsubscribe?.();const unsubscribe=window.clipboardLine.subscribe(state=>{if(state.__folderDragAcceptancePacket!==token)return;probe[flag]=true;unsubscribe();});probe.unsubscribe=unsubscribe;},{flag,token});
  await application.evaluate((_electron,token)=>{const h=global.__clipboardLineTest;h.getWindow().webContents.send('clipboardline:changed',{...h.state(),__folderDragAcceptancePacket:token});},token);
  await until(()=>page.evaluate(flag=>window.__folderDragProbe[flag],flag),Boolean);
 }
 // A refresh before dragstart can legitimately replace nodes. Anchor the probe
 // to the actual gesture, then require those exact nodes to survive its packet.
 await statePacket('beforeStartPacket');
 assert.deepEqual(await page.evaluate(()=>{const probe=window.__folderDragProbe;return{started:probe.started,sourceDetached:!probe.setupSource?.isConnected,targetDetached:!probe.setupTarget?.isConnected};}),{started:false,sourceDetached:true,targetDetached:true});
 // This is a real pointer drag, paused after dragstart and before the target.
 // The packet travels through the production main→preload state subscription.
 await preparePreGestureLocator(resolveSource,'hover');const point=await page.evaluate(()=>window.__folderDragProbe.pointer);assert.ok(point&&Number.isFinite(point.x)&&Number.isFinite(point.y));
 await page.mouse.down();await page.mouse.move(point.x+12,point.y+8,{steps:3});await page.mouse.move(point.x+20,point.y+8);
 await until(()=>page.evaluate(()=>window.__folderDragProbe.started),Boolean);
 assert.deepEqual(await page.evaluate(()=>window.__folderDragProbe.ids),expectedIds);
 assert.equal(await page.evaluate(()=>window.__folderDragProbe.startCount),1);
 await statePacket('packet');
 const identity=await page.evaluate(()=>{const probe=window.__folderDragProbe;return{source:probe.source===document.querySelector(`.library-grid [data-item-id="${probe.sourceId}"]`),target:probe.target===document.querySelector(`[data-action="folder-scope"][data-folder="${probe.folderId}"]`),sourceConnected:probe.source?.isConnected,targetConnected:probe.target?.isConnected,startCount:probe.startCount};});
 assert.deepEqual(identity,{source:true,target:true,sourceConnected:true,targetConnected:true,startCount:1});
 const box=await target.boundingBox();assert.ok(box);await page.mouse.move(box.x+box.width/2,box.y+box.height/2,{steps:12});await page.mouse.up();
 await until(()=>page.evaluate(()=>window.__folderDragProbe.events.some(event=>event.type==='drop'&&event.prevented)),Boolean);
 await page.evaluate(()=>{window.__folderDragProbe.active=false;});return identity;
}

module.exports=async({page,application,check,until,output})=>{
 const fixture=await application.evaluate(async({nativeImage})=>{
  const h=global.__clipboardLineTest,crypto=process.getBuiltinModule('node:crypto'),prefix='Folder drag '+crypto.randomUUID(),bitmap=crypto.randomBytes(16);for(let at=3;at<bitmap.length;at+=4)bitmap[at]=255;
  const image=h.store.insert('image',nativeImage.createFromBitmap(bitmap,{width:2,height:2}).toPNG()),text=h.store.insert('text',prefix+' text value'),b=h.store.modify('createFolder',{name:prefix+' Z'}),child=h.store.modify('createFolder',{name:prefix+' Child',parentId:b.id}),a=h.store.modify('createFolder',{name:prefix+' A'});
  for(const [item,suffix]of [[image,' image'],[text,' text']]){h.store.modify('details',{id:item.id,name:prefix+suffix});h.store.modify('retain',{ids:[item.id]});}
  h.store.modify('folder',{ids:[image.id],folderId:a.id,pinning:false});
  const originalSidebar=h.store.data.settings.librarySidebarVisible;
  await h.command('setSettings',{patch:{librarySidebarVisible:true}});await h.command('library');
  return{prefix,image:image.id,text:text.id,a:a.id,b:b.id,child:child.id,originalSidebar};
 });
 try{
  await page.locator('[data-action="scope"][data-scope="saved"]').click();
  const clear=page.locator('[data-action="clear-filters"]').first();if(await clear.count()&&await clear.isVisible())await clear.click();
  await page.locator('[data-action="allTypes"]').click();await page.locator('#search-input').fill(fixture.prefix);
  assert.deepEqual(await page.locator('[data-action="folder-scope"]').evaluateAll((buttons,expected)=>buttons.map(button=>button.dataset.folder).filter(id=>expected.includes(id)),[fixture.a,fixture.b,fixture.child]),[fixture.a,fixture.b,fixture.child]);
  const image=page.locator(`.library-grid [data-item-id="${fixture.image}"]`),text=page.locator(`.library-grid [data-item-id="${fixture.text}"]`);
  await image.waitFor({state:'visible'});await text.waitFor({state:'visible'});
  await dragAcrossStatePacket({page,application,until,sourceId:fixture.image,folderId:fixture.b,expectedIds:[fixture.image]});
  const read=()=>application.evaluate((_electron,{image,text})=>{const h=global.__clipboardLineTest;return{image:h.store.item(image),text:h.store.item(text)};},fixture);
  let state=await until(read,value=>value.image.folderIds.includes(fixture.b));assert.deepEqual(state.image.folderIds,[fixture.a,fixture.b]);assert.equal(state.image.pinned,false);assert.deepEqual(state.text.folderIds,[]);
  await image.click();await text.click({modifiers:['Control']});await until(()=>page.locator('.library-grid .card.selected').count(),value=>value===2);
  const expectedIds=await page.locator('.library-grid .card.selected').evaluateAll(cards=>cards.map(card=>card.dataset.itemId));assert.equal(expectedIds.length,2);assert.ok(expectedIds.includes(fixture.image)&&expectedIds.includes(fixture.text));await dragAcrossStatePacket({page,application,until,sourceId:fixture.text,folderId:fixture.a,expectedIds});
  state=await until(read,value=>value.text.folderIds.includes(fixture.a));assert.deepEqual(state.image.folderIds,[fixture.a,fixture.b]);assert.deepEqual(state.text.folderIds,[fixture.a]);assert.equal(state.image.pinned,false);assert.equal(state.text.pinned,false);
  check('actual Library image and ordered mixed-selection pointer drags begin after pre-start refreshes and survive main-process state packets and add folders without moving or pinning');
 }catch(error){
  const ui=await page.evaluate(()=>{const probe=window.__folderDragProbe;return{started:probe?.started,startCount:probe?.startCount,beforeStartPacket:probe?.beforeStartPacket,packet:probe?.packet,setupSourceConnected:probe?.setupSource?.isConnected,setupTargetConnected:probe?.setupTarget?.isConnected,ids:probe?.ids,events:probe?.events,sourceConnected:probe?.source?.isConnected,targetConnected:probe?.target?.isConnected,selected:Array.from(document.querySelectorAll('.library-grid .card.selected')).map(card=>card.dataset.itemId),documentFocused:document.hasFocus(),active:document.activeElement?.id};}).catch(()=>null);
  const native=await application.evaluate((_electron,{image,text})=>{const h=global.__clipboardLineTest,w=h.getWindow();return{visible:w.isVisible(),focused:w.isFocused(),view:h.state().view,items:[image,text].map(id=>{const record=h.store.item(id);return{id,folderIds:record.folderIds,pinned:record.pinned,trashedAt:record.trashedAt};})};},fixture).catch(()=>null);
  fs.writeFileSync(path.join(output,'library-folder-drag-failure.json'),JSON.stringify({sourceRevision:process.env.GITHUB_SHA||'',error:String(error),ui,native},null,2)+'\n');throw error;
 }finally{
  await page.mouse.up().catch(()=>{});await page.evaluate(()=>{window.__folderDragProbe?.unsubscribe?.();if(window.__folderDragProbe)window.__folderDragProbe.active=false;}).catch(()=>{});
  if(await page.locator('#search-input').count())await page.locator('#search-input').fill('').catch(()=>{});
  await application.evaluate(async(_electron,value)=>{const h=global.__clipboardLineTest;for(const id of [value.image,value.text]){h.store.modify('trash',{ids:[id]});h.store.modify('delete',{ids:[id]});}for(const id of [value.a,value.b])h.store.modify('removeFolder',{id});await h.command('setSettings',{patch:{librarySidebarVisible:value.originalSidebar}});await h.command('hide');},fixture);
 }
};
