'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),crypto=require('node:crypto'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const {statusSummary,translated,languageCode,badgeBitmap,StatusTray}=require('../lib/status-summary.cjs');
const sha=value=>crypto.createHash('sha256').update(value).digest('hex');
test('tray totals only visible live image/text/link shelves, independently from pin/search/capture choices',()=>{
 const items=[{kind:'image',recording:true},{kind:'image',pinned:true},{kind:'text',hiddenFromShelf:true},{kind:'text',trashedAt:123},{kind:'text'},{kind:'link'},{kind:'unknown'}];
 const summary=statusSummary({items,settings:{visibleKinds:['image','text','link'],captureImages:false}});assert.deepEqual([summary.images,summary.texts,summary.links,summary.count,summary.badge,summary.dim],[2,1,1,4,'4',false]);
 const only=statusSummary({items,settings:{visibleKinds:['text','link']}});assert.deepEqual([only.images,only.texts,only.links,only.count],[0,1,1,2]);
 assert.equal(statusSummary({items,settings:{visibleKinds:[]}}).count,4,'Empty legacy visibility follows the renderer’s all-shelves fallback');
});
test('tray caps digits at9+ and empty stays dim unless an update must remain visible',()=>{
 for(const count of[0,1,9,10,20000]){const summary=statusSummary({items:Array.from({length:count},()=>({kind:'text'}))});assert.equal(summary.badge,count>9?'9+':String(count));assert.equal(summary.dim,count===0);}
 const empty=statusSummary({settings:{language:'tr'},updateVersion:'1.7.3'});assert.equal(empty.dim,false);assert.equal(empty.highlight,true);assert.equal(empty.badge,'0');assert.match(empty.tooltip,/Askılar boş/);assert.match(empty.tooltip,/Güncelleme var/);assert.match(empty.tooltip,/1\.7\.3/);assert.ok(statusSummary({items:Array(20000).fill({kind:'text'}),updateVersion:'9'.repeat(100)}).tooltip.length<=127);
});
test('Node and browser share exactly nine unchanged locale catalogs and system-language resolution',()=>{
 const catalogs=require('../locales.js'),context={window:{}};vm.runInNewContext(fs.readFileSync(path.join(__dirname,'../locales.js'),'utf8'),context);assert.equal(Object.keys(catalogs).length,9);assert.deepEqual(JSON.parse(JSON.stringify(context.window.clipboardLineTranslations)),catalogs);
 assert.equal(languageCode('system','tr-TR'),'tr');assert.equal(languageCode('system','pt-PT'),'pt-BR');assert.equal(languageCode('system','zh-TW'),'zh-Hans');assert.equal(languageCode('system','de-DE'),'en');assert.equal(languageCode('en','tr-TR'),'en');
 assert.equal(statusSummary({items:[{kind:'image'},{kind:'text'},{kind:'link'}],settings:{language:'tr'}}).description,'Askılarda 1 görsel · 1 metin · 1 link');assert.equal(translated('tr','Quit %@','ClipBoardLine'),'ClipBoardLine uygulamasından çık');assert.equal(translated('en','Library'),'Library');
});
test('actual bitmap badges0 through9+ have distinct glyphs, retain shared art outside the badge and dim empty alpha',()=>{
 const size=32,source=Buffer.alloc(size*size*4);for(let at=0;at<source.length;at+=4){source[at]=70;source[at+1]=40;source[at+2]=20;source[at+3]=255;}
 const variants=[];for(const badge of['0','1','2','3','4','5','6','7','8','9','9+']){const bitmap=badgeBitmap(source,size,{badge});variants.push(sha(bitmap));assert.ok(bitmap.subarray(0,16*4).equals(source.subarray(0,16*4)));assert.notEqual(sha(bitmap),sha(source));}
 assert.equal(new Set(variants).size,11);const normal=badgeBitmap(source,size,{badge:'0'}),dim=badgeBitmap(source,size,{badge:'0',dim:true}),update=badgeBitmap(source,size,{badge:'0',highlight:true});assert.ok(dim[3]<normal[3]);assert.notEqual(sha(normal),sha(update));assert.ok(source.every((value,index)=>value===[70,40,20,255][index%4]),'Shared source artwork is never mutated');assert.throws(()=>badgeBitmap(source,size,{badge:'unsafe'}));
});
test('controller skips indexing/caret packets and bounds icon/menu rebuilding to actual status changes',()=>{
 const calls={image:0,tooltip:0,menu:0,create:0},tray={setImage:()=>calls.image++,setToolTip:()=>calls.tooltip++,setContextMenu:()=>calls.menu++};const controller=new StatusTray({tray,createIcon:summary=>(calls.create++,summary.iconKey),createMenu:summary=>summary.menuKey});
 const items=[{kind:'text',name:'A'}],settings={language:'en',visibleKinds:['text']};assert.equal(controller.refresh({items,settings}),true);assert.deepEqual(calls,{image:1,tooltip:1,menu:1,create:1});
 assert.equal(controller.refresh({items:[{...items[0],name:'Changed detail'}],settings}),false);assert.deepEqual(calls,{image:1,tooltip:1,menu:1,create:1});
 controller.refresh({items:[...items,{kind:'text'}],settings});assert.deepEqual(calls,{image:2,tooltip:2,menu:1,create:2});controller.refresh({items,settings});assert.equal(calls.create,2,'Existing glyph image is reused');controller.refresh({items,settings:{...settings,language:'tr'}});assert.equal(calls.image,3);assert.equal(calls.menu,2);
 controller.refresh({items,settings,updateVersion:'1.7.3'});assert.equal(calls.menu,3);assert.equal(calls.image,4);for(let count=0;count<40;count++)for(const updateVersion of[null,'1.7.3'])controller.refresh({items:Array(count).fill({kind:'text'}),settings,updateVersion});assert.ok(controller.snapshot().cachedIcons<=22);assert.equal(controller.snapshot().count,39);
});

test('shutdown and a destroyed native Tray reject late status packets without native calls',()=>{
 for(const stop of['dispose','destroy']){let destroyed=false,calls=0;const tray={isDestroyed:()=>destroyed,setImage:()=>{if(destroyed)throw new Error('Native Tray already destroyed');calls++;},setToolTip:()=>calls++,setContextMenu:()=>calls++},controller=new StatusTray({tray,createIcon:()=>Buffer.from('owned native image'),createMenu:()=>({})});controller.refresh({});assert.equal(calls,3);if(stop==='dispose')controller.dispose();else destroyed=true;assert.equal(controller.refresh({items:[{kind:'text'}],settings:{language:'tr'},updateVersion:'99.0.0'}),false);assert.equal(calls,3);assert.equal(controller.snapshot().count,0);}
});
