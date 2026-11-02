'use strict';
// Exercises the shipped Library and preview renderer against an isolated IPC/DOM
// fixture. Native geometry and app integration are checked separately on Windows.
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const crypto=require('node:crypto');
const {execFileSync}=require('node:child_process');

function fixture({deferInitialState=false,initialVisible=true}={}){
 const listeners=new Map(),nodes=new Map(),commands=[],imageLoads=[];let exportFailures=0;
 class Element{
  constructor(id=''){this.id=id;this.innerHTML='';this.textContent='';this.dataset={};this.style={};this.className='';this.value='';this.selectionStart=0;this.selectionEnd=0;this.classList={add(){},remove(){},contains(){return false;}};}
  set innerHTML(value){this.htmlWrites=(this.htmlWrites||0)+1;this._innerHTML=value;if(this.id==='overlay-root'){
   const video=value.match(/id="preview-video" data-video-id="([^"]+)" data-source-fingerprint="([^"]*)"/);if(video){const player=new Element('preview-video');player.dataset={videoId:video[1],sourceFingerprint:video[2]};nodes.set('preview-video',player);}
   if(value.includes('class="video-trim-controls"')){const controls=new Element('video-trim-controls'),inputs=[];for(const match of value.matchAll(/<input id="(trim-[^"]+)"[^>]*value="([^"]*)"[^>]*>/g)){const input=new Element(match[1]);input.value=match[2];nodes.set(match[1],input);inputs.push(input);}controls.querySelectorAll=selector=>selector==='input'?inputs:[];nodes.set('video-trim-controls',controls);}else nodes.delete('video-trim-controls');
  }}get innerHTML(){return this._innerHTML;}
  setAttribute(){}querySelector(){return null;}querySelectorAll(){return [];}focus(){}blur(){}select(){}setSelectionRange(){}scrollIntoView(){}matches(){return false;}closest(){return null;}
 }
 class TextArea extends Element{}
 class Canvas extends Element{
  constructor(id=''){super(id);this.width=900;this.height=220;}
  getBoundingClientRect(){return{left:0,top:0,width:900,height:220};}
  getContext(){return new Proxy({}, {get(object,key){return object[key]??(()=>{});},set(object,key,value){object[key]=value;return true;}});}
  toDataURL(){if(exportFailures){exportFailures--;throw Object.assign(new Error('Synthetic canvas export rejection'),{name:'SecurityError'});}return 'data:image/png;base64,iVBORw0KGgo=';}
 }
 class FixtureImage extends Element{
  constructor(){super();this.naturalWidth=900;this.naturalHeight=220;this.complete=true;}
  set src(value){imageLoads.push({url:value,crossOrigin:this.crossOrigin});if(this.onload)queueMicrotask(()=>this.onload());}
 }
 const document={body:new Element('body'),activeElement:null,getElementById(id){if(!nodes.has(id))nodes.set(id,id==='markup-canvas'?new Canvas(id):new Element(id));return nodes.get(id);},createElement(tag){return tag==='canvas'?new Canvas():new Element();},querySelector(selector){return selector==='.video-trim-controls'?nodes.get('video-trim-controls')||null:null;},querySelectorAll(){return [];},addEventListener(name,listener){if(!listeners.has(name))listeners.set(name,[]);listeners.get(name).push(listener);}};
 const image='00000000-0000-4000-8000-000000000001',text1='00000000-0000-4000-8000-000000000002',text2='00000000-0000-4000-8000-000000000003',link='00000000-0000-4000-8000-000000000004';
 const base=(id,kind,createdAt,extra)=>({id,kind,createdAt,updatedAt:createdAt,name:'',title:'',text:'',url:'',pinned:false,folderIds:[],tags:[],trashedAt:null,hiddenFromShelf:false,crop:null,annotations:[],...extra});
 const state={items:[base(image,'image',1000,{name:'Synthetic image',mediaUrl:'appmedia://media/'+image,originalMediaUrl:'appmedia://media/'+image+'/original'}),base(text1,'text',900,{text:'Text one'}),base(text2,'text',800,{text:'Text two'}),base(link,'link',700,{url:'https://example.com/reference',title:'Reference link'})],folders:[],settings:{visibleKinds:['image','text','link'],retentionDays:{image:30,text:30,link:30},shortcuts:{toggle:'Control+Alt+Space',search:'Control+Alt+S'},localShortcuts:{},language:'en',theme:'soft',cardSize:'medium'},view:'shelves',version:'1.7.0',windowVisible:initialVisible,canUndo:false};
 let subscriber,removed=[],cleanupFailures=0,editFailures=0,delayedReply=null,releaseInitialState,visualSearch=()=>({ids:[],scores:[],available:false,indexing:false}),detailsFailures=0,folderFailures=0;
 const clone=value=>structuredClone(value);
 const api={emit(patch){Object.assign(state,patch);subscriber?.(clone(state));},state:async()=>{const initial=clone(state);if(deferInitialState)await new Promise(resolve=>{releaseInitialState=resolve;});return initial;},subscribe(fn){subscriber=fn;return()=>{};},async command(action,payload={}){commands.push({action,payload:clone(payload)});const selected=state.items.filter(item=>(payload.ids||[payload.id]).includes(item.id));
  let cleanupError,newNote;if(action==='cleanup'){if(cleanupFailures){cleanupFailures--;cleanupError='Permanent deletion cleanup is still pending.';}else state.needsDeletionCleanup=false;}
  if(action==='newNote'){newNote=base('00000000-0000-4000-8000-000000000006','text',Date.now(),{text:payload.text,retainedAt:Date.now()});state.items.unshift(newNote);}
  if(action==='editText'){if(editFailures){editFailures--;cleanupError='Synthetic draft write failure';}else selected.forEach(item=>item.text=payload.text);}
  if(action==='setSettings'){const patch=payload.patch||{},localShortcuts={...state.settings.localShortcuts,...patch.localShortcuts};for(const [action,value]of Object.entries(localShortcuts))if(value===null)delete localShortcuts[action];state.settings={...state.settings,...patch,localShortcuts};}
  if(action==='saveImage')selected.forEach(item=>{item.crop=clone(payload.crop);item.annotations=clone(payload.annotations);});
  if(action==='details'){if(detailsFailures){detailsFailures--;cleanupError='Synthetic atomic inspector write failure';}else selected.forEach(item=>{for(const key of ['name','text','note'])if(Object.hasOwn(payload,key))item[key]=payload[key];});}
  if(action==='note')selected.forEach(item=>item.note=payload.note);
  if(action==='retain')selected.forEach(item=>item.retainedAt=Date.now());
  if(action==='folder'){if(folderFailures){folderFailures--;cleanupError='Synthetic folder commit failure';}else{selected.forEach(item=>{item.folderIds=[...new Set([...item.folderIds,payload.folderId])];if(payload.pinning!==false)item.pinned=true;item.retainedAt??=Date.now();});if(payload.rememberRecent)state.settings.recentPinFolderIds=[payload.folderId,...(state.settings.recentPinFolderIds||[]).filter(id=>id!==payload.folderId)].slice(0,8);}}
  if(action==='unassign')selected.forEach(item=>item.folderIds=item.folderIds.filter(id=>id!==payload.folderId));
  if(action==='removeTag')selected.forEach(item=>item.tags=item.tags.filter(tag=>tag!==payload.tag));
  if(action==='renameTag')state.items.forEach(item=>item.tags=item.tags.map(tag=>tag===payload.tag?payload.name:tag));
  if(action==='deleteTag')state.items.forEach(item=>item.tags=item.tags.filter(tag=>tag!==payload.tag));
  if(action==='pin')selected.forEach(item=>item.pinned=typeof payload.value==='boolean'?payload.value:!item.pinned);
   if(action==='restore')selected.forEach(item=>{item.trashedAt=null;item.trashRevision=null;item.retainedAt??=Date.now();});
  if(action==='name')selected.forEach(item=>{item.name=payload.name;item.pinned=true;});
  if(action==='remove'){removed=selected.map(clone);selected.forEach(item=>{if(item.pinned)item.hiddenFromShelf=true;else item.trashedAt=Date.now();});state.canUndo=true;}
  if(action==='undo'){for(const before of removed)Object.assign(state.items.find(item=>item.id===before.id),before);state.canUndo=false;}
  if(action==='copy'&&!payload.keepOpen||action==='paste'||action==='hide')state.windowVisible=false;
  if(action==='show'){state.view='shelves';state.windowVisible=true;state.viewEvent={serial:String(commands.length)};}
  if(action==='library'||action==='settings'){state.view=action;state.windowVisible=true;}
  const output=clone(state);if(newNote)output.result={id:newNote.id};if(action==='searchImages')output.result=await visualSearch(clone(payload));if(cleanupError)output.result={error:cleanupError};subscriber?.(output);
  if(delayedReply?.action===action){const pending=delayedReply;delayedReply=null;await pending.promise;}
  return output;
 }};
 const context={window:{clipboardLine:api,addEventListener(){}},document,HTMLElement:Element,HTMLTextAreaElement:TextArea,Image:FixtureImage,console,structuredClone,URL,Set,Date,JSON,Math,Number,String,requestAnimationFrame:fn=>fn(),setTimeout:fn=>{queueMicrotask(fn);return 1;},clearTimeout(){}};
 vm.createContext(context);vm.runInContext(fs.readFileSync(path.join(__dirname,'../renderer.js'),'utf8'),context,{filename:'renderer.js'});
 async function ready(){await new Promise(setImmediate);}
 async function key(code,{ctrl=false,alt=false,shift=false,repeat=false,key,target}={}){const event={code,key:key||(/^Key/.test(code)?code.slice(3).toLowerCase():code==='Space'?' ':code),ctrlKey:ctrl,metaKey:false,altKey:alt,shiftKey:shift,repeat,target:target||new Element(),preventDefault(){this.prevented=true;}};for(const listener of listeners.get('keydown')||[])await listener(event);await ready();return event;}
 async function click(action,extra={}){const target=new Element();target.dataset.action=action;Object.assign(target.dataset,extra);target.closest=selector=>selector==='[data-action]'?target:null;for(const listener of listeners.get('click')||[])listener({target,stopPropagation(){}});await ready();}
 async function pointer(type,x,y){const target=document.getElementById('markup-canvas');for(const listener of listeners.get(type)||[])listener({target,clientX:x,clientY:y,pointerId:1,shiftKey:false,preventDefault(){}});await ready();}
 function columnGrip(column){const target=new Element();target.dataset.listColumn=column;target.closest=selector=>selector==='[data-list-column]'?target:null;return target;}
 async function columnDrag(column,from,to,cancel=false){const target=columnGrip(column);for(const [type,x]of [['pointerdown',from],['pointermove',to],[cancel?'pointercancel':'pointerup',to]]){for(const listener of listeners.get(type)||[])await listener({target,clientX:x,clientY:0,pointerId:1,shiftKey:false,preventDefault(){},stopPropagation(){}});await ready();}}
 async function drag(id,{alt=false}={}){const card=new Element();card.dataset.itemId=id;card.closest=selector=>selector==='[data-item-id]'?card:null;const data=new Map(),event={target:card,altKey:alt,dataTransfer:{effectAllowed:'',setData(type,value){data.set(type,value);}},preventDefault(){this.prevented=true;}};for(const listener of listeners.get('dragstart')||[])await listener(event);await ready();return{prevented:event.prevented,data,effectAllowed:event.dataTransfer.effectAllowed};}
 async function input(id,value,extra={}){const target=document.getElementById(id);Object.assign(target.dataset,extra.dataset||{});target.value=value;target.selectionStart=value.length;for(const listener of listeners.get('input')||[])await listener({target});await ready();}
 async function change(id,value,extra={}){const target=document.getElementById(id);target.value=value;Object.assign(target,extra);if(extra.dataset)target.dataset=extra.dataset;for(const listener of listeners.get('change')||[])await listener({target});await ready();}
 return{document,ready,key,input,click,change,pointer,columnGrip,columnDrag,drag,setVisualSearch(callback){visualSearch=callback;},failDetails(count=1){detailsFailures=count;},failFolder(){folderFailures++;},imageLoads,releaseInitialState(){releaseInitialState?.();},deferReply(action){let release;const promise=new Promise(resolve=>{release=resolve;});delayedReply={action,promise};return release;},failExportOnce(){exportFailures++;},failCleanupOnce(){cleanupFailures++;},failEditOnce(){editFailures++;},state,commands,nodes,image,text1,text2,link,api,get main(){return nodes.get('app').innerHTML;},get overlay(){return nodes.get('overlay-root').innerHTML;}};
}

function cards(f){return [...f.main.matchAll(/<article class="[^"]*"[^>]*data-item-id="([^"]+)"/g)].map(match=>match[1]);}
async function recent(f){await f.key('KeyL');await f.click('scope',{scope:'recent'});}
async function savedLibrary(f){await f.key('KeyL');await f.click('scope',{scope:'saved'});}
function focusedCard(f){return f.main.match(/<article class="[^"]*\bfocused\b[^"]*"[^>]*data-item-id="([^"]+)"/)?.[1]||null;}

test('image browsing previews use rendered full resolution instead of cached thumbnail and no permanent footer',async()=>{
 const f=fixture();await f.ready();f.state.items[0].thumbnailUrl='appmedia://media/'+f.image+'/thumbnail';f.api.emit({items:f.state.items});await f.ready();await f.key('Space');
 assert.match(f.overlay,new RegExp('id="preview-media" src="appmedia://media/'+f.image+'"'));
 assert.doesNotMatch(f.overlay,/preview-footer|\/thumbnail"/);
 assert.match(f.overlay,/role="toolbar" aria-label="Preview controls"/);
 assert.match(f.overlay,/data-action="pin"[^>]*aria-pressed="false"/);
 assert.doesNotMatch(f.overlay,/>◆<|>⧉</);
});

test('Library notes and memberships have focused controls and use captured target IDs',async()=>{
 const f=fixture();await f.ready();const text=f.state.items.find(value=>value.id===f.text1);text.pinned=true;text.note='A searchable note';text.folderIds=['20000000-0000-4000-8000-000000000001'];text.tags=['client'];f.state.folders=[{id:text.folderIds[0],name:'Client work'}];f.api.emit({items:f.state.items,folders:f.state.folders});await f.ready();await savedLibrary(f);assert.equal(focusedCard(f),f.text1);
 assert.match(f.main,/id="detail-note"[^>]*>A searchable note<\/textarea>/);
 await f.input('detail-note','Updated organization note');await f.click('save-inspector-draft');assert.equal(text.note,'Updated organization note');assert.deepEqual(f.commands.at(-1),{action:'details',payload:{id:f.text1,note:'Updated organization note'}});
 await f.click('remove-item-folder',{id:f.text1,folder:text.folderIds[0]});assert.equal(text.folderIds.length,0);assert.equal(f.commands.at(-1).action,'unassign');
 await f.click('remove-item-tag',{id:f.text1,tag:'client'});assert.deepEqual(text.tags,[]);assert.equal(f.commands.at(-1).action,'removeTag');
});

test('Library navigation and inspector hierarchy match the native editable-title and primary-action workflow',async()=>{
 const f=fixture();await f.ready();await recent(f);const sidebar=f.main.match(/<aside class="sidebar"[\s\S]*?<\/aside>/)[0],inspector=f.main.match(/<aside class="inspector"[\s\S]*?<\/aside>/)[0];assert.deepEqual([...sidebar.matchAll(/data-scope="([^"]+)"/g)].map(match=>match[1]),['saved','pinned','unorganized','recent','trash']);assert.match(inspector,/id="detail-name"[^>]*class="inspector-title"[^>]*aria-label="Name"/);assert.doesNotMatch(inspector,/<h2>|save-detail-name|save-detail-text|save-detail-note|Name and pin/);assert.match(inspector,/data-action="preview"[\s\S]*?<path d="M8 3H3v5M3 3l7 7M16 21h5v-5M21 21l-7-7"/);const primary=inspector.indexOf('inspector-primary-actions');assert.ok(primary>inspector.indexOf('detail-name')&&primary<inspector.indexOf('inspector-section'));assert.equal((inspector.match(/data-action="copy"/g)||[]).length,1);assert.equal((inspector.match(/data-action="pin"/g)||[]).length,1);assert.doesNotMatch(inspector,/save-inspector-draft/);
});

test('an actual failed inspector draft exposes one Save retry without turning title edits into pin actions',async()=>{
 const f=fixture();await f.ready();await recent(f);await f.key('ArrowRight');f.failDetails(2);await f.input('detail-name','Retained draft title');assert.match(f.main,/data-action="save-inspector-draft"/);assert.equal(f.state.items.find(value=>value.id===f.text1).name,'');await f.click('save-inspector-draft');assert.match(f.main,/data-action="save-inspector-draft"/);await f.click('save-inspector-draft');const value=f.state.items.find(value=>value.id===f.text1);assert.equal(value.name,'Retained draft title');assert.equal(value.pinned,false);assert.doesNotMatch(f.main,/data-action="save-inspector-draft"/);assert.equal(f.commands.some(value=>value.action==='name'),false);
});

test('inspector Add to folder preserves pin state and memberships while ShiftP still pins',async()=>{
 const f=fixture();await f.ready();const a='20000000-0000-4000-8000-000000000001',b='20000000-0000-4000-8000-000000000002';f.state.folders=[{id:a,name:'Existing folder'},{id:b,name:'Additional folder'}];Object.assign(f.state.items[0],{retainedAt:1000,folderIds:[a],pinned:false});f.api.emit({folders:f.state.folders,items:f.state.items});await f.ready();await savedLibrary(f);await f.click('add-to-folder');assert.match(f.overlay,/aria-label="Add to folder"/);assert.doesNotMatch(f.overlay,/Pin without folder/);assert.match(f.overlay,/data-action="confirm-modal"[^>]*>Add<\/button>/);await f.input('modal-query','Additional folder');await f.key('Enter');assert.deepEqual(f.commands.findLast(value=>value.action==='folder').payload,{ids:[f.image],folderId:b,pinning:false});assert.deepEqual(f.state.items[0].folderIds,[a,b]);assert.equal(f.state.items[0].pinned,false);
 await f.key('KeyP',{shift:true});assert.match(f.overlay,/Pin without folder/);await f.click('choose-folder',{folder:b});assert.deepEqual(f.commands.findLast(value=>value.action==='folder').payload,{ids:[f.image],folderId:b,rememberRecent:true});assert.equal(f.state.items[0].pinned,true);
});

test('ShiftP starts on the first real folder and keeps Pin without folder last like the native picker',async()=>{
 const f=fixture();await f.ready();const first='20000000-0000-4000-8000-000000000001',second='20000000-0000-4000-8000-000000000002';f.api.emit({folders:[{id:first,name:'References'},{id:second,name:'Video ideas'}]});await f.ready();await f.key('KeyP',{shift:true});assert.deepEqual([...f.overlay.matchAll(/data-action="choose-folder" data-folder="([^"]*)"/g)].map(match=>match[1]),[first,second,'']);await f.key('Enter');assert.deepEqual(f.commands.findLast(value=>value.action==='folder').payload,{ids:[f.image],folderId:first,rememberRecent:true});await f.key('KeyP',{shift:true});await f.key('ArrowDown');await f.key('ArrowDown');await f.key('Enter');assert.deepEqual(f.commands.at(-1),{action:'pin',payload:{ids:[f.image],value:true}});
});

test('folder display sorts folded names and stable IDs with children directly after parents without changing creation order',async()=>{
 const f=fixture();await f.ready();const id=last=>'20000000-0000-4000-8000-00000000000'+last,z=id('9'),a=id('7'),zChild=id('8'),aChildZ=id('6'),aChildA=id('5'),echoHigh=id('2'),echoLow=id('1');const created=[{id:z,name:'Zulu'},{id:aChildZ,name:'Zulu child',parentId:a},{id:zChild,name:'Alpha child',parentId:z},{id:echoHigh,name:'echo'},{id:a,name:'Ａlpha'},{id:aChildA,name:'Álpha child',parentId:a},{id:echoLow,name:'Écho'}];f.api.emit({folders:created});await f.ready();await recent(f);const expected=[a,aChildA,aChildZ,echoLow,echoHigh,z,zChild];const sidebar=f.main.match(/<aside class="sidebar"[\s\S]*?<\/aside>/)[0];assert.deepEqual([...sidebar.matchAll(/data-action="folder-scope" data-folder="([^"]+)"/g)].map(match=>match[1]),expected);assert.match(sidebar,new RegExp('data-folder="'+aChildA+'"[^>]*padding-left:25px'));await f.key('KeyP',{shift:true});assert.deepEqual([...f.overlay.matchAll(/data-action="choose-folder" data-folder="([^"]*)"/g)].map(match=>match[1]),[...expected,'']);await f.key('Escape');await f.click('add-to-folder');assert.deepEqual([...f.overlay.matchAll(/data-action="choose-folder" data-folder="([^"]*)"/g)].map(match=>match[1]),[a,aChildA,zChild,echoLow,echoHigh,z,aChildZ]);await f.key('Escape');assert.deepEqual(f.state.folders,created);
});

test('pin picker remembers only successful folder commits and promotes recents while additive inspector choices stay alphabetic',async()=>{
 const f=fixture();await f.ready();const a='20000000-0000-4000-8000-000000000001',z='20000000-0000-4000-8000-000000000002';f.api.emit({folders:[{id:z,name:'Zulu'},{id:a,name:'Alpha'}]});await f.ready();const choices=()=>[...f.overlay.matchAll(/data-action="choose-folder" data-folder="([^"]*)"/g)].map(match=>match[1]);await f.key('KeyP',{shift:true});assert.deepEqual(choices(),[a,z,'']);await f.key('ArrowDown');await f.key('Escape');assert.deepEqual(f.state.settings.recentPinFolderIds||[],[]);await f.key('KeyP',{shift:true});await f.key('ArrowDown');f.failFolder();await f.key('Enter');assert.deepEqual(f.state.settings.recentPinFolderIds||[],[]);assert.match(f.overlay,/Pin to folder/);await f.key('Enter');assert.deepEqual(f.state.settings.recentPinFolderIds,[z]);await f.key('KeyP',{shift:true});assert.deepEqual(choices(),[z,a,'']);await f.input('modal-query','Alpha');assert.deepEqual(choices(),[a]);await f.key('Escape');assert.deepEqual(f.state.settings.recentPinFolderIds,[z]);await f.click('add-to-folder');assert.deepEqual(choices(),[a,z]);await f.key('Enter');assert.deepEqual(f.state.settings.recentPinFolderIds,[z]);assert.equal(f.commands.findLast(value=>value.action==='folder').payload.rememberRecent,undefined);
});

test('Library multi-tag filters require every selected tag and Clear filters restores results',async()=>{
 const f=fixture();await f.ready();f.state.items[0].tags=['work','client'];f.state.items[1].tags=['work'];f.state.items[2].tags=['client'];f.api.emit({items:f.state.items});await f.ready();await savedLibrary(f);await f.click('toggle-filters');
 assert.match(f.main,/Tags \(match all\)/);
 await f.change('filter-work','',{dataset:{filterTag:'work'},checked:true});assert.deepEqual(cards(f),[f.image,f.text1]);
 await f.change('filter-client','',{dataset:{filterTag:'client'},checked:true});assert.deepEqual(cards(f),[f.image]);
 await f.click('clear-filters');assert.deepEqual(cards(f),[f.image,f.text1,f.text2]);await f.click('scope',{scope:'recent'});assert.deepEqual(cards(f),[f.link]);
});

test('Library Recent, Saved, Pinned and Unorganized use disjoint retention scopes and exclude Trash',async()=>{
 const f=fixture();await f.ready();const folder='20000000-0000-4000-8000-000000000001';f.state.items[0].retainedAt=0;Object.assign(f.state.items[1],{retainedAt:900,pinned:true,folderIds:[folder],tags:['client']});Object.assign(f.state.items[3],{retainedAt:700,folderIds:[folder],tags:['client']});f.state.folders=[{id:folder,name:'Client work'}];f.state.items.push({...structuredClone(f.state.items[1]),id:'00000000-0000-4000-8000-000000000005',trashedAt:1100});f.api.emit({items:f.state.items,folders:f.state.folders});await f.ready();await recent(f);assert.deepEqual(cards(f),[f.text2]);await f.click('scope',{scope:'saved'});assert.deepEqual(cards(f),[f.image,f.text1,f.link]);await f.click('scope',{scope:'unorganized'});assert.deepEqual(cards(f),[f.image]);await f.click('scope',{scope:'pinned'});assert.deepEqual(cards(f),[f.text1]);await f.click('scope',{scope:'trash'});assert.deepEqual(cards(f),['00000000-0000-4000-8000-000000000005']);
});

test('Library F filters within folder, tag and Recent without replacing their scope or eligible focus',async()=>{
 const f=fixture();await f.ready();const folder='20000000-0000-4000-8000-000000000001';f.state.items[0].retainedAt=1000;Object.assign(f.state.items[1],{retainedAt:900,pinned:true,folderIds:[folder],tags:['client'],text:'Shared reference text'});Object.assign(f.state.items[3],{retainedAt:700,folderIds:[folder],tags:['client'],title:'Shared reference link'});f.state.folders=[{id:folder,name:'Client work'}];f.api.emit({items:f.state.items,folders:f.state.folders});await f.ready();await savedLibrary(f);await f.click('folder-scope',{folder});assert.deepEqual(cards(f),[f.text1,f.link]);await f.key('ArrowRight');assert.equal(focusedCard(f),f.link);await f.key('KeyF');assert.deepEqual(cards(f),[f.text1]);assert.equal(focusedCard(f),f.text1);assert.match(f.main,/data-action="folder-scope"[^>]*class="active"/);assert.match(f.main,/data-action="pinnedOnly"[^>]*aria-pressed="true"/);await f.key('KeyF');assert.deepEqual(cards(f),[f.text1,f.link]);assert.equal(focusedCard(f),f.text1);
 await f.click('tag-scope',{tag:'client'});await f.input('search-input','Shared reference');await f.change('sort-filter','oldest');await f.key('KeyF');assert.deepEqual(cards(f),[f.text1]);assert.match(f.main,/data-action="tag-scope" data-tag="client" class="active"/);assert.match(f.main,/id="search-input"[^>]*value="Shared reference"/);assert.match(f.main,/<option value="oldest" selected>/);await f.key('KeyF');assert.deepEqual(cards(f),[f.link,f.text1]);
 await f.click('scope',{scope:'recent'});assert.deepEqual(cards(f),[f.text2]);await f.key('KeyF');assert.deepEqual(cards(f),[]);assert.match(f.main,/data-action="scope" data-scope="recent" class="active"/);await f.key('KeyF');assert.deepEqual(cards(f),[f.text2]);assert.equal(focusedCard(f),f.text2);
 await f.click('scope',{scope:'pinned'});await f.key('KeyF');assert.deepEqual(cards(f),[f.link,f.text1,f.image]);assert.match(f.main,/data-action="scope" data-scope="saved" class="active"/);await f.click('folder-scope',{folder});await f.key('KeyF');await f.click('clear-filters');assert.deepEqual(cards(f),[f.link,f.text1]);assert.match(f.main,/data-action="folder-scope"[^>]*class="active"/);assert.match(f.main,/data-action="pinnedOnly"[^>]*aria-pressed="false"/);
});

test('new permanent notes leave incompatible Library filters and open unpinned in Saved',async()=>{
 const f=fixture();await f.ready();Object.assign(f.state.items[0],{retainedAt:1000,pinned:true});f.api.emit({items:f.state.items});await f.ready();await savedLibrary(f);await f.key('KeyF');await f.click('new-note');await f.input('simple-input','A new permanent note');await f.click('confirm-modal');const note=f.state.items.find(value=>value.text==='A new permanent note');assert.ok(note?.retainedAt);assert.equal(note.pinned,false);assert.deepEqual(cards(f),[note.id,f.image]);assert.match(f.main,/data-action="scope" data-scope="saved" class="active"/);assert.match(f.main,/data-action="pinnedOnly"[^>]*aria-pressed="false"/);assert.match(f.overlay,/id="text-editor"[^>]*>A new permanent note<\/textarea>/);
});

test('Edit details chooses Saved for a retained shelf item excluded by Recent',async()=>{
 const f=fixture();await f.ready();f.state.items[0].retainedAt=0;f.api.emit({items:f.state.items});await f.ready();await recent(f);assert.ok(!cards(f).includes(f.image));await f.api.command('show');await f.click('edit-details');assert.deepEqual(cards(f),[f.image]);assert.equal(focusedCard(f),f.image);assert.match(f.main,/data-action="scope" data-scope="saved" class="active"/);
});

test('folder menus create only one subfolder level and generic New folder stays top-level',async()=>{
 const f=fixture();await f.ready();const parent='20000000-0000-4000-8000-000000000001',child='20000000-0000-4000-8000-000000000002';f.state.folders=[{id:parent,name:'Parent',parentId:null},{id:child,name:'Child',parentId:parent}];f.api.emit({folders:f.state.folders});await f.ready();await f.key('KeyL');await f.click('folder-menu',{folder:child});assert.doesNotMatch(f.overlay,/data-folder-action="new-subfolder"|New subfolder/);await f.click('close-modal');await f.click('folder-scope',{folder:child});await f.click('new-folder');await f.input('simple-input','New root');await f.click('confirm-modal');assert.deepEqual(f.commands.findLast(command=>command.action==='createFolder').payload,{name:'New root',parentId:null});await f.click('folder-menu',{folder:parent});assert.match(f.overlay,/New subfolder/);await f.click('new-subfolder',{folder:parent});await f.input('simple-input','Another child');await f.click('confirm-modal');assert.deepEqual(f.commands.findLast(command=>command.action==='createFolder').payload,{name:'Another child',parentId:parent});await f.click('remove-folder',{folder:parent});assert.match(f.overlay,/Remove this folder and its subfolders\? Item content remains in the library\./);
});

test('a subfolder scope is titled with its parent like macOS',async()=>{
 const f=fixture();await f.ready();const parent='20000000-0000-4000-8000-000000000001',child='20000000-0000-4000-8000-000000000002';
 f.state.folders=[{id:parent,name:'Parent',parentId:null},{id:child,name:'Child',parentId:parent}];f.api.emit({folders:f.state.folders});await f.ready();await savedLibrary(f);
 await f.click('folder-scope',{folder:parent});assert.match(f.main,/<div class="window-title"><strong>Parent<\/strong>/);await f.click('folder-scope',{folder:child});assert.match(f.main,/<div class="window-title"><strong>Parent \/ Child<\/strong>/);
});

test('an unnamed item is titled like macOS: trimmed first line capped at 120, link host without a fetched title',async()=>{
 const f=fixture();await f.ready();const base=(id,kind,extra)=>({id,kind,createdAt:500,updatedAt:500,name:'',title:'',text:'',url:'',pinned:false,folderIds:[],tags:[],trashedAt:null,hiddenFromShelf:false,retainedAt:500,crop:null,annotations:[],...extra});
 f.state.items=[base('30000000-0000-4000-8000-000000000001','text',{text:'\t  Indented first line \r\nsecond line'}),base('30000000-0000-4000-8000-000000000002','text',{text:'x'.repeat(130)}),base('30000000-0000-4000-8000-000000000003','link',{url:'https://www.example.com/a/very/long/path?utm_source=news'}),base('30000000-0000-4000-8000-000000000004','link',{url:'https://example.com/ref',title:'Fetched title'}),base('30000000-0000-4000-8000-000000000005','text',{text:'\n \t\r\nSecond line\nthird'}),base('30000000-0000-4000-8000-000000000006','text',{text:' \t\r\n  '}),base('30000000-0000-4000-8000-000000000007','link',{url:'http://[bad'})];
 f.api.emit({items:f.state.items});await f.ready();await savedLibrary(f);
 assert.deepEqual([...f.main.matchAll(/<article class="[^"]*" [^>]*aria-label="([^"]*)"/g)].map(match=>match[1]),['Indented first line','x'.repeat(120),'www.example.com','Fetched title','Second line','Untitled note','Link']);
});

test('removing the active folder ancestor returns Library to Saved',async()=>{
 const f=fixture();await f.ready();const parent='20000000-0000-4000-8000-000000000001',child='20000000-0000-4000-8000-000000000002';
 f.state.items[0].retainedAt=1000;f.state.items[0].folderIds=[child];f.state.folders=[{id:parent,name:'Parent',parentId:null},{id:child,name:'Child',parentId:parent}];f.api.emit({items:f.state.items,folders:f.state.folders});await f.ready();
 await savedLibrary(f);const command=f.api.command.bind(f.api);f.api.command=async(action,payload)=>{if(action==='removeFolder'){f.state.folders=[];f.state.items.forEach(item=>item.folderIds=[]);}return command(action,payload);};await f.click('folder-scope',{folder:child});assert.deepEqual(cards(f),[f.image]);await f.click('remove-folder',{folder:parent});await f.click('confirm-modal');
 assert.match(f.main,/data-action="scope" data-scope="saved" class="active"/);assert.deepEqual(cards(f),[f.image]);
});

test('removing a folder that is not open keeps the current Library view',async()=>{
 const f=fixture();await f.ready();const keep='20000000-0000-4000-8000-000000000003',other='20000000-0000-4000-8000-000000000004';
 Object.assign(f.state.items[0],{retainedAt:1000,folderIds:[keep]});Object.assign(f.state.items[1],{retainedAt:900,folderIds:[keep]});f.state.folders=[{id:keep,name:'Keep',parentId:null},{id:other,name:'Other',parentId:null}];f.api.emit({items:f.state.items,folders:f.state.folders});await f.ready();
 await savedLibrary(f);const command=f.api.command.bind(f.api),removed=[];f.api.command=async(action,payload)=>{if(action==='removeFolder'){removed.push(payload.id);f.state.folders=f.state.folders.filter(folder=>folder.id!==payload.id);}return command(action,payload);};await f.click('folder-scope',{folder:keep});assert.deepEqual(cards(f),[f.image,f.text1]);await f.key('ArrowRight');const selectedCard=/<article class="[^"]*\bselected\b[^"]*"[^>]*data-item-id="00000000-0000-4000-8000-000000000002"/;assert.match(f.main,selectedCard);assert.equal(focusedCard(f),f.text1);await f.click('remove-folder',{folder:other});await f.click('confirm-modal');
 assert.deepEqual(removed,[other]);assert.deepEqual(f.state.folders.map(folder=>folder.id),[keep]);
 assert.match(f.main,/<div class="window-title"><strong>Keep<\/strong>/);assert.doesNotMatch(f.main,/data-action="scope" data-scope="saved" class="active"/);assert.deepEqual(cards(f),[f.image,f.text1]);assert.match(f.main,selectedCard);assert.equal(focusedCard(f),f.text1);
});

test('the action list keeps Copy enabled for Trash items while editing actions are disabled',async()=>{
 const f=fixture();await f.ready();f.state.items[0].trashedAt=1000;f.api.emit({items:f.state.items});await f.ready();await f.key('KeyL');await f.click('scope',{scope:'trash'});assert.deepEqual(cards(f),[f.image]);
 await f.key('KeyK',{ctrl:true});assert.match(f.overlay,/data-command="copy" >/);assert.match(f.overlay,/data-command="pin" disabled>/);assert.match(f.overlay,/data-command="paste" disabled>/);assert.match(f.overlay,/data-command="preview" disabled>/);
});
test('restoring from Trash moves focus and selection to the first remaining item',async()=>{
 const f=fixture();await f.ready();for(const value of f.state.items.slice(0,3))value.trashedAt=1000;f.api.emit({items:f.state.items});await f.ready();await f.key('KeyL');await f.click('scope',{scope:'trash'});assert.deepEqual(cards(f),[f.image,f.text1,f.text2]);
 await f.key('ArrowRight');assert.equal(focusedCard(f),f.text1);await f.click('restore');assert.deepEqual(cards(f),[f.image,f.text2]);assert.equal(focusedCard(f),f.image);assert.match(f.main,/<article class="[^"]*\bselected\b[^"]*"[^>]*data-item-id="00000000-0000-4000-8000-000000000001"/);
});

test('restoring the only Trash item clears its stale inspector selection',async()=>{
 const f=fixture();await f.ready();f.state.items[0].trashedAt=1000;f.api.emit({items:f.state.items});await f.ready();await f.key('KeyL');await f.click('scope',{scope:'trash'});assert.deepEqual(cards(f),[f.image]);
 await f.click('restore');assert.deepEqual(cards(f),[]);assert.doesNotMatch(f.main,/data-action="restore"/);assert.match(f.main,/Select an item to view its details/);
});

test('Library tags are listed in folded-name order like the Mac library',async()=>{
 const f=fixture();await f.ready();Object.assign(f.state.items[0],{retainedAt:1000,tags:['zebra','Çay']});Object.assign(f.state.items[1],{retainedAt:900,tags:['apple','Banana']});f.api.emit({items:f.state.items});await f.ready();await savedLibrary(f);
 const expected=['apple','Banana','Çay','zebra'],order=(html,pattern)=>[...html.matchAll(pattern)].map(match=>match[1]);
 assert.deepEqual(order(f.main,/data-action="tag-scope" data-tag="([^"]+)"/g),expected,'sidebar');
 await f.click('toggle-filters');assert.deepEqual(order(f.main,/data-filter-tag="([^"]+)"/g),expected,'Library tag filter');
 await f.key('KeyT',{ctrl:true,shift:true});assert.deepEqual(order(f.overlay,/data-action="pick-tag" data-tag="([^"]+)"/g),expected,'Add tags dialog');await f.key('Escape');
 await f.key('KeyK',{ctrl:true});assert.deepEqual(order(f.overlay,/Open tag · ([^<"]+)/g),expected,'command palette');
});
test('global tag menu keyboard rename follows the selected scope and filters while deletion requires confirmation',async()=>{
 const f=fixture();await f.ready();Object.assign(f.state.items[0],{retainedAt:1000,tags:['client'],pinned:true});Object.assign(f.state.items[1],{retainedAt:900,tags:['client'],pinned:false});Object.assign(f.state.items[2],{retainedAt:800,tags:['other']});f.api.emit({items:f.state.items});await f.ready();await savedLibrary(f);await f.click('tag-scope',{tag:'client'});await f.change('filter-client','',{dataset:{filterTag:'client'},checked:true});assert.deepEqual(cards(f),[f.image,f.text1]);await f.click('tag-menu',{tag:'client'});assert.match(f.overlay,/Rename tag/);assert.match(f.overlay,/Remove tag/);await f.key('Enter');assert.match(f.overlay,/Rename tag/);await f.input('simple-input','Renamed client');await f.key('Enter');assert.deepEqual(f.commands.findLast(command=>command.action==='renameTag').payload,{tag:'client',name:'Renamed client'});assert.deepEqual(cards(f),[f.image,f.text1]);assert.match(f.main,/data-action="tag-scope" data-tag="Renamed client" class="active"/);assert.deepEqual(f.state.items[0].tags,['Renamed client']);assert.deepEqual(f.state.items[1].tags,['Renamed client']);assert.equal(f.state.items[1].pinned,false);
 await f.click('tag-menu',{tag:'Renamed client'});await f.key('ArrowDown');await f.key('Enter');assert.match(f.overlay,/Remove this tag\?/);assert.equal(f.commands.some(command=>command.action==='deleteTag'),false);await f.key('Escape');assert.deepEqual(f.state.items[0].tags,['Renamed client']);await f.click('tag-menu',{tag:'Renamed client'});await f.key('ArrowDown');await f.key('Enter');await f.click('confirm-modal');assert.deepEqual(f.commands.findLast(command=>command.action==='deleteTag').payload,{tag:'Renamed client'});assert.deepEqual(f.state.items[0].tags,[]);assert.deepEqual(f.state.items[1].tags,[]);assert.deepEqual(f.state.items[2].tags,['other']);assert.deepEqual(cards(f),[f.image,f.text1,f.text2]);assert.match(f.main,/data-action="scope" data-scope="saved" class="active"/);assert.doesNotMatch(f.main,/data-action="tag-scope" data-tag="Renamed client"/);
});

test('Library title descending and best match order actual result identities',async()=>{
 const f=fixture();await f.ready();f.state.items[0].name='Zulu reference';f.state.items[1].text='Alpha reference';f.api.emit({items:f.state.items});await f.ready();await recent(f);
 await f.change('sort-filter','titleDescending');assert.deepEqual(cards(f),[f.image,f.text2,f.link,f.text1]);
 f.state.items[0].name='reference';f.api.emit({items:f.state.items});await f.ready();await f.input('search-input','reference');await f.change('sort-filter','relevance');assert.deepEqual(cards(f),[f.image,f.text1,f.link]);
});

test('Library List exposes Title Type Tags Added columns without image-card empty space',async()=>{
 const f=fixture();await f.ready();await recent(f);await f.click('view-mode');assert.match(f.main,/library-list-header/);assert.match(f.main,/list-title/);assert.match(f.main,/list-kind/);assert.match(f.main,/list-tags/);assert.match(f.main,/list-added/);assert.doesNotMatch(f.main,/class="library-media"/);
});

test('empty My library explains retention and View recent copies is actionable',async()=>{
 const f=fixture();await f.ready();await f.key('KeyL');assert.match(f.main,/Pin an item, or add a folder or tag/);assert.match(f.main,/data-action="scope-recent"/);await f.click('scope-recent');assert.equal(cards(f).length,4);
});

test('explicitly retained items stay in My library after their pin is removed',async()=>{
 const f=fixture();await f.ready();f.state.items[1].retainedAt=1000;f.api.emit({items:f.state.items});await f.ready();await f.key('KeyL');assert.deepEqual(cards(f),[f.text1]);assert.doesNotMatch(f.main,/data-action="retain"/);
});

test('all supported Mac languages are offered in Windows Settings',async()=>{
 const f=fixture();await f.ready();await f.api.command('settings');await f.ready();for(const value of ['system','en','tr','es','fr','pt-BR','az','zh-Hans','ja','ko'])assert.match(f.main,new RegExp('<option value="'+value+'"'));
});

test('crop can resize left top and right bottom edges without moving opposite edges',async()=>{
 const f=fixture();await f.ready();await f.key('Space');await f.key('KeyC');await f.pointer('pointerdown',100,40);await f.pointer('pointermove',600,180);await f.pointer('pointerup',600,180);
 await f.pointer('pointerdown',100,100);await f.pointer('pointermove',150,100);await f.pointer('pointerup',150,100);
 await f.pointer('pointerdown',350,40);await f.pointer('pointermove',350,60);await f.pointer('pointerup',350,60);
 await f.pointer('pointerdown',600,120);await f.pointer('pointermove',650,120);await f.pointer('pointerup',650,120);
 await f.pointer('pointerdown',350,180);await f.pointer('pointermove',350,200);await f.pointer('pointerup',350,200);await f.key('Enter');
 assert.deepEqual(f.state.items[0].crop,{x:150,y:60,width:500,height:140});
});

test('crop corners clamp inside original and maintain nonzero size',async()=>{
 const f=fixture();await f.ready();await f.key('Space');await f.key('KeyC');await f.pointer('pointerdown',100,40);await f.pointer('pointermove',600,180);await f.pointer('pointerup',600,180);
 await f.pointer('pointerdown',100,40);await f.pointer('pointermove',650,200);await f.pointer('pointerup',650,200);await f.key('Enter');assert.deepEqual(f.state.items[0].crop,{x:599,y:179,width:1,height:1});
});

test('Reset crop preserves annotations and Clear annotations preserves crop',async()=>{
 const f=fixture();await f.ready();const image=f.state.items[0];image.crop={x:10,y:10,width:500,height:150};image.annotations=[{type:'rectangle',x:40,y:30,width:60,height:60,color:'#ff0000'}];f.api.emit({items:f.state.items});await f.ready();await f.key('Space');await f.key('KeyC');await f.click('reset-crop');await f.click('save-image');assert.equal(image.crop,null);assert.equal(image.annotations.length,1);
 image.crop={x:10,y:10,width:500,height:150};f.api.emit({items:f.state.items});await f.ready();await f.key('KeyM');await f.click('clear-annotations');await f.click('save-image');assert.deepEqual(image.crop,{x:10,y:10,width:500,height:150});assert.deepEqual(image.annotations,[]);
});

test('image crop undo and redo remain available after Done returns to browsing preview',async()=>{
 const f=fixture();await f.ready();await f.key('Space');await f.key('KeyC');await f.pointer('pointerdown',60,30);await f.pointer('pointermove',500,150);await f.pointer('pointerup',500,150);await f.key('Enter');assert.deepEqual(f.state.items[0].crop,{x:60,y:30,width:440,height:120});assert.doesNotMatch(f.overlay,/markup-canvas/);
 await f.key('KeyZ',{ctrl:true});assert.equal(f.state.items[0].crop,null);assert.doesNotMatch(f.overlay,/markup-canvas/);
 await f.key('KeyZ',{ctrl:true,shift:true});assert.deepEqual(f.state.items[0].crop,{x:60,y:30,width:440,height:120});assert.doesNotMatch(f.overlay,/markup-canvas/);
});

test('Library visual search uses only eligible image IDs, combines with text and respects text-only mode',async()=>{
 const f=fixture();await f.ready();f.setVisualSearch(({eligibleIds})=>({ids:[f.image,f.text1],scores:[{id:f.image,score:.4},{id:f.text1,score:99}],available:true,indexing:false}));await recent(f);await f.input('search-input','ocean');assert.deepEqual(cards(f),[f.image]);const request=f.commands.findLast(command=>command.action==='searchImages');assert.deepEqual(request.payload,{query:'ocean',eligibleIds:[f.image]});
 await f.change('search-mode-filter','text');assert.deepEqual(cards(f),[]);await f.input('search-input','Text one');assert.deepEqual(cards(f),[f.text1]);
 await f.change('search-mode-filter','visual');assert.deepEqual(cards(f),[f.image]);await f.click('clear-filters');assert.equal(cards(f).length,4);
});

test('visual query results from an older request cannot replace the current query or cross Library scope',async()=>{
 const f=fixture();await f.ready();let release;const delayed=new Promise(resolve=>{release=resolve;});f.setVisualSearch(({query})=>query==='old query'?delayed:{ids:[],scores:[],available:true,indexing:false});await recent(f);await f.input('search-input','old query');await f.input('search-input','new query');assert.deepEqual(cards(f),[]);release({ids:[f.image],scores:[{id:f.image,score:.5}],available:true,indexing:false});await f.ready();assert.deepEqual(cards(f),[]);
 f.setVisualSearch(()=>({ids:[f.image],scores:[{id:f.image,score:.5}],available:true,indexing:false}));await f.click('scope',{scope:'saved'});await f.input('search-input','ocean');assert.deepEqual(cards(f),[]);assert.deepEqual(f.commands.findLast(command=>command.action==='searchImages').payload.eligibleIds,[]);
});

test('local image index revisions refresh an existing visual query without semantic calls from shelves',async()=>{
 const f=fixture();await f.ready();let indexed=false;f.setVisualSearch(()=>({ids:indexed?[f.image]:[],scores:indexed?[{id:f.image,score:.4}]:[],available:indexed,indexing:!indexed}));await f.key('KeyS',{shift:true});await f.input('search-input','ocean');assert.equal(f.commands.filter(command=>command.action==='searchImages').length,0);await f.key('Escape');await recent(f);await f.input('search-input','ocean');assert.deepEqual(cards(f),[]);assert.match(f.main,/Indexing images locally/);indexed=true;f.api.emit({imageSearch:{available:true,indexing:false,revision:1}});await f.ready();assert.deepEqual(cards(f),[f.image]);assert.equal(f.commands.filter(command=>command.action==='searchImages').length,2);
});

test('Library layout toggles persist and saved column visibility, sizes and view are restored',async()=>{
 const f=fixture();await f.ready();await recent(f);await f.click('view-mode');assert.equal(f.state.settings.libraryListMode,true);await f.click('toggle-inspector');assert.equal(f.state.settings.libraryInspectorVisible,false);await f.click('toggle-sidebar');assert.equal(f.state.settings.librarySidebarVisible,false);
 f.api.emit({settings:{...f.state.settings,libraryListMode:false,libraryInspectorVisible:true,librarySidebarVisible:true,librarySidebarWidth:280,libraryInspectorWidth:370}});await f.ready();assert.match(f.main,/class="sidebar" style="width:280px;flex-basis:280px"/);assert.match(f.main,/class="inspector" style="width:370px;flex-basis:370px"/);assert.doesNotMatch(f.main,/library-grid list/);assert.match(f.main,/data-library-divider="sidebar"/);assert.match(f.main,/data-library-divider="inspector"/);
});

test('inspector automatically saves name text and note without pinning before navigating away',async()=>{
 const f=fixture();await f.ready();await recent(f);await f.key('ArrowRight');await f.input('detail-name','Inspector title without pin');await f.input('detail-text','Edited in Library inspector');await f.input('detail-note','Autosaved organization context');await f.key('ArrowRight');const value=f.state.items.find(value=>value.id===f.text1);assert.equal(value.name,'Inspector title without pin');assert.equal(value.text,'Edited in Library inspector');assert.equal(value.note,'Autosaved organization context');assert.equal(value.pinned,false);assert.ok(f.commands.some(value=>value.action==='details'&&value.payload.id===f.text1));assert.match(f.main,new RegExp('data-item-id="'+f.text2+'"'));
});

test('failed inspector write keeps the draft and aborts navigation until a successful retry',async()=>{
 const f=fixture();await f.ready();await recent(f);await f.key('ArrowRight');f.failDetails(2);await f.input('detail-text','Draft must not disappear');assert.equal(f.state.items.find(value=>value.id===f.text1).text,'Text one');await f.key('ArrowRight');assert.match(f.main,new RegExp('card kind-text focused selected[^>]*data-item-id="'+f.text1+'"'));assert.match(f.main,/Draft must not disappear/);assert.match(f.nodes.get('toast').textContent,/Changes could not be saved/);await f.key('ArrowRight');assert.equal(f.state.items.find(value=>value.id===f.text1).text,'Draft must not disappear');assert.match(f.main,new RegExp('card kind-text focused selected[^>]*data-item-id="'+f.text2+'"'));
});

test('edits made during an in-flight inspector save are not cleared by its older completion',async()=>{
 const f=fixture();await f.ready();await recent(f);await f.key('ArrowRight');const release=f.deferReply('details');await f.input('detail-text','First saved draft');await f.input('detail-text','Newer saved draft');await f.input('detail-note','Newer note');release();await f.ready();assert.equal(f.state.items.find(value=>value.id===f.text1).text,'Newer saved draft');assert.equal(f.state.items.find(value=>value.id===f.text1).note,'Newer note');await f.click('scope',{scope:'saved'});assert.equal(cards(f).length,0);
});

test('Library Title and Added headers toggle matching sorts through real action handlers',async()=>{
 const f=fixture();await f.ready();await recent(f);await f.click('view-mode');await f.click('sort-column',{column:'title'});assert.deepEqual(cards(f),[f.link,f.image,f.text1,f.text2]);assert.match(f.main,/data-action="sort-column" data-column="title" aria-pressed="true"/);await f.click('sort-column',{column:'title'});assert.deepEqual(cards(f),[f.text2,f.text1,f.image,f.link]);await f.click('sort-column',{column:'created'});assert.deepEqual(cards(f),[f.image,f.text1,f.text2,f.link]);await f.click('sort-column',{column:'created'});assert.deepEqual(cards(f),[f.link,f.text2,f.text1,f.image]);
});

test('list column pointer resize clamps to native bounds, persists widths and cancel restores the original',async()=>{
 const f=fixture();await f.ready();await recent(f);await f.click('view-mode');await f.columnDrag('title',300,440);assert.equal(f.state.settings.libraryListColumns.title,440);assert.match(f.main,/--list-title-width:440px/);await f.columnDrag('title',0,-900);assert.equal(f.state.settings.libraryListColumns.title,180);await f.columnDrag('tags',0,10000);assert.equal(f.state.settings.libraryListColumns.tags,800);const before=f.commands.filter(value=>value.action==='setSettings').length;await f.columnDrag('tags',0,-500,true);assert.match(f.main,/--list-tags-width:800px/);assert.equal(f.commands.filter(value=>value.action==='setSettings').length,before);
});

test('list column separator keyboard resize supports arrows Home and End and restores saved columns',async()=>{
 const f=fixture();await f.ready();await recent(f);await f.click('view-mode');const target=f.columnGrip('created');await f.key('ArrowRight',{target});assert.equal(f.state.settings.libraryListColumns.created,140);await f.key('Home',{target});assert.equal(f.state.settings.libraryListColumns.created,100);await f.key('End',{target});assert.equal(f.state.settings.libraryListColumns.created,500);f.api.emit({settings:{...f.state.settings,libraryListColumns:{title:375,kind:95,tags:210,created:175}}});await f.ready();for(const [key,width]of Object.entries({title:375,kind:95,tags:210,created:175}))assert.match(f.main,new RegExp('--list-'+key+'-width:'+width+'px'));assert.match(f.main,/data-list-column="created"[^>]*aria-valuenow="175"/);
});

test('default text drag preserves combined text insertion while Alt drag requests ordered separate file copies',async()=>{
 const f=fixture();await f.ready();await f.key('ArrowDown');await f.key('KeyA',{ctrl:true});let drag=await f.drag(f.text1);assert.equal(drag.prevented,undefined);assert.equal(drag.data.get('text/plain'),'Text one\n\nText two');assert.equal(drag.effectAllowed,'copy');assert.equal(f.commands.filter(value=>value.action==='startDrag').length,0);assert.match(f.main,/Drag to insert text · Alt\+drag to export file copies/);
 drag=await f.drag(f.text1,{alt:true});assert.equal(drag.prevented,true);assert.equal(f.commands.at(-1).action,'startDrag');assert.deepEqual(f.commands.at(-1).payload.ids,[f.text1,f.text2]);assert.equal(drag.data.get('text/plain'),'Text one\n\nText two');
 await f.key('ArrowDown');drag=await f.drag(f.link);assert.equal(drag.prevented,undefined);assert.equal(drag.data.get('text/plain'),'https://example.com/reference');await f.drag(f.link,{alt:true});assert.deepEqual(f.commands.at(-1).payload.ids,[f.link]);
});

test('after editing text column one, Up previews image column one and explicit First moves to the first image',async()=>{
 const f=fixture();await f.ready();const newer='00000000-0000-4000-8000-000000000005';f.state.items.push({...structuredClone(f.state.items[0]),id:newer,createdAt:2000,name:'New first image',mediaUrl:'appmedia://media/'+newer,originalMediaUrl:'appmedia://media/'+newer+'/original'});f.api.emit({items:f.state.items});await f.ready();await f.api.command('hide');await f.api.command('show');await f.ready();await f.key('ArrowDown');await f.key('ArrowRight');await f.key('Space');await f.key('KeyE');await f.input('text-editor','Edited second column text');await f.key('Enter',{ctrl:true});await f.key('ArrowUp');assert.match(f.overlay,/aria-label="Synthetic image"/);assert.match(f.main,new RegExp('card kind-image focused selected[^>]*data-item-id="'+f.image+'"'));await f.key('ArrowLeft',{ctrl:true});assert.match(f.overlay,/aria-label="New first image"/);assert.match(f.main,new RegExp('card kind-image focused selected[^>]*data-item-id="'+newer+'"'));
});

test('multiple crop gestures commit as one applied document for browsing undo and redo',async()=>{
 const f=fixture();await f.ready();await f.key('Space');await f.key('KeyC');await f.pointer('pointerdown',100,40);await f.pointer('pointermove',600,180);await f.pointer('pointerup',600,180);await f.pointer('pointerdown',100,110);await f.pointer('pointermove',150,110);await f.pointer('pointerup',150,110);await f.pointer('pointerdown',375,40);await f.pointer('pointermove',375,60);await f.pointer('pointerup',375,60);await f.key('Enter');const applied={x:150,y:60,width:450,height:120};assert.deepEqual(f.state.items[0].crop,applied);await f.key('KeyZ',{ctrl:true});assert.equal(f.state.items[0].crop,null);await f.key('KeyZ',{ctrl:true,shift:true});assert.deepEqual(f.state.items[0].crop,applied);
});

test('canceling multiple crop gestures restores the previous markup undo history',async()=>{
 const f=fixture();await f.ready();await f.key('Space');await f.key('KeyM');await f.key('KeyR');await f.pointer('pointerdown',50,40);await f.pointer('pointermove',130,100);await f.pointer('pointerup',130,100);await f.key('KeyC');await f.pointer('pointerdown',100,40);await f.pointer('pointermove',600,180);await f.pointer('pointerup',600,180);await f.pointer('pointerdown',100,110);await f.pointer('pointermove',150,110);await f.pointer('pointerup',150,110);await f.key('Escape');await f.key('KeyZ',{ctrl:true});await f.click('save-image');assert.equal(f.state.items[0].crop,null);assert.deepEqual(f.state.items[0].annotations,[]);
});

test('failed crop apply retries do not duplicate the crop undo transaction',async()=>{
 const f=fixture();await f.ready();await f.key('Space');await f.key('KeyC');await f.pointer('pointerdown',60,30);await f.pointer('pointermove',500,150);await f.pointer('pointerup',500,150);f.failExportOnce();await f.key('Enter');assert.match(f.overlay,/markup-canvas/);await f.key('Enter');assert.deepEqual(f.state.items[0].crop,{x:60,y:30,width:440,height:120});await f.key('KeyZ',{ctrl:true});assert.equal(f.state.items[0].crop,null);const saved=f.commands.filter(value=>value.action==='saveImage').length;await f.key('KeyZ',{ctrl:true});assert.equal(f.commands.filter(value=>value.action==='saveImage').length,saved,'A failed apply must not leave another crop checkpoint');
});


test('background indexing broadcasts preserve the active canvas until the pointer transaction ends',async()=>{
 const f=fixture();await f.ready();await f.key('Space');await f.key('KeyC');assert.match(f.overlay,/id="markup-canvas" width="900" height="220"/);await f.pointer('pointerdown',540,44);const overlay=f.nodes.get('overlay-root'),writes=overlay.htmlWrites;f.api.emit({imageSearch:{available:true,indexing:true,revision:10}});await f.ready();assert.equal(overlay.htmlWrites,writes,'A background state packet must not replace the canvas during its gesture');await f.pointer('pointermove',810,176);await f.pointer('pointerup',810,176);assert.ok(overlay.htmlWrites>writes,'The toolbar receives deferred updates after the gesture');await f.key('Enter');assert.deepEqual(f.state.items[0].crop,{x:540,y:44,width:270,height:132});
 await f.key('KeyM');await f.key('KeyR');await f.pointer('pointerdown',20,20);const drawingWrites=overlay.htmlWrites;f.api.emit({imageSearch:{available:true,indexing:false,revision:11}});await f.ready();assert.equal(overlay.htmlWrites,drawingWrites);await f.pointer('pointermove',120,80);await f.pointer('pointerup',120,80);await f.click('save-image');assert.equal(f.state.items[0].annotations.length,1);assert.equal(f.state.items[0].annotations[0].width,100);
});


function asRecording(f){const video=f.state.items[0];Object.assign(video,{recording:true,videoUrl:'appmedia://media/'+video.id+'/video?v='+'a'.repeat(64),originalVideoUrl:'appmedia://media/'+video.id+'/video/original',durationMs:6000,width:160,height:120,sourceFingerprint:'a'.repeat(64)});f.api.emit({items:f.state.items});return video;}

test('recordings share image cards and open the managed video player without still crop or OCR commands',async()=>{
 const f=fixture();await f.ready();asRecording(f);await f.ready();assert.match(f.main,/recording-card/);assert.match(f.main,/recording-badge/);await f.key('Space');assert.match(f.overlay,/id="preview-video" data-video-id=/);assert.match(f.overlay,/crossorigin="anonymous" src="appmedia:\/\/media\/[^"/]+\/video\?v=[a-f0-9]{64}"/);assert.doesNotMatch(f.overlay,/<canvas|data-action="crop"/);await f.key('KeyC');assert.doesNotMatch(f.overlay,/<canvas|trim-start-range/);await f.key('KeyK',{ctrl:true});assert.match(f.overlay,/Trim video/);assert.match(f.overlay,/data-command="crop" disabled/);assert.match(f.overlay,/data-command="copyOCR" disabled/);await f.key('Escape');
});

test('M opens recording trim, editable bounds preserve 100ms minimum and Enter saves the exact source generation',async()=>{
 const f=fixture();await f.ready();const video=asRecording(f);await f.ready();await f.key('Space');await f.key('KeyM');assert.match(f.overlay,/id="trim-start-range"/);assert.doesNotMatch(f.overlay,/<canvas/);await f.input('trim-start','2',{dataset:{videoTrim:'startMs',seconds:'true'}});await f.input('trim-end','1',{dataset:{videoTrim:'endMs',seconds:'true'}});assert.equal(f.nodes.get('trim-end-range').value,2100);await f.input('trim-end','4',{dataset:{videoTrim:'endMs',seconds:'true'}});await f.key('Enter');const request=f.commands.find(value=>value.action==='trimRecording');assert.deepEqual(request,{action:'trimRecording',payload:{id:video.id,startMs:2000,endMs:4000,sourceFingerprint:video.sourceFingerprint}});assert.doesNotMatch(f.overlay,/trim-start-range/);assert.match(f.overlay,/preview-video/);assert.equal(f.commands.some(value=>value.action==='saveImage'),false);
});

test('background state packets preserve recording trim input/player identities and exact bounds until save',async()=>{
 const f=fixture();await f.ready();const video=asRecording(f);await f.ready();await f.key('Space');await f.key('KeyM');await f.input('trim-start','2',{dataset:{videoTrim:'startMs',seconds:'true'}});const controls=f.nodes.get('video-trim-controls'),end=f.nodes.get('trim-end'),player=f.nodes.get('preview-video'),overlay=f.nodes.get('overlay-root'),writes=overlay.htmlWrites;f.api.emit({imageSearch:{available:true,indexing:true,revision:12}});await f.ready();assert.equal(overlay.htmlWrites,writes);assert.equal(f.nodes.get('trim-end'),end);assert.equal(f.nodes.get('video-trim-controls'),controls);assert.equal(f.nodes.get('preview-video'),player);await f.input('trim-end','4',{dataset:{videoTrim:'endMs',seconds:'true'}});assert.equal(f.nodes.get('trim-start-range').value,2000);assert.equal(f.nodes.get('trim-end-range').value,4000);
 const release=f.deferReply('trimRecording');await f.click('video-trim-save');assert.ok(controls.querySelectorAll('input').every(input=>input.disabled));assert.equal(f.nodes.get('trim-end'),end);assert.deepEqual(f.commands.find(value=>value.action==='trimRecording'),{action:'trimRecording',payload:{id:video.id,startMs:2000,endMs:4000,sourceFingerprint:video.sourceFingerprint}});release();await f.ready();assert.doesNotMatch(f.overlay,/trim-start-range/);
});

test('a changed recording source or removed record invalidates trim DOM preservation',async()=>{
 const f=fixture();await f.ready();const video=asRecording(f);await f.ready();await f.key('Space');await f.key('KeyM');const controls=f.nodes.get('video-trim-controls'),player=f.nodes.get('preview-video'),writes=f.nodes.get('overlay-root').htmlWrites;video.sourceFingerprint='b'.repeat(64);video.videoUrl='appmedia://media/'+video.id+'/video?v='+video.sourceFingerprint;f.api.emit({items:f.state.items});await f.ready();assert.ok(f.nodes.get('overlay-root').htmlWrites>writes);assert.notEqual(f.nodes.get('video-trim-controls'),controls);assert.notEqual(f.nodes.get('preview-video'),player);assert.equal(f.nodes.get('preview-video').dataset.sourceFingerprint,video.sourceFingerprint);video.trashedAt=Date.now();f.api.emit({items:f.state.items});await f.ready();assert.match(f.overlay,/empty-preview/);assert.doesNotMatch(f.overlay,/trim-start-range/);
});

test('Esc cancels recording range and preview toolbar navigation cancels before switching items',async()=>{
 const f=fixture();await f.ready();const video=asRecording(f),other='00000000-0000-4000-8000-000000000007';f.state.items.push({...structuredClone(f.state.items[0]),id:other,recording:false,name:'Another image',createdAt:500,mediaUrl:'appmedia://media/'+other});f.api.emit({items:f.state.items});await f.ready();await f.key('Space');await f.key('KeyM');await f.input('trim-start','2',{dataset:{videoTrim:'startMs',seconds:'true'}});await f.key('Escape');assert.doesNotMatch(f.overlay,/trim-start-range/);assert.equal(f.commands.at(-1).action,'cancelTrim');assert.equal(f.state.items[0].durationMs,6000);await f.key('KeyM');await f.click('next');assert.equal(f.commands.at(-1).action,'cancelTrim');assert.equal(f.commands.filter(value=>value.action==='cancelTrim').length,2);assert.equal(f.commands.some(value=>value.action==='trimRecording'),false);assert.match(f.overlay,/id="preview-media"/);assert.match(f.overlay,/aria-label="Another image"/);assert.equal(video.sourceFingerprint,'a'.repeat(64));
});

test('a background state push keeps keyboard focus on the focused dialog button instead of dropping it to the page',async()=>{
 const f=fixture();await f.ready();await f.key('KeyF');
 // The shared stub DOM does not parse markup; give the overlay just enough of one to model destroyed focus.
 const overlay=f.nodes.get('overlay-root'),buttons=[],attribute=(html,name)=>html.match(new RegExp(' data-'+name+'="([^"]*)"'))?.[1];
 Object.defineProperty(overlay,'innerHTML',{configurable:true,get(){return this._html||'';},set(html){
  if(buttons.includes(f.document.activeElement))f.document.activeElement=f.document.body;
  this._html=html;buttons.length=0;
  for(const [, attributes] of html.matchAll(/<button([^>]*)>/g)){const button={id:'',dataset:{action:attribute(attributes,'action')},focus(){f.document.activeElement=this;}};if(button.dataset.action)buttons.push(button);}
 }});
 overlay.contains=node=>buttons.includes(node);
 overlay.querySelectorAll=selector=>{const wanted=[...selector.matchAll(/\[data-(\w+)="([^"]*)"\]/g)];return wanted.length?buttons.filter(button=>wanted.every(([, key, value])=>button.dataset[key]===value)):[];};
 overlay.querySelector=selector=>overlay.querySelectorAll(selector)[0]||null;
 await f.click('new-note');
 const cancels=buttons.filter(button=>button.dataset.action==='close-modal');assert.equal(cancels.length,2,'header close and footer Cancel');
 cancels[1].focus();assert.equal(f.document.activeElement,cancels[1]);
 f.api.emit({});await f.ready();
 const rebuilt=buttons.filter(button=>button.dataset.action==='close-modal');
 assert.notEqual(rebuilt[1],cancels[1],'the overlay was rebuilt');assert.equal(f.document.activeElement,rebuilt[1],'focus returns to the same (footer) Cancel button');
 // A different dialog, or no focused button, must not steal focus.
 f.document.activeElement=f.document.body;f.api.emit({});await f.ready();assert.equal(f.document.activeElement,f.document.body);
 // An unmatchable selector (for example a stored tag with a control character) must not stop the refresh.
 const again=buttons.filter(button=>button.dataset.action==='close-modal');again[1].focus();overlay.querySelectorAll=()=>{throw new SyntaxError('invalid selector');};
 f.api.emit({});await f.ready();assert.ok(overlay.innerHTML.includes('close-modal'),'the overlay is still rebuilt');
});
test('Space on a focused dialog button activates it on keydown, so a background refresh between keydown and keyup cannot drop the click',async()=>{
 const f=fixture();await f.ready();await f.key('KeyF');
 // Chromium clicks a button on Space keyup only if the same element saw the keydown; a state push rebuilds the overlay in between.
 const overlay=f.nodes.get('overlay-root'),buttons=[];
 Object.defineProperty(overlay,'innerHTML',{configurable:true,get(){return this._html||'';},set(html){
  this._html=html;buttons.length=0;
  for(const [, attributes] of html.matchAll(/<button([^>]*)>/g)){const action=attributes.match(/ data-action="([^"]*)"/)?.[1];if(!action)continue;const button={id:'',dataset:{action},clicks:0,closest:selector=>selector==='button'?button:null,focus(){f.document.activeElement=button;},click(){button.clicks++;void f.click(action);}};buttons.push(button);}
 }});
 overlay.contains=node=>buttons.includes(node);overlay.querySelectorAll=()=>[];overlay.querySelector=()=>null;
 await f.click('new-note');
 const cancel=buttons.filter(button=>button.dataset.action==='close-modal')[1];cancel.focus();
 const enter=await f.key('Enter',{target:cancel});assert.equal(enter.prevented,undefined,'Enter keeps its native activation');assert.equal(cancel.clicks,0);assert.ok(overlay.innerHTML.includes('close-modal'));
 const repeat=await f.key('Space',{target:cancel,repeat:true});assert.equal(cancel.clicks,0,'a held key does not repeat the click');assert.equal(repeat.prevented,true);
 const space=await f.key('Space',{target:cancel});assert.equal(space.prevented,true,'the native keyup click is suppressed so it cannot fire twice');assert.equal(cancel.clicks,1);assert.ok(!overlay.innerHTML.includes('close-modal'),'Cancel closed the dialog on keydown');
});
test('Library Last copied falls back to the creation time, so editing a never-copied item does not reorder it',async()=>{
 const f=fixture();await f.ready();f.state.items[1].lastCopiedAt=950;f.state.items[2].updatedAt=5000;f.api.emit({items:f.state.items});await f.ready();await recent(f);
 await f.change('sort-filter','copied');assert.deepEqual(cards(f),[f.image,f.text1,f.text2,f.link]);
});
test('Library domain filter ignores case, surrounding spaces and dots, www and an empty value like the native filter',async()=>{
 const f=fixture();await f.ready();f.state.items[0].tags=['x'];f.state.items.find(item=>item.id===f.link).retainedAt=1;f.api.emit({items:f.state.items});await f.ready();await savedLibrary(f);await f.click('toggle-filters');
 for(const value of ['example.com',' Example.COM ','WWW.example.com','.example.com.'])await f.input('domain-filter',value),assert.deepEqual(cards(f),[f.link],JSON.stringify(value));
 await f.input('domain-filter','other.org');assert.deepEqual(cards(f),[]);
 await f.input('domain-filter','  ');assert.deepEqual(cards(f),[f.image,f.link]);
});
