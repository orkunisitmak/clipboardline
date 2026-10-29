'use strict';
// Isolated real browser canvas/DOM work, not native Windows acceptance or FPS.
const fs=require('node:fs'),path=require('node:path'),{chromium}=require('playwright');
const {rendererPage}=require('./shelf-performance.cjs'),{exerciseEditor}=require('./image-editor-compositor-acceptance.cjs');
async function main(){const args=process.argv.slice(2),option=name=>args[args.indexOf(name)+1],browser=await chromium.launch({headless:true,...(args.includes('--browser')?{executablePath:option('--browser')}:{})}),report={scope:'Synthetic 4K/8K shipped renderer and real Chromium canvas; not native Windows FPS',browser:browser.version(),runs:[]};
 try{for(const file of [args.includes('--baseline')?option('--baseline'):null,path.join(__dirname,'../renderer.js')].filter(Boolean))for(const [width,height]of[[3840,2160],[7680,4320]]){
  const source=fs.readFileSync(file,'utf8'),page=await rendererPage(browser,{source,perKind:1});
  try{
   const id=await page.evaluate(({width,height})=>{const f=window.__shelfPerformance,state=f.snapshot(),image=state.items.find(value=>value.kind==='image'),canvas=document.createElement('canvas');canvas.width=width;canvas.height=height;const c=canvas.getContext('2d');c.fillStyle='#e2b46d';c.fillRect(0,0,width,height);c.fillStyle='#327fa1';c.fillRect(width*.4,height*.4,width*.2,height*.2);const png=canvas.toDataURL('image/png');Object.assign(image,{mediaUrl:png,originalMediaUrl:png,annotations:[],crop:null});f.emit({items:state.items});const command=window.clipboardLine.command;window.clipboardLine.command=async(action,payload)=>{if(action==='saveImage'){const current=f.snapshot();Object.assign(current.items.find(value=>value.id===payload.id),{annotations:payload.annotations,crop:payload.crop,mediaUrl:payload.dataUrl});f.emit({items:current.items});}return command(action,payload);};return image.id;},{width,height});
   const until=async(reader,predicate)=>{const deadline=Date.now()+10000;while(Date.now()<deadline){const value=await reader();if(predicate(value))return value;await new Promise(resolve=>setTimeout(resolve,10));}throw new Error('Image editor state timed out');};
   const result=await exerciseEditor({page,id,width,height,until,expectRetained:!args.includes('--baseline')||file!==option('--baseline')});report.runs.push({source:path.resolve(file),...result});
  }finally{await page.close();}
 }
 if(args.includes('--output'))fs.writeFileSync(option('--output'),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report));
 }finally{await browser.close();}}
if(require.main===module)main().catch(error=>{console.error(error);process.exitCode=1;});
