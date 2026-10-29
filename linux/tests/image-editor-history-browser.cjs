'use strict';
// Actual renderer, Chromium keyboard dispatch and real PNG decode. Synthetic
// image URLs and IPC control the relative reply/broadcast delivery; the native
// acceptance suite separately exercises Electron's managed-media protocol.
const assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path');
const {chromium}=require('playwright');
const {rendererPage}=require('./shelf-performance.cjs');

async function exerciseHistory(browser,ordering,source=fs.readFileSync(path.join(__dirname,'../renderer.js'),'utf8')){
 const page=await rendererPage(browser,{source,perKind:1});page.setDefaultTimeout(5000);
 try{
  const id=await page.evaluate(ordering=>{
   const fixture=window.__shelfPerformance,server=fixture.snapshot(),image=server.items.find(value=>value.kind==='image'),canvas=document.createElement('canvas');canvas.width=240;canvas.height=150;const c=canvas.getContext('2d');c.fillStyle='#e2b46d';c.fillRect(0,0,240,150);c.fillStyle='#327fa1';c.fillRect(50,30,100,60);const png=canvas.toDataURL('image/png');Object.assign(image,{annotations:[],crop:null,mediaUrl:png,originalMediaUrl:png});server.view='library';fixture.emit(server);
   const original=window.clipboardLine.command,driver=window.__imageHistoryDriver={server,saves:[],keys:[],pending:null};
   document.addEventListener('keydown',event=>driver.keys.push({key:event.key,ctrl:event.ctrlKey,target:event.target.tagName,id:event.target.id}),true);
   window.clipboardLine.state=async()=>structuredClone(server);
   window.clipboardLine.command=async(action,payload)=>{
    if(action!=='saveImage')return original(action,payload);
    Object.assign(server.items.find(value=>value.id===payload.id),{mediaUrl:payload.dataUrl,annotations:payload.annotations,crop:payload.crop});driver.saves.push(structuredClone(payload));
    const reply=structuredClone(server);
    if(driver.saves.length===1&&ordering!=='broadcast before reply'){
     driver.pending=reply;if(ordering==='unrelated surface before reply')fixture.surface({windowVisible:true});
    }else fixture.emit(reply);
    return reply;
   };
   driver.release=()=>{const pending=driver.pending;driver.pending=null;if(pending)fixture.emit(pending);};
   return image.id;
  },ordering);
  await page.locator('[data-item-id="'+id+'"]').click();await page.keyboard.press('Space');await page.locator('#preview-media').waitFor();
  await page.keyboard.press('c');await page.waitForFunction(()=>document.getElementById('markup-canvas')?.dataset.overlayReady==='true');
  const box=await page.locator('#markup-canvas').boundingBox();
  await page.mouse.move(box.x+box.width*.2,box.y+box.height*.2);await page.mouse.down();await page.mouse.move(box.x+box.width*.8,box.y+box.height*.8,{steps:6});await page.mouse.up();await page.keyboard.press('Enter');await page.locator('#markup-canvas').waitFor({state:'hidden'});
  await page.evaluate(()=>window.__imageHistoryDriver.release());
  await page.waitForFunction(()=>document.getElementById('preview-media')?.complete&&document.getElementById('preview-media').naturalWidth===144);
  const crop=await page.evaluate(()=>window.__imageHistoryDriver.server.items.find(value=>value.kind==='image').crop);assert.deepEqual(crop,{x:48,y:30,width:144,height:90});
  await page.keyboard.press('Control+z');await page.waitForFunction(()=>window.__imageHistoryDriver.saves.length===2);await page.locator('#markup-canvas').waitFor({state:'hidden'});
  assert.equal(await page.evaluate(()=>window.__imageHistoryDriver.server.items.find(value=>value.kind==='image').crop),null);
  await page.keyboard.press('Control+Shift+z');await page.waitForFunction(()=>window.__imageHistoryDriver.saves.length===3);await page.locator('#markup-canvas').waitFor({state:'hidden'});
  assert.deepEqual(await page.evaluate(()=>window.__imageHistoryDriver.server.items.find(value=>value.kind==='image').crop),crop);
  // A later same-ID image edit must still invalidate local undo.
  const external={x:20,y:10,width:60,height:70};
  await page.evaluate(external=>{const d=window.__imageHistoryDriver,value=d.server.items.find(value=>value.kind==='image');Object.assign(value,{crop:external,annotations:[{type:'rectangle',x:1,y:2,width:3,height:4}]});window.__shelfPerformance.emit(structuredClone(d.server));},external);
  await page.keyboard.press('Control+z');await page.locator('#markup-canvas').waitFor({state:'hidden'});
  const after=await page.evaluate(()=>{const d=window.__imageHistoryDriver;return{crop:d.server.items.find(value=>value.kind==='image').crop,saves:d.saves.length,keys:d.keys.filter(value=>value.key==='z'),activeElement:{tag:document.activeElement.tagName,id:document.activeElement.id}};});
  assert.equal(after.saves,3,'External edits must not be overwritten by the older local undo stack');assert.deepEqual(after.crop,external);assert.equal(after.keys.length,3);assert.ok(after.keys.every(value=>value.ctrl&&value.target==='BODY'));
  return{ordering,savedCrop:crop,undo:true,redo:true,externalEditProtected:true,...after};
 }finally{await page.close();}
}

async function main(){
 const args=process.argv.slice(2),option=name=>args[args.indexOf(name)+1],browser=await chromium.launch({headless:true,...(args.includes('--browser')?{executablePath:option('--browser')}:{})});
 try{const report={scope:'Synthetic real Chromium renderer; native Windows acceptance remains required',browser:browser.version(),cases:[]},source=args.includes('--source')?fs.readFileSync(option('--source'),'utf8'):undefined;for(const ordering of ['broadcast before reply','reply before broadcast','unrelated surface before reply']){try{report.cases.push(await exerciseHistory(browser,ordering,source));}catch(error){report.cases.push({ordering,error:error.message});if(args.includes('--output'))fs.writeFileSync(option('--output'),JSON.stringify(report,null,2)+'\n');throw error;}}if(args.includes('--output'))fs.writeFileSync(option('--output'),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report));}
 finally{await browser.close();}
}
module.exports={exerciseHistory};
if(require.main===module)main().catch(error=>{console.error(error);process.exitCode=1;});
