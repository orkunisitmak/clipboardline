'use strict';
// Real Chromium text editing against the shipped renderer. The native runtime
// acceptance separately uses one IME commit to assert exactly one undo group.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {chromium}=require('playwright'),{rendererPage}=require('./shelf-performance.cjs');

async function exerciseInspector(browser,field,key,mode){
 const page=await rendererPage(browser,{source:fs.readFileSync(path.join(__dirname,'../renderer.js'),'utf8'),perKind:1});page.setDefaultTimeout(5000);
 const modifier=process.platform==='darwin'?'Meta':'Control';
 try{
  const original=await page.evaluate(({field,key})=>{
   const fixture=window.__shelfPerformance,server=fixture.snapshot(),record=server.items.find(value=>value.kind==='text');Object.assign(record,{name:'Native inspector name',text:'Native inspector content',note:'Native inspector note'});server.view='library';fixture.emit(server);
   const previous=window.clipboardLine.command,driver=window.__inspectorUndo={server,events:[],saves:0};
   window.clipboardLine.command=async(action,payload)=>{if(action!=='details')return previous(action,payload);const value=server.items.find(value=>value.id===payload.id);for(const name of ['name','text','note'])if(Object.hasOwn(payload,name))value[name]=payload[name];driver.saves++;fixture.emit(structuredClone(server));return structuredClone(server);};
   driver.recordID=record.id;return record[key];
  },{field,key});
  const id=await page.evaluate(()=>window.__inspectorUndo.recordID);await page.locator('[data-item-id="'+id+'"]').click();const editor=page.locator('#'+field);await editor.click();
  await editor.evaluate(node=>{const d=window.__inspectorUndo;d.field=node;d.ancestors=[node.parentElement,node.closest('.library'),node.closest('.shell')];node.addEventListener('input',event=>d.events.push({type:event.inputType,trusted:event.isTrusted}));});
  await page.keyboard.press(process.platform==='darwin'?'Meta+ArrowRight':'Control+End');
  const suffix='_Edited'+key,draft=original+suffix;
  if(mode==='one native commit')await page.keyboard.insertText(suffix);
  else{await page.keyboard.type(suffix.slice(0,-2));await page.evaluate(()=>window.__shelfPerformance.emit({}));await page.keyboard.type(suffix.slice(-2));}
  assert.equal(await editor.inputValue(),draft);
  async function undoToOriginal(){let count=0,value=await editor.inputValue();while(value!==original&&count<suffix.length){await page.keyboard.press(modifier+'+z');const next=await editor.inputValue();assert.notEqual(next,value,'A retained native undo group must change the field');value=next;count++;}assert.equal(value,original);assert.ok(count>0);return count;}
  async function redoGroups(count){for(let at=0;at<count;at++)await page.keyboard.press(modifier+'+Shift+z');assert.equal(await editor.inputValue(),draft);}
  const groups=await undoToOriginal();if(mode==='one native commit')assert.equal(groups,1);await redoGroups(groups);
  await page.waitForFunction(({key,draft})=>{const d=window.__inspectorUndo;return d.server.items.find(value=>value.id===d.recordID)[key]===draft;},{key,draft});
  await editor.evaluate(node=>node.setSelectionRange(2,6));await page.evaluate(()=>window.__shelfPerformance.emit({}));
  const retained=await editor.evaluate(node=>{const d=window.__inspectorUndo;return{same:node===d.field,ancestors:d.ancestors.every(value=>value.isConnected),focused:document.activeElement===node,start:node.selectionStart,end:node.selectionEnd};});assert.deepEqual(retained,{same:true,ancestors:true,focused:true,start:2,end:6});
  const afterPacketGroups=await undoToOriginal();await page.waitForFunction(({key,original})=>{const d=window.__inspectorUndo;return d.server.items.find(value=>value.id===d.recordID)[key]===original;},{key,original});await redoGroups(afterPacketGroups);
  await page.waitForFunction(({key,draft})=>{const d=window.__inspectorUndo;return d.server.items.find(value=>value.id===d.recordID)[key]===draft;},{key,draft});
  const events=await page.evaluate(()=>window.__inspectorUndo.events);assert.ok(events.some(value=>value.type==='historyUndo'));assert.ok(events.some(value=>value.type==='historyRedo'));assert.ok(events.every(value=>value.trusted));
  return{field,mode,groups,afterPacketGroups,retained,exactUndoRedo:true,persistedUndoRedo:true,trustedNativeEvents:true};
 }finally{await page.close();}
}
async function main(){
 const args=process.argv.slice(2),option=name=>args[args.indexOf(name)+1],browser=await chromium.launch({headless:true,...(args.includes('--browser')?{executablePath:option('--browser')}:{})});
 try{const report={scope:'Synthetic real Chromium editing; not native Windows acceptance',host:process.platform,browser:browser.version(),cases:[]};for(const [field,key]of [['detail-name','name'],['detail-text','text'],['detail-note','note']])for(const mode of ['one native commit','segmented real typing'])report.cases.push(await exerciseInspector(browser,field,key,mode));if(args.includes('--output'))fs.writeFileSync(option('--output'),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report));}
 finally{await browser.close();}
}
module.exports={exerciseInspector};
if(require.main===module)main().catch(error=>{console.error(error);process.exitCode=1;});
