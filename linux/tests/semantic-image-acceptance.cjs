'use strict';
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');

// This acceptance runs the bundled S2 model through the real worker/WASM
// backend. Names and OCR deliberately contain none of the visual query words.
module.exports=async function semanticImages({page,application,check,until,output}){
 const fixtures=await application.evaluate(({nativeImage})=>{
  const h=global.__clipboardLineTest,side=512,images=[];
  for(const shape of ['round','square']){const bitmap=Buffer.alloc(side*side*4,255);for(let y=0;y<side;y++)for(let x=0;x<side;x++){const dx=x-side/2,dy=y-side/2,inside=shape==='round'?dx*dx+dy*dy<150*150:Math.abs(dx)<150&&Math.abs(dy)<150;if(inside){const at=(y*side+x)*4;bitmap[at]=shape==='round'?0:255;bitmap[at+1]=0;bitmap[at+2]=shape==='round'?255:0;}}const item=h.store.insert('image',nativeImage.createFromBitmap(bitmap,{width:side,height:side}).toPNG());item.name='Semantic fixture '+(images.length?'B':'A');h.store.modify('pin',{id:item.id,value:true});item.ocrText='';item.tags=['semantic-acceptance'];images.push({id:item.id,key:item.imageFile.slice(0,64)});}
  h.store.persist();h.getImageSearch().refresh();return images;
 });
 const ids=fixtures.map(value=>value.id),query=async(text,eligible=ids)=>page.evaluate(async({text,eligible})=>{const state=await window.clipboardLine.command('searchImages',{query:text,eligibleIds:eligible});if(state.result?.error)throw new Error(state.result.error);return state.result;},{text,eligible});
 const evidence={engine:'onnxruntime-web/wasm',model:'MobileCLIP-S2',hostPlatform:process.platform,sourceRevision:process.env.GITHUB_SHA||'',queries:[]};
 try{
  await until(()=>page.evaluate(()=>window.clipboardLine.state()),state=>state.imageSearch?.available===true,30000);
  // Electron evaluate receives its module first and our serialized argument
  // second. Return scoped indexing diagnostics instead of swallowing a bad
  // callback into an undefined timeout.
  evidence.indexState=await until(()=>application.evaluate((_electron,keys)=>{const search=global.__clipboardLineTest.getImageSearch();return{ready:keys.every(key=>search.known.has(key)),keys,known:keys.filter(key=>search.known.has(key)),failed:keys.filter(key=>search.failed.has(key)),state:{...search.state}};},fixtures.map(value=>value.key)),value=>value.ready,180000);
  const red=await query('a red circle'),blue=await query('a blue square');
  assert.equal(red.available,true);assert.equal(blue.available,true);assert.ok(red.ids.includes(ids[0]),JSON.stringify(red));assert.ok(!red.ids.includes(ids[1]),JSON.stringify(red));assert.ok(blue.ids.includes(ids[1]),JSON.stringify(blue));assert.ok(!blue.ids.includes(ids[0]),JSON.stringify(blue));
  assert.ok(red.scores.find(value=>value.id===ids[0]).score>red.scores.find(value=>value.id===ids[1]).score);assert.ok(blue.scores.find(value=>value.id===ids[1]).score>blue.scores.find(value=>value.id===ids[0]).score);
  evidence.queries.push({query:'a red circle',...red},{query:'a blue square',...blue});
  check('bundled offline MobileCLIP-S2 WASM model distinguishes generated red-circle and blue-square images without OCR or descriptive metadata');

  const scoped=await query('a red circle',[ids[1]]);assert.ok(scoped.ids.every(id=>id===ids[1]));assert.ok(scoped.scores.every(value=>value.id===ids[1]));
  await page.evaluate(()=>window.clipboardLine.command('library'));await page.locator('[data-action="scope"][data-scope="saved"]').click();await page.keyboard.press('Control+1');await page.locator('#search-input').fill('a red circle');
  await until(()=>page.locator('.library-grid .card').getAttribute('data-item-id'),id=>id===ids[0],30000);assert.equal(await page.locator(`[data-item-id="${ids[1]}"]`).count(),0);
  if(!await page.locator('#search-mode-filter').count())await page.locator('[data-action="toggle-filters"]').click();await page.locator('#search-mode-filter').selectOption('text');await until(()=>page.locator('.library-grid .card').count(),count=>count===0);await page.locator('#search-mode-filter').selectOption('visual');await page.locator(`[data-item-id="${ids[0]}"]`).waitFor({state:'visible'});
  check('Library uses real semantic results, keeps Text-only independent, and ranks only the current eligible image scope');

  await page.evaluate(id=>window.clipboardLine.command('trash',{ids:[id]}),ids[0]);
  const deleted=await query('a red circle');assert.ok(!deleted.ids.includes(ids[0]));assert.ok(!deleted.scores.some(value=>value.id===ids[0]));
  await until(()=>application.evaluate((_electron,key)=>{const fs=process.getBuiltinModule('node:fs'),path=process.getBuiltinModule('node:path'),h=global.__clipboardLineTest;return!fs.existsSync(path.join(h.store.directory,'image-search',key+'.bin'));},fixtures[0].key),Boolean,30000);
  check('deleted images immediately leave visual query results and their unreferenced derived vector cache is removed');
 }finally{
  await page.keyboard.press('Escape').catch(()=>{});await page.evaluate(()=>window.clipboardLine.command('library'));await page.locator('[data-action="clear-filters"]').click().catch(()=>{});
  const live=(await page.evaluate(()=>window.clipboardLine.state())).items.filter(value=>ids.includes(value.id));if(live.length){await page.evaluate(ids=>window.clipboardLine.command('trash',{ids}),live.map(value=>value.id));await page.evaluate(ids=>window.clipboardLine.command('delete',{ids}),live.map(value=>value.id));}
  await page.evaluate(()=>window.clipboardLine.command('show'));fs.writeFileSync(path.join(output,'semantic-image-search.json'),JSON.stringify(evidence,null,2)+'\n');
 }
};
