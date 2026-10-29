'use strict';
// Development-only compositor check. Native window/focus/hide acceptance still
// runs separately on Windows in source, packaged and installed application modes.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {chromium}=require('playwright'),{rendererPage}=require('./shelf-performance.cjs');
async function main(){
 const args=process.argv.slice(2),browserIndex=args.indexOf('--browser'),browser=await chromium.launch({headless:true,...(browserIndex<0?{}:{executablePath:args[browserIndex+1]})});
 try{
  const page=await rendererPage(browser,{source:fs.readFileSync(path.join(__dirname,'../renderer.js'),'utf8'),perKind:20});await page.emulateMedia({reducedMotion:'no-preference'});
  const result=await page.evaluate(async()=>{
   const body=document.body,controller=new window.clipboardLineShelfMotion.ShelfMotion({body,computed:node=>getComputedStyle(node),height:()=>innerHeight,motion:matchMedia('(prefers-reduced-motion: reduce)')}),nodes=Array.from(document.querySelectorAll('.shelf,.card,img')),opening=[],closing=[];
   const sample=async(operation,values)=>{let done=false;const promise=operation.then(value=>{done=true;return value;});while(!done){await new Promise(requestAnimationFrame);const transform=getComputedStyle(body).transform;values.push({y:transform==='none'?0:new DOMMatrixReadOnly(transform).m42,pointer:getComputedStyle(document.querySelector('.card')).pointerEvents,phase:body.dataset.shelfMotion||'shown'});}return promise;};
   await controller.run({phase:'prepare',hidden:true});await sample(controller.run({phase:'open'}),opening);await sample(controller.run({phase:'close'}),closing);
   await controller.run({phase:'prepare',hidden:true});const oldOpen=controller.run({phase:'open'});await new Promise(resolve=>setTimeout(resolve,60));const reverse=controller.run({phase:'close'});const old=await oldOpen;await reverse;const hidden=body.dataset.shelfMotion==='hidden';await controller.run({phase:'prepare',hidden:false});await controller.run({phase:'open'});
   window.__rendererMotion=controller;
   return{opening,closing,oldOpenCanceled:old.completed===false,reverseHidden:hidden,allNodesConnected:nodes.every(node=>node.isConnected),pointerRestored:getComputedStyle(document.querySelector('.card')).pointerEvents!=='none'};
  });
  assert.ok(result.opening.length>2);assert.ok(result.opening.some(value=>value.y< -100));assert.ok(result.opening.at(-1).y>result.opening[0].y+100);assert.ok(result.closing.length>2);assert.ok(result.closing.at(-1).y<result.closing[0].y-100);assert.ok(result.opening.filter(value=>value.phase==='opening').every(value=>value.pointer==='none'));assert.equal(result.oldOpenCanceled,true);assert.equal(result.reverseHidden,true);assert.equal(result.allNodesConnected,true);assert.equal(result.pointerRestored,true);
  await page.emulateMedia({reducedMotion:'reduce'});const reduced=await page.evaluate(async()=>{let count=0;const body=document.body,original=body.animate;body.animate=function(...args){count++;return original.apply(this,args);};try{await window.__rendererMotion.run({phase:'close'});await window.__rendererMotion.run({phase:'prepare',hidden:true});await window.__rendererMotion.run({phase:'open'});return{count,pointerRestored:!body.dataset.shelfMotion};}finally{body.animate=original;}});assert.deepEqual(reduced,{count:0,pointerRestored:true});
  const report={scope:'Headless browser compositor on macOS; not native Windows acceptance',browser:browser.version(),...result,reduced},at=args.indexOf('--output');if(at>=0)fs.writeFileSync(args[at+1],JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report));
 }finally{await browser.close();}
}
if(require.main===module)main().catch(error=>{console.error(error);process.exitCode=1;});
