'use strict';
// Runs the actual renderer handlers with a small DOM/IPC fixture. These cases
// validate UI state transitions, not browser layout or native Windows paste.
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const crypto=require('node:crypto');
const {execFileSync}=require('node:child_process');

function fixture({deferInitialState=false,initialVisible=true,queuedAnimationFrames=false,imageRaster={width:900,height:220},imageDocument=false}={}){
 const listeners=new Map(),nodes=new Map(),commands=[],imageLoads=[],animationFrames=[],paintCalls=[];let exportFailures=0;
 class Element{
  constructor(id=''){this.id=id;this.innerHTML='';this.textContent='';this.dataset={};this.style={};this.className='';this.value='';this.selectionStart=0;this.selectionEnd=0;this.classList={add(){},remove(){},contains(){return false;}};}
  setAttribute(){}querySelector(){return null;}querySelectorAll(){return [];}focus(){}blur(){}select(){}setSelectionRange(){}scrollIntoView(){}matches(){return false;}closest(){return null;}
 }
 class TextArea extends Element{}
 class Canvas extends Element{
  constructor(id=''){super(id);this.width=900;this.height=220;}
  getBoundingClientRect(){return{left:0,top:0,width:900,height:220};}
  getContext(){const canvas=this;return new Proxy({}, {get(object,key){if(key==='drawImage'||key==='clearRect')return(...args)=>paintCalls.push({canvas:canvas.id,operation:key,source:args[0] instanceof FixtureImage?'original':'other'});return object[key]??(()=>{});},set(object,key,value){object[key]=value;return true;}});}
  toDataURL(){if(exportFailures){exportFailures--;throw Object.assign(new Error('Synthetic canvas export rejection'),{name:'SecurityError'});}return 'data:image/png;base64,iVBORw0KGgo=';}
 }
 class FixtureImage extends Element{
  constructor(){super();this.naturalWidth=imageRaster.width;this.naturalHeight=imageRaster.height;this.complete=true;}
  set src(value){imageLoads.push({url:value,crossOrigin:this.crossOrigin});if(this.onload)queueMicrotask(()=>this.onload());}
 }
 const document={body:new Element('body'),activeElement:null,querySelectorAll(){return[];},getElementById(id){if(!nodes.has(id))nodes.set(id,id==='markup-canvas'?new Canvas(id):new Element(id));return nodes.get(id);},createElement(tag){return tag==='canvas'?new Canvas():new Element();},querySelector(){return null;},addEventListener(name,listener){if(!listeners.has(name))listeners.set(name,[]);listeners.get(name).push(listener);}};
 const image='00000000-0000-4000-8000-000000000001',text1='00000000-0000-4000-8000-000000000002',text2='00000000-0000-4000-8000-000000000003',link='00000000-0000-4000-8000-000000000004';
 const base=(id,kind,createdAt,extra)=>({id,kind,createdAt,updatedAt:createdAt,name:'',title:'',text:'',url:'',pinned:false,folderIds:[],tags:[],trashedAt:null,hiddenFromShelf:false,...extra});
 const state={items:[base(image,'image',1000,{name:'Synthetic image',...(imageDocument?{annotations:[],crop:null}:{}),mediaUrl:'appmedia://media/'+image,originalMediaUrl:'appmedia://media/'+image+'/original'}),base(text1,'text',900,{text:'Text one'}),base(text2,'text',800,{text:'Text two'}),base(link,'link',700,{url:'https://example.com/reference',title:'Reference link'})],folders:[],settings:{visibleKinds:['image','text','link'],retentionDays:{image:30,text:30,link:30},shortcuts:{toggle:'Control+Alt+Space',search:'Control+Alt+S'},localShortcuts:{},language:'en',theme:'soft',cardSize:'medium'},view:'shelves',version:'1.7.0',windowVisible:initialVisible,canUndo:false,canUndoTrash:false,r2Configured:true,r2HasSecret:true,libraryRevision:0};
 let subscriber,removed=[],trashRemoved=[],cleanupFailures=0,editFailures=0,delayedReply=null,releaseInitialState,deferredImageBroadcast=null,pendingImageBroadcast=null;
 const clone=value=>structuredClone(value);
 const api={emit(patch){Object.assign(state,patch);subscriber?.(clone(state));},surface(patch){Object.assign(state,patch);subscriber?.({surfaceOnly:true,...clone(patch)});},state:async()=>{const initial=clone(state);if(deferInitialState)await new Promise(resolve=>{releaseInitialState=resolve;});return initial;},subscribe(fn){subscriber=fn;return()=>{};},async command(action,payload={}){commands.push({action,payload:clone(payload)});const selected=state.items.filter(item=>(payload.ids||[payload.id]).includes(item.id));
  let cleanupError,trashResult;if(action==='cleanup'){if(cleanupFailures){cleanupFailures--;cleanupError='Permanent deletion cleanup is still pending.';}else state.needsDeletionCleanup=false;}
  if(action==='editText'){if(editFailures){editFailures--;cleanupError='Synthetic draft write failure';}else selected.forEach(item=>{if(item.text!==payload.text){delete item.uploadedUrl;delete item.uploadedAt;}item.text=payload.text;});}
  if(action==='setSettings'){const patch=payload.patch||{},localShortcuts={...state.settings.localShortcuts,...patch.localShortcuts};for(const [action,value]of Object.entries(localShortcuts))if(value===null)delete localShortcuts[action];state.settings={...state.settings,...patch,localShortcuts};}
  if(action==='saveImage')selected.forEach(item=>{item.crop=clone(payload.crop);item.annotations=clone(payload.annotations);delete item.uploadedUrl;delete item.uploadedAt;});
  if(action==='uploadItem'){let cached=false;selected.forEach(item=>{if(!payload.force&&item.uploadedUrl)cached=true;else{item.uploadedUrl='https://cdn.example.com/'+item.id;item.uploadedAt=Date.now();}});trashResult={cached};}
  if(action==='uploadLatest'){const latest=state.items.filter(item=>!item.trashedAt&&!item.hiddenFromShelf).sort((a,b)=>b.createdAt-a.createdAt)[0];if(latest){const cached=!!latest.uploadedUrl;if(!cached){latest.uploadedUrl='https://cdn.example.com/'+latest.id;latest.uploadedAt=Date.now();}trashResult={cached,url:latest.uploadedUrl};}}
  if(action==='setR2Secret'){state.r2HasSecret=true;state.r2Configured=Boolean(state.settings.r2AccountId&&state.settings.r2AccessKeyId&&state.settings.r2Bucket&&state.settings.r2PublicBaseUrl);}
  if(action==='clearR2Secret'){state.r2HasSecret=false;state.r2Configured=false;}
  if(action==='testR2Connection'){trashResult={ok:true};}
  if(action==='pin')selected.forEach(item=>item.pinned=typeof payload.value==='boolean'?payload.value:!item.pinned);
  if(action==='name')selected.forEach(item=>{item.name=payload.name;item.pinned=true;});
  if(action==='remove'){removed=selected.map(clone);selected.forEach(item=>{if(item.pinned)item.hiddenFromShelf=true;else item.trashedAt=Date.now();});state.canUndo=true;}
  if(action==='undo'){for(const before of removed)Object.assign(state.items.find(item=>item.id===before.id),before);state.canUndo=false;}
  if(action==='trashUndoably'){trashRemoved=selected.filter(item=>!item.trashedAt).map(clone);trashResult={ids:trashRemoved.map(item=>item.id)};selected.forEach(item=>{item.trashedAt=Date.now();item.hiddenFromShelf=true;});state.canUndoTrash=trashRemoved.length>0;}
  if(action==='undoTrash'){trashResult={ids:trashRemoved.map(item=>item.id)};for(const before of trashRemoved)Object.assign(state.items.find(item=>item.id===before.id),before);trashRemoved=[];state.canUndoTrash=false;}
  if(action==='copy'&&!payload.keepOpen||action==='paste'||action==='hide')state.windowVisible=false;
  if(action==='show'){state.view='shelves';state.windowVisible=true;state.viewEvent={serial:String(commands.length)};}
  if(action==='library'||action==='settings'){state.view=action;state.windowVisible=true;}
  const output=clone(state);if(trashResult)output.result=trashResult;if(cleanupError)output.result={error:cleanupError};
  if(action==='saveImage'&&deferredImageBroadcast){const pending=deferredImageBroadcast;deferredImageBroadcast=null;pendingImageBroadcast=output;if(pending.surface)subscriber?.({surfaceOnly:true,windowVisible:true});}
  else subscriber?.(output);
  if(delayedReply?.action===action){const pending=delayedReply;delayedReply=null;await pending.promise;}
  return output;
 }};
 const context={window:{clipboardLine:api,addEventListener(name,listener){if(!listeners.has('window:'+name))listeners.set('window:'+name,[]);listeners.get('window:'+name).push(listener);}},document,HTMLElement:Element,HTMLTextAreaElement:TextArea,Image:FixtureImage,console,structuredClone,URL,Set,Date,JSON,Math,Number,String,requestAnimationFrame:fn=>queuedAnimationFrames?animationFrames.push(fn):fn(),setTimeout:fn=>{queueMicrotask(fn);return 1;},clearTimeout(){}};
 vm.createContext(context);vm.runInContext(fs.readFileSync(path.join(__dirname,'../locales.js'),'utf8'),context,{filename:'locales.js'});vm.runInContext(fs.readFileSync(path.join(__dirname,'../renderer.js'),'utf8'),context,{filename:'renderer.js'});
 async function ready(){await new Promise(setImmediate);}
 async function key(code,{ctrl=false,alt=false,shift=false,key,target,composing=false,keyCode=0}={}){const event={code,key:key||(/^Key/.test(code)?code.slice(3).toLowerCase():code==='Space'?' ':code),ctrlKey:ctrl,metaKey:false,altKey:alt,shiftKey:shift,repeat:false,isComposing:composing,keyCode,target:target||new Element(),preventDefault(){this.prevented=true;}};for(const listener of listeners.get('keydown')||[])await listener(event);await ready();return event;}
 async function click(action,extra={}){const target=new Element();target.dataset.action=action;Object.assign(target.dataset,extra);target.closest=selector=>selector==='[data-action]'?target:null;for(const listener of listeners.get('click')||[])listener({target,stopPropagation(){}});await ready();}
 async function pointer(type,x,y){const target=document.getElementById('markup-canvas');for(const listener of listeners.get(type)||[])listener({target,clientX:x,clientY:y,pointerId:1,shiftKey:false,preventDefault(){}});await ready();}
 async function input(id,value){const target=document.getElementById(id);target.value=value;target.selectionStart=value.length;for(const listener of listeners.get('input')||[])await listener({target});await ready();}
 async function change(id,value){const target=document.getElementById(id);target.value=value;for(const listener of listeners.get('change')||[])await listener({target});await ready();}
 return{async cardClick(id,{ctrl=false}={}){const card=new Element();card.dataset.itemId=id;card.closest=selector=>selector==='[data-item-id]'?card:null;for(const listener of listeners.get('click')||[])await listener({target:card,ctrlKey:ctrl,metaKey:false,shiftKey:false,stopPropagation(){}});await ready();},grid(columns){document.querySelectorAll=selector=>selector==='.library-grid > .card'?[...document.getElementById('app').innerHTML.matchAll(/<article class="[^"]*"[^>]*data-item-id="([^"]+)"/g)].map((match,index)=>({offsetTop:Math.floor(index/columns)*200,dataset:{itemId:match[1]}})):[];},editor(id){const node=document.getElementById(id);node.tagName='INPUT';node.matches=selector=>selector.includes('input');return node;},ready,key,input,change,click,pointer,async blur(){for(const listener of listeners.get('window:blur')||[])listener();await ready();},imageLoads,paintCalls,animationFrames,flushAnimationFrames(){for(const fn of animationFrames.splice(0))fn();},releaseInitialState(){releaseInitialState?.();},deferReply(action){let release;const promise=new Promise(resolve=>{release=resolve;});delayedReply={action,promise};return release;},deferImageBroadcast({surface=true}={}){deferredImageBroadcast={surface};},releaseImageBroadcast(){const next=pendingImageBroadcast;pendingImageBroadcast=null;if(next)subscriber?.(next);},failExportOnce(){exportFailures++;},failCleanupOnce(){cleanupFailures++;},failEditOnce(){editFailures++;},state,commands,nodes,image,text1,text2,link,api,get main(){return nodes.get('app').innerHTML;},get overlay(){return nodes.get('overlay-root').innerHTML;}};
}

function selectedCards(f){return [...f.main.matchAll(/<article class="([^"]*)"[^>]*data-item-id="([^"]+)"/g)].filter(match=>match[1].split(' ').includes('selected')).map(match=>match[2]);}
function activeKind(f){return f.main.match(/class="shelf active-shelf" data-shelf="([^"]+)"/)?.[1];}
function focusedCard(f){return [...f.main.matchAll(/<article class="([^"]*)"[^>]*data-item-id="([^"]+)"/g)].find(match=>match[1].split(' ').includes('focused'))?.[2];}
function navigationItems(f,{image=13,text=11,link=10}={}){let serial=0;const values={};for(const [kind,count]of Object.entries({image,text,link})){const source=f.state.items.find(value=>value.kind===kind);values[kind]=Array.from({length:count},(_,index)=>({...structuredClone(source),id:'10000000-0000-4000-8000-'+String(++serial).padStart(12,'0'),createdAt:10000-index,name:kind==='image'?'Navigation image '+index:'',text:kind==='text'?'Navigation text '+index:'',title:kind==='link'?'Navigation link '+index:'',url:kind==='link'?'https://example.com/navigation/'+index:''}));}return values;}

test('fresh shelves select only the first image; P pins it; Space previews it',async()=>{const f=fixture();await f.ready();assert.match(f.main,/card kind-image focused selected/);assert.deepEqual(selectedCards(f),[f.image]);await f.key('KeyP');assert.equal(f.state.items[0].pinned,true);await f.key('Space');assert.match(f.overlay,/id="preview-dialog"/);assert.match(f.overlay,/aria-label="Synthetic image"/);});

test('lightweight native toggles retain current content and reset to a single first-image selection',async()=>{
 const f=fixture();await f.ready();for(let index=0;index<8;index++){
  await f.key('ArrowDown');assert.equal(activeKind(f),'text');await f.key('ArrowRight');
  f.api.surface({view:'shelves',windowVisible:false});await f.ready();assert.deepEqual(selectedCards(f),[]);
  f.api.surface({view:'shelves',windowVisible:true});await f.ready();assert.equal(activeKind(f),'image');assert.deepEqual(selectedCards(f),[f.image]);assert.match(f.main,/Text two/);
 }
 f.api.emit({items:f.state.items.map(value=>value.id===f.text1?{...value,text:'Latest hidden edit'}:value)});await f.ready();f.api.surface({windowVisible:false});f.api.surface({windowVisible:true});await f.ready();await f.key('ArrowDown');await f.key('Space');assert.match(f.overlay,/Latest hidden edit/);assert.deepEqual(selectedCards(f),[f.text1]);
});

test('a lightweight toggle before the first full snapshot preserves the later visibility event',async()=>{
 const f=fixture({deferInitialState:true,initialVisible:false});f.api.surface({view:'shelves',windowVisible:true});f.releaseInitialState();await f.ready();assert.deepEqual(selectedCards(f),[f.image]);assert.equal(activeKind(f),'image');await f.key('Space');assert.match(f.overlay,/Synthetic image/);
 const hidden=fixture({deferInitialState:true,initialVisible:true});hidden.api.surface({view:'shelves',windowVisible:false});hidden.releaseInitialState();await hidden.ready();assert.deepEqual(selectedCards(hidden),[]);assert.equal(hidden.overlay,'');
});

test('lightweight native hide saves a dirty text preview before clearing it and reopening',async()=>{
 const f=fixture();await f.ready();await f.key('ArrowDown');await f.key('Space');await f.key('KeyE');await f.input('text-editor','Draft saved before lightweight hide');
 f.api.surface({view:'shelves',windowVisible:false});await f.ready();assert.equal(f.state.items.find(value=>value.id===f.text1).text,'Draft saved before lightweight hide');assert.equal(f.commands.filter(value=>value.action==='editText').length,1);assert.equal(f.overlay,'');
 f.api.surface({view:'shelves',windowVisible:true});await f.ready();assert.deepEqual(selectedCards(f),[f.image]);assert.equal(f.overlay,'');await f.key('ArrowDown');await f.key('Space');assert.match(f.overlay,/Draft saved before lightweight hide/);
});

test('new full content survives later lightweight visibility packets while an editor save is pending',async()=>{
 const f=fixture();await f.ready();await f.key('ArrowDown');await f.key('Space');await f.key('KeyE');const release=f.deferReply('editText');await f.input('text-editor','Saved pending draft');
 f.api.surface({view:'shelves',windowVisible:false});await f.ready();f.api.emit({items:f.state.items.map(value=>value.id===f.image?{...value,name:'Current image title',mediaUrl:'appmedia://media/'+f.image+'?v=new'}:value.id===f.text2?{...value,text:'Current second text'}:value),libraryRevision:7});
 f.api.surface({view:'shelves',windowVisible:true,libraryRevision:7,viewEvent:{serial:'after-pending-save',selectId:f.text2,kind:'text',preview:true}});await f.ready();release();await f.ready();
 assert.match(f.main,/Current image title/);assert.match(f.main,new RegExp('appmedia://media/'+f.image+'\\?v=new'));assert.match(f.overlay,/Current second text/);assert.doesNotMatch(f.overlay,/id="text-editor"/);assert.equal(f.state.items.find(value=>value.id===f.text1).text,'Saved pending draft');assert.equal(f.state.windowVisible,true);assert.deepEqual(selectedCards(f),[f.text2]);
});

test('an initial library older than a queued lightweight revision is refreshed before it is shown',async()=>{
 const f=fixture({deferInitialState:true,initialVisible:false});f.state.libraryRevision=2;f.state.items=f.state.items.map(value=>value.id===f.image?{...value,name:'Current bootstrap image'}:value);f.api.surface({view:'shelves',windowVisible:true,libraryRevision:2});f.releaseInitialState();await f.ready();
 // The fresh API read also uses the controllable initial-state gate.
 f.releaseInitialState();await f.ready();assert.match(f.main,/Current bootstrap image/);assert.deepEqual(selectedCards(f),[f.image]);assert.equal(activeKind(f),'image');
});

test('preview arrows move across shelf kinds, S keeps preview on neighbor, Backspace restores',async()=>{const f=fixture();await f.ready();await f.key('Space');await f.key('ArrowDown');assert.match(f.overlay,/aria-label="Text one"/);await f.key('KeyS');assert.match(f.overlay,/aria-label="Text two"/);assert.ok(f.state.items.find(item=>item.id===f.text1).trashedAt);await f.key('Backspace');assert.match(f.overlay,/aria-label="Text one"/);assert.equal(f.state.items.find(item=>item.id===f.text1).trashedAt,null);});

test('removing the final preview item keeps an empty Undo view and Backspace restores that exact item',async()=>{
 for(const pinned of [false,true]){
  const f=fixture();await f.ready();f.api.emit({items:[{...f.state.items[0],pinned}]});await f.ready();await f.key('Space');await f.key('KeyS');
  assert.match(f.overlay,/id="preview-dialog"/);assert.match(f.overlay,/empty-preview/);assert.match(f.overlay,/data-action="undo"/);
  const before=f.commands.length;await f.key('KeyC',{ctrl:true});await f.key('KeyP');assert.equal(f.commands.length,before,'empty preview must not copy or mutate its removed item');
  await f.key('Backspace');assert.match(f.overlay,/aria-label="Synthetic image"/);assert.doesNotMatch(f.overlay,/empty-preview/);assert.deepEqual(selectedCards(f),[f.image]);
  assert.equal(f.state.items[0].trashedAt,null);assert.equal(f.state.items[0].hiddenFromShelf,false);
  await f.key('KeyS');assert.match(f.overlay,/empty-preview/);await f.key('Escape');assert.equal(f.overlay,'');assert.equal(f.state.windowVisible,true);
 }
});

test('preview CtrlC keeps open; Enter copies exact current item and dismisses',async()=>{const f=fixture();await f.ready();await f.key('Space');await f.key('ArrowDown');await f.key('KeyC',{ctrl:true});assert.equal(f.commands.at(-1).action,'copy');assert.equal(f.commands.at(-1).payload.keepOpen,true);assert.match(f.overlay,/id="preview-dialog"/);await f.key('Enter');assert.equal(f.commands.at(-1).payload.ids[0],f.text1);assert.equal(f.commands.at(-1).payload.keepOpen,false);assert.equal(f.state.windowVisible,false);assert.equal(f.overlay,'');});

test('L opens Library; CtrlK action search closes with Escape',async()=>{const f=fixture();await f.ready();await f.key('KeyL');assert.equal(f.state.view,'library');assert.match(f.main,/Library results/);await f.key('KeyK',{ctrl:true});assert.match(f.overlay,/Search actions/);await f.key('Escape');assert.equal(f.overlay,'');});

test('AltP sequential naming saves one then advances and Escape leaves remaining item unchanged',async()=>{const f=fixture();await f.ready();await f.key('Tab');await f.key('KeyA',{ctrl:true});await f.key('KeyP',{alt:true});assert.match(f.overlay,/1 \/ 2/);await f.input('name-input','First named note');await f.key('Enter');assert.equal(f.state.items.find(item=>item.id===f.text1).name,'First named note');assert.equal(f.state.items.find(item=>item.id===f.text1).pinned,true);assert.match(f.overlay,/2 \/ 2/);await f.key('Escape');assert.equal(f.state.items.find(item=>item.id===f.text2).name,'');assert.equal(f.state.items.find(item=>item.id===f.text2).pinned,false);});

test('ShiftS searches enabled rows and native reopen resets to only the first image',async()=>{const f=fixture();await f.ready();await f.key('KeyS',{shift:true});await f.input('search-input','Text two');assert.match(f.main,/Text two/);assert.doesNotMatch(f.main,/Text one/);await f.key('Escape');await f.key('Tab');await f.key('ArrowRight');assert.match(f.main,/card kind-text focused selected[^>]*data-item-id="00000000-0000-4000-8000-000000000003"/);await f.key('Enter');await f.api.command('show');await f.ready();assert.equal(activeKind(f),'image');assert.deepEqual(selectedCards(f),[f.image]);});


test('Settings retries pending deletion cleanup without clearing failure or deleting another record',async()=>{const f=fixture();await f.ready();await f.api.command('settings');await f.ready();assert.doesNotMatch(f.main,/data-action="retry-cleanup"/);const original=f.state.items.map(item=>item.id);f.state.needsDeletionCleanup=true;await f.api.command('settings');await f.ready();assert.match(f.main,/data-action="retry-cleanup"/);f.failCleanupOnce();await f.click('retry-cleanup');assert.equal(f.commands.at(-1).action,'cleanup');assert.deepEqual(f.commands.at(-1).payload,{});assert.equal(f.state.needsDeletionCleanup,true);assert.match(f.main,/data-action="retry-cleanup"/);assert.deepEqual(f.state.items.map(item=>item.id),original);await f.click('retry-cleanup');assert.equal(f.state.needsDeletionCleanup,false);assert.doesNotMatch(f.main,/data-action="retry-cleanup"/);assert.deepEqual(f.state.items.map(item=>item.id),original);});


test('native Settings state closes the screenshot crop preview instead of covering Settings',async()=>{const f=fixture();await f.ready();f.api.emit({viewEvent:{serial:'synthetic-capture',selectId:f.image,kind:'image',preview:true,crop:true}});await f.ready();assert.match(f.overlay,/id="preview-dialog"/);assert.match(f.overlay,/id="markup-canvas"/);await f.api.command('settings');await f.ready();assert.equal(f.overlay,'');assert.match(f.main,/class="settings-main"/);assert.match(f.main,/data-setting="theme"/);});

test('native view transition saves the current text draft once before clearing preview',async()=>{const f=fixture();await f.ready();await f.key('Tab');await f.key('Space');await f.key('KeyE');await f.input('text-editor','Edited before native Settings');await f.api.command('settings');await f.ready();assert.equal(f.state.items.find(item=>item.id===f.text1).text,'Edited before native Settings');assert.equal(f.commands.filter(command=>command.action==='editText').length,1);assert.equal(f.overlay,'');assert.match(f.main,/class="settings-main"/);});

test('failed native transition retains text draft until a successful explicit retry',async()=>{const f=fixture();await f.ready();await f.key('Tab');await f.key('Space');await f.key('KeyE');f.failEditOnce();f.failEditOnce();await f.input('text-editor','Keep this unsaved draft');await f.api.command('settings');await f.ready();assert.match(f.overlay,/id="text-editor"/);assert.match(f.overlay,/Keep this unsaved draft/);assert.equal(f.state.items.find(item=>item.id===f.text1).text,'Text one');assert.doesNotMatch(f.main,/class="settings-main"/);await f.click('finish-text');assert.equal(f.state.items.find(item=>item.id===f.text1).text,'Keep this unsaved draft');assert.equal(f.overlay,'');assert.match(f.main,/class="settings-main"/);});

test('native hide clears clean preview and does not leave it on the next opening',async()=>{const f=fixture();await f.ready();await f.key('Space');assert.match(f.overlay,/id="preview-dialog"/);await f.api.command('hide');await f.ready();assert.equal(f.overlay,'');await f.api.command('show');await f.ready();assert.equal(f.overlay,'');});


test('editor requests anonymous CORS before loading managed original',async()=>{const f=fixture();await f.ready();await f.key('Space');await f.key('KeyC');assert.equal(f.imageLoads.length,1);assert.equal(f.imageLoads[0].crossOrigin,'anonymous');assert.match(f.imageLoads[0].url,/\/original$/);});

test('canvas export rejection retains dirty crop and explicit Enter retry saves it',async()=>{const f=fixture();await f.ready();await f.key('Space');await f.key('KeyC');await f.pointer('pointerdown',60,30);await f.pointer('pointermove',500,150);await f.pointer('pointerup',500,150);f.failExportOnce();await f.key('Enter');assert.match(f.overlay,/id="markup-canvas"/);assert.equal(f.commands.filter(command=>command.action==='saveImage').length,0);assert.match(f.nodes.get('toast').textContent,/Image changes could not be saved/);await f.key('Enter');assert.doesNotMatch(f.overlay,/id="markup-canvas"/);assert.deepEqual(f.state.items.find(item=>item.id===f.image).crop,{x:60,y:30,width:440,height:120});});

for(const ordering of ['broadcast before reply','reply before broadcast','unrelated surface before reply'])test('preview crop undo and redo survive '+ordering,async()=>{
 const f=fixture({imageDocument:true});await f.ready();await f.key('Space');await f.key('KeyC');await f.pointer('pointerdown',60,30);await f.pointer('pointermove',500,150);await f.pointer('pointerup',500,150);
 if(ordering!=='broadcast before reply')f.deferImageBroadcast({surface:ordering==='unrelated surface before reply'});
 await f.key('Enter');assert.doesNotMatch(f.overlay,/id="markup-canvas"/);f.releaseImageBroadcast();await f.ready();
 const crop={x:60,y:30,width:440,height:120};assert.deepEqual(f.state.items.find(item=>item.id===f.image).crop,crop);
 await f.key('KeyZ',{ctrl:true});assert.equal(f.commands.filter(command=>command.action==='saveImage').length,2);assert.equal(f.state.items.find(item=>item.id===f.image).crop,null);assert.doesNotMatch(f.overlay,/id="markup-canvas"/);
 await f.key('KeyZ',{ctrl:true,shift:true});assert.equal(f.commands.filter(command=>command.action==='saveImage').length,3);assert.deepEqual(f.state.items.find(item=>item.id===f.image).crop,crop);
});

test('an external same-ID image edit invalidates acknowledged preview undo history',async()=>{
 const f=fixture({imageDocument:true});await f.ready();await f.key('Space');await f.key('KeyC');await f.pointer('pointerdown',60,30);await f.pointer('pointermove',500,150);await f.pointer('pointerup',500,150);f.deferImageBroadcast();await f.key('Enter');f.releaseImageBroadcast();await f.ready();
 const external={x:10,y:20,width:80,height:90};f.api.emit({items:f.state.items.map(value=>value.id===f.image?{...value,crop:external,mediaUrl:value.mediaUrl+'?v=external'}:value)});await f.ready();
 await f.key('KeyZ',{ctrl:true});assert.equal(f.commands.filter(command=>command.action==='saveImage').length,1);assert.deepEqual(f.state.items.find(item=>item.id===f.image).crop,external);
});

test('canvas export failure blocks native Settings until explicit Save succeeds',async()=>{const f=fixture();await f.ready();await f.key('Space');await f.key('KeyC');await f.pointer('pointerdown',60,30);await f.pointer('pointermove',500,150);await f.pointer('pointerup',500,150);f.failExportOnce();await f.api.command('settings');await f.ready();assert.match(f.overlay,/id="markup-canvas"/);assert.doesNotMatch(f.main,/class="settings-main"/);await f.click('save-image');assert.equal(f.overlay,'');assert.match(f.main,/class="settings-main"/);assert.deepEqual(f.state.items.find(item=>item.id===f.image).crop,{x:60,y:30,width:440,height:120});});

test('Tab saves dirty image crop before switching the open preview; Enter copies the visible text',async()=>{
 const f=fixture();await f.ready();await f.key('Space');await f.key('KeyC');
 await f.pointer('pointerdown',60,30);await f.pointer('pointermove',500,150);await f.pointer('pointerup',500,150);
 await f.key('Tab');
 assert.deepEqual(f.state.items.find(item=>item.id===f.image).crop,{x:60,y:30,width:440,height:120});
 assert.equal(f.commands.filter(command=>command.action==='saveImage').length,1);
 assert.match(f.overlay,/aria-label="Text one"/);
 assert.doesNotMatch(f.overlay,/editing-toolbar|id="markup-canvas"/);
 await f.key('Enter');
 assert.equal(f.commands.at(-1).action,'copy');
 assert.deepEqual(f.commands.at(-1).payload.ids,[f.text1]);
 assert.equal(f.state.windowVisible,false);assert.equal(f.overlay,'');
 assert.equal(f.commands.filter(command=>command.action==='saveImage').length,1);
});

test('failed crop export aborts Tab shelf switching and keeps the draft available for retry',async()=>{
 const f=fixture();await f.ready();await f.key('Space');await f.key('KeyC');
 await f.pointer('pointerdown',60,30);await f.pointer('pointermove',500,150);await f.pointer('pointerup',500,150);
 f.failExportOnce();await f.key('Tab');
 assert.match(f.overlay,/aria-label="Synthetic image"/);
 assert.match(f.overlay,/editing-toolbar/);assert.match(f.overlay,/id="markup-canvas"/);
 assert.match(f.main,/card kind-image focused selected/);
 assert.equal(f.commands.filter(command=>['saveImage','copy'].includes(command.action)).length,0);
 assert.equal(f.state.items.find(item=>item.id===f.image).crop,undefined);
 await f.key('Tab');
 assert.deepEqual(f.state.items.find(item=>item.id===f.image).crop,{x:60,y:30,width:440,height:120});
 assert.match(f.overlay,/aria-label="Text one"/);
 assert.doesNotMatch(f.overlay,/editing-toolbar|id="markup-canvas"/);
});

test('Settings hides browsing selection and keyboard hints while Library retains its footer',async()=>{
 const f=fixture();await f.ready();await f.key('KeyP');await f.api.command('library');await f.ready();
 assert.match(f.main,/class="statusbar"/);assert.match(f.main,/1 selected/);
 await f.api.command('settings');await f.ready();
 assert.match(f.main,/class="settings-main"/);
 assert.doesNotMatch(f.main,/class="statusbar"|class="key-legend"|1 selected/);
});


test('Settings browsing keys do not pin, copy or paste the last shelf selection',async()=>{const f=fixture();await f.ready();await f.api.command('settings');await f.ready();await f.key('KeyP');await f.key('Enter');await f.key('Enter',{ctrl:true});assert.equal(f.state.items.find(item=>item.id===f.image).pinned,false);assert.equal(f.commands.filter(command=>['pin','copy','paste'].includes(command.action)).length,0);await f.key('KeyK',{ctrl:true});assert.match(f.overlay,/Search actions/);});

test('fresh opening skips an empty enabled image shelf so Space and Enter operate on the first text',async()=>{
 const f=fixture();await f.ready();
 f.api.emit({items:f.state.items.filter(value=>value.kind!=='image')});
 await f.api.command('show');await f.ready();
 assert.match(f.main,/card kind-text focused selected/);
 await f.key('Space');assert.match(f.overlay,/aria-label="Text one"/);
 await f.key('Enter');
 assert.equal(f.commands.at(-1).action,'copy');
 assert.deepEqual(f.commands.at(-1).payload.ids,[f.text1]);
 assert.equal(f.state.windowVisible,false);
});

test('fresh focus skips empty or disabled kinds and safely handles every shelf empty',async()=>{
 const f=fixture();await f.ready();
 f.api.emit({items:f.state.items.filter(value=>value.kind!=='image'),settings:{...f.state.settings,visibleKinds:['image','link']}});
 await f.api.command('show');await f.ready();
 assert.match(f.main,/card kind-link focused selected/);
 await f.key('Space');assert.match(f.overlay,/aria-label="Reference link"/);
 await f.key('Escape');
 f.api.emit({items:[]});await f.api.command('show');await f.ready();
 const commands=f.commands.length;await f.key('Space');await f.key('Enter');
 assert.equal(f.overlay,'');assert.equal(f.commands.length,commands);
});

test('closed preview arrows cross shelves by full item column, clamp without wrapping, and keep Left/Right horizontal',async()=>{
 const f=fixture();await f.ready();const values=navigationItems(f);f.api.emit({items:Object.values(values).flat()});await f.ready();
 await f.key('ArrowRight',{ctrl:true});assert.equal(focusedCard(f),values.image[12].id);
 await f.key('ArrowDown');assert.equal(activeKind(f),'text');assert.deepEqual(selectedCards(f),[values.text[10].id]);
 await f.key('ArrowDown');assert.equal(activeKind(f),'link');assert.deepEqual(selectedCards(f),[values.link[9].id]);
 await f.key('ArrowDown');assert.equal(focusedCard(f),values.link[9].id);
 await f.key('ArrowUp');assert.equal(activeKind(f),'text');assert.deepEqual(selectedCards(f),[values.text[9].id]);
 await f.key('ArrowUp');assert.equal(activeKind(f),'image');assert.deepEqual(selectedCards(f),[values.image[9].id]);
 await f.key('ArrowUp');assert.equal(focusedCard(f),values.image[9].id);
 await f.key('ArrowLeft');assert.equal(activeKind(f),'image');assert.equal(focusedCard(f),values.image[8].id);
 await f.key('ArrowRight');assert.equal(focusedCard(f),values.image[9].id);assert.equal(f.overlay,'');
});

test('vertical navigation skips filtered empty and hidden shelves and Space/Enter use the destination',async()=>{
 const f=fixture();await f.ready();await f.click('pinned-kind',{kind:'text'});await f.click('activate-shelf',{kind:'image'});
 await f.key('ArrowDown');assert.equal(activeKind(f),'link');assert.deepEqual(selectedCards(f),[f.link]);
 await f.key('Space');assert.match(f.overlay,/aria-label="Reference link"/);
 await f.key('ArrowUp');assert.match(f.overlay,/aria-label="Synthetic image"/);assert.deepEqual(selectedCards(f),[f.image]);
 await f.key('Escape');await f.key('KeyL',{shift:true});await f.key('ArrowDown');assert.equal(activeKind(f),'image');assert.deepEqual(selectedCards(f),[f.image]);
 assert.doesNotMatch(f.main,/data-shelf="link"/);await f.key('Enter');assert.deepEqual(f.commands.at(-1).payload.ids,[f.image]);assert.equal(f.state.windowVisible,false);
});

test('row toggles preserve the active batch and enabling other shelves adds no selection',async()=>{
 const f=fixture();await f.ready();await f.key('ArrowDown');await f.key('ArrowRight');await f.key('KeyA',{ctrl:true});
 assert.deepEqual(selectedCards(f),[f.text1,f.text2]);
 for(const action of ['KeyL','KeyL','KeyI','KeyI']){await f.key(action,{shift:true});assert.equal(activeKind(f),'text');assert.equal(focusedCard(f),f.text2);assert.deepEqual(selectedCards(f),[f.text1,f.text2]);}
 await f.key('KeyT',{shift:true});assert.equal(activeKind(f),'image');assert.deepEqual(selectedCards(f),[f.image]);
 await f.key('KeyT',{shift:true});assert.deepEqual(selectedCards(f),[f.image]);assert.equal(activeKind(f),'image');
});

test('fresh native reveal clears stale search, quick pages and selection then prefers images',async()=>{
 const f=fixture();await f.ready();const values=navigationItems(f);f.api.emit({items:Object.values(values).flat()});await f.ready();
 await f.key('ArrowRight',{alt:true});assert.notEqual(focusedCard(f),values.image[0].id);
 await f.key('KeyS',{shift:true});await f.input('search-input','Navigation text 10');assert.match(f.main,/Navigation text 10/);
 await f.api.command('hide');await f.api.command('show');await f.ready();
 assert.equal(activeKind(f),'image');assert.deepEqual(selectedCards(f),[values.image[0].id]);assert.doesNotMatch(f.main,/search-hud|search-summary/);
 await f.key('Digit1');assert.equal(focusedCard(f),values.image[0].id);
 await f.key('ArrowDown');assert.deepEqual(selectedCards(f),[values.text[0].id]);
 await f.key('Space');assert.match(f.overlay,/aria-label="Navigation text 0"/);await f.key('Enter');assert.deepEqual(f.commands.at(-1).payload.ids,[values.text[0].id]);
});

test('hidden or filtered images use first visible nonempty shelf and reopening never keeps a text default when images return',async()=>{
 const f=fixture();await f.ready();await f.key('KeyI',{shift:true});assert.equal(activeKind(f),'text');assert.deepEqual(selectedCards(f),[f.text1]);
 await f.api.command('hide');await f.api.command('show');await f.ready();assert.equal(activeKind(f),'text');assert.deepEqual(selectedCards(f),[f.text1]);
 await f.key('KeyI',{shift:true});assert.equal(activeKind(f),'text');assert.deepEqual(selectedCards(f),[f.text1]);
 await f.api.command('hide');await f.api.command('show');await f.ready();assert.equal(activeKind(f),'image');assert.deepEqual(selectedCards(f),[f.image]);
 await f.click('pinned-kind',{kind:'image'});await f.api.command('hide');await f.api.command('show');await f.ready();assert.equal(activeKind(f),'text');assert.deepEqual(selectedCards(f),[f.text1]);
});

test('native search typing stays in its editor and Shift arrows extend only the current row',async()=>{
 const f=fixture();await f.ready();await f.key('ArrowDown');await f.key('ArrowDown',{shift:true});assert.equal(activeKind(f),'text');assert.deepEqual(selectedCards(f),[f.text1,f.text2]);
 await f.key('KeyS',{shift:true});const editor=f.nodes.get('search-input');editor.matches=selector=>selector.includes('input');
 const before=f.commands.length;for(const code of ['Space','ArrowLeft','ArrowRight'])assert.equal((await f.key(code,{target:editor})).prevented,undefined);
 assert.equal(f.commands.length,before);assert.equal(activeKind(f),'text');assert.equal(f.overlay,'');
 await f.input('search-input','Text');await f.key('Enter',{target:editor});assert.equal(activeKind(f),'text');assert.deepEqual(selectedCards(f),[f.text1]);
 await f.key('ArrowDown');assert.equal(activeKind(f),'text','Empty result shelves do not wrap');
});

test('global native search survives a hidden resize broadcast before the same event becomes visible',async()=>{
 const f=fixture();await f.ready();await f.api.command('hide');await f.ready();
 const viewEvent={search:true,serial:'global-search-before-window-show'};
 f.api.emit({windowVisible:false,viewEvent});await f.ready();
 assert.doesNotMatch(f.main,/class="search-hud"/);assert.deepEqual(selectedCards(f),[]);
 f.api.emit({windowVisible:true,viewEvent});await f.ready();
 assert.match(f.main,/class="search-hud"/);assert.deepEqual(selectedCards(f),[f.image]);
 f.api.emit({windowVisible:true,viewEvent});await f.ready();assert.match(f.main,/class="search-hud"/);
 await f.key('Escape');assert.doesNotMatch(f.main,/class="search-hud"/);
 f.api.emit({windowVisible:true,viewEvent});await f.ready();
 assert.doesNotMatch(f.main,/class="search-hud"/,'An unchanged broadcast must not reopen a dismissed search');
});

test('native image preview and crop event wait until the hidden window is shown',async()=>{
 const f=fixture();await f.ready();await f.api.command('hide');await f.ready();
 const viewEvent={selectId:f.image,kind:'image',preview:true,crop:true,serial:'capture-before-window-show'};
 f.api.emit({windowVisible:false,viewEvent});await f.ready();assert.equal(f.overlay,'');assert.equal(f.imageLoads.length,0);
 f.api.emit({windowVisible:true,viewEvent});await f.ready();
 assert.match(f.overlay,/id="preview-dialog"/);assert.match(f.overlay,/id="markup-canvas"/);assert.equal(f.imageLoads.length,1);
 f.api.emit({windowVisible:true,viewEvent});await f.ready();assert.equal(f.imageLoads.length,1,'The same event must not recreate its editor');
});

test('late Enter-copy response cannot clear the reopened selection or preview',async()=>{
 const f=fixture();await f.ready();await f.key('ArrowDown');await f.key('Space');assert.match(f.overlay,/aria-label="Text one"/);
 const release=f.deferReply('copy'),copying=f.key('Enter');await f.ready();
 assert.equal(f.state.windowVisible,false);assert.equal(f.overlay,'');
 await f.api.command('show');await f.ready();assert.deepEqual(selectedCards(f),[f.image]);
 await f.key('ArrowDown');await f.key('Space');assert.match(f.overlay,/aria-label="Text one"/);
 release();await copying;
 assert.equal(f.state.windowVisible,true);assert.deepEqual(selectedCards(f),[f.text1]);assert.match(f.overlay,/aria-label="Text one"/);
 await f.key('ArrowDown');assert.match(f.overlay,/aria-label="Reference link"/);assert.deepEqual(selectedCards(f),[f.link]);
});

test('late Hide response cannot replace a newer native global search opening',async()=>{
 const f=fixture();await f.ready();const release=f.deferReply('hide'),hiding=f.key('Escape');await f.ready();
 assert.equal(f.state.windowVisible,false);
 f.api.emit({windowVisible:true,viewEvent:{search:true,serial:'search-after-pending-hide'}});await f.ready();assert.match(f.main,/class="search-hud"/);
 release();await hiding;
 assert.match(f.main,/class="search-hud"/);assert.deepEqual(selectedCards(f),[f.image]);
});

test('shared macOS/Windows shelf contract runs through actual renderer handlers',async()=>{
 const contractFile=path.resolve(__dirname,'../../contracts/shelf-behavior.json'),raw=fs.readFileSync(contractFile),contract=JSON.parse(raw);
 assert.equal(contract.schemaVersion,1);assert.equal(contract.contractId,'clipboardline.shelves.v1');
 const observations=[],errors=[];
 for(const scenario of contract.scenarios){
  const f=fixture();await f.ready();const aliases=new Map(),values=contract.itemSets[scenario.itemSet].map((entry,index)=>{
   const id='20000000-0000-4000-8000-'+String(index+1).padStart(12,'0');aliases.set(id,entry.id);
   const source=f.state.items.find(value=>value.kind===entry.kind);
   return{...structuredClone(source),id,createdAt:10000-index,name:entry.kind==='image'?entry.text:'',text:entry.kind==='text'?entry.text:'',title:entry.kind==='link'?entry.text:'',url:entry.kind==='link'?'https://example.com/contract/'+entry.id:''};
  });
  f.api.emit({items:values,settings:{...f.state.settings,visibleKinds:scenario.visibleKinds}});await f.ready();
  for(const kind of scenario.pinnedOnlyKinds||[])await f.click('pinned-kind',{kind});
  await f.api.command('hide');await f.ready();
  for(let index=0;index<scenario.steps.length;index++){
   const step=scenario.steps[index];const editor=f.nodes.get('search-input');if(editor)editor.matches=selector=>selector.includes('input');
   const searchEditing=/class="search-hud"/.test(f.main);
   if(step.action==='open')await f.api.command('show');
   else if(step.action==='close')await f.api.command('hide');
   else if(step.action==='remap'){const localShortcuts={...f.state.settings.localShortcuts};if(step.key===null)delete localShortcuts[step.binding];else localShortcuts[step.binding]=step.key==='KeyX'?'X':step.key;f.api.emit({settings:{...f.state.settings,localShortcuts}});}
   else if(step.action==='key')await f.key(step.code,searchEditing?{target:editor}:{});
   else if(['up','down','left','right'].includes(step.action))await f.key({up:'ArrowUp',down:'ArrowDown',left:'ArrowLeft',right:'ArrowRight'}[step.action],searchEditing?{target:editor}:{});
   else if(step.action==='toggle')await f.key({image:'KeyI',text:'KeyT',link:'KeyL'}[step.kind],{shift:true});
   else if(step.action==='openSearch')await f.key('KeyS',{shift:true});
   else if(step.action==='finishSearch')await f.key('Enter',{target:editor});
   else throw new Error('Unsupported shared contract action: '+step.action);
   await f.ready();
   const actual={activeKind:activeKind(f),focused:aliases.get(focusedCard(f))||null,selected:selectedCards(f).map(id=>aliases.get(id)||id).sort(),visibleKinds:[...f.main.matchAll(/<section class="shelf(?: active-shelf)?\s*" data-shelf="([^"]+)"/g)].map(match=>match[1]),searchEditing:/class="search-hud"/.test(f.main),uploaded:f.state.items.filter(value=>value.uploadedUrl).map(value=>aliases.get(value.id)||value.id).sort()};
   observations.push({scenarioId:scenario.id,step:index,actual});
   try{assert.deepEqual(actual,step.expect);}catch(error){errors.push(scenario.id+' step '+index+': '+error.message);}
  }
 }
 if(process.env.CLIPBOARDLINE_PARITY_REPORT){
  const revision=process.env.GITHUB_SHA||execFileSync('git',['rev-parse','HEAD'],{cwd:path.resolve(__dirname,'../..'),encoding:'utf8'}).trim();
  const implementationSHA256=crypto.createHash('sha256').update(fs.readFileSync(path.resolve(__dirname,'../renderer.js'))).digest('hex');
  const report={schemaVersion:1,contractId:contract.contractId,platform:'windows',hostPlatform:process.platform,mode:'renderer',sourceRevision:revision,contractSHA256:crypto.createHash('sha256').update(raw).digest('hex'),implementationSHA256,implementationFiles:{'windows/renderer.js':implementationSHA256},observations,passed:errors.length===0,errors};
  fs.mkdirSync(path.dirname(path.resolve(process.env.CLIPBOARDLINE_PARITY_REPORT)),{recursive:true});fs.writeFileSync(process.env.CLIPBOARDLINE_PARITY_REPORT,JSON.stringify(report,null,2)+'\n');
 }
 assert.deepEqual(errors,[]);
});

test('folder menu arrows retain folder operations and Enter creates a subfolder under the chosen folder',async()=>{
 const f=fixture();await f.ready();const folderId='10000000-0000-4000-8000-000000000000';
 f.api.emit({folders:[{id:folderId,name:'Chosen folder',parentId:null}]});
 await f.api.command('library');await f.click('folder-menu',{folder:folderId});
 assert.match(f.overlay,/Rename folder/);assert.match(f.overlay,/New subfolder/);assert.match(f.overlay,/Remove folder/);
 await f.key('ArrowDown');
 assert.match(f.overlay,/dialog-option selected[^>]*data-action="new-subfolder"/);
 assert.doesNotMatch(f.overlay,/Search actions|execute-command/);
 await f.key('Enter');assert.match(f.overlay,/New folder/);
 await f.input('simple-input','Child folder');await f.key('Enter');
 assert.equal(f.commands.at(-1).action,'createFolder');
 assert.deepEqual(f.commands.at(-1).payload,{name:'Child folder',parentId:folderId});
 assert.equal(f.commands.filter(command=>['copy','paste','pin','remove'].includes(command.action)).length,0);
});

test('folder menu Enter renames its folder and Escape cancels remaining folder actions',async()=>{
 const f=fixture();await f.ready();const folderId='10000000-0000-4000-8000-000000000000';
 f.api.emit({folders:[{id:folderId,name:'Chosen folder',parentId:null}]});
 await f.api.command('library');await f.click('folder-menu',{folder:folderId});
 await f.key('Enter');assert.match(f.overlay,/Rename folder/);
 await f.input('simple-input','Renamed folder');await f.key('Enter');
 assert.equal(f.commands.at(-1).action,'renameFolder');
 assert.deepEqual(f.commands.at(-1).payload,{id:folderId,name:'Renamed folder'});
 await f.click('folder-menu',{folder:folderId});await f.key('ArrowDown');
 const commands=f.commands.length;await f.key('Escape');
 assert.equal(f.overlay,'');assert.equal(f.commands.length,commands);
});

test('folder menu removal requires its confirmation and never removes an item instead',async()=>{
 const f=fixture();await f.ready();const folderId='10000000-0000-4000-8000-000000000000';
 f.api.emit({folders:[{id:folderId,name:'Chosen folder',parentId:null}]});
 await f.api.command('library');await f.click('folder-menu',{folder:folderId});
 await f.key('ArrowDown');await f.key('ArrowDown');
 assert.match(f.overlay,/dialog-option selected[^>]*data-action="remove-folder"/);
 await f.key('Enter');assert.match(f.overlay,/Item content remains in the library/);
 assert.equal(f.commands.filter(command=>command.action==='removeFolder').length,0);
 await f.key('Enter');assert.equal(f.commands.at(-1).action,'removeFolder');
 assert.deepEqual(f.commands.at(-1).payload,{id:folderId});
 assert.equal(f.commands.filter(command=>['copy','paste','pin','remove','trash'].includes(command.action)).length,0);
});


test('late initial hidden state cannot replace a newer visible global search',async()=>{
 const f=fixture({deferInitialState:true,initialVisible:false});
 f.api.emit({windowVisible:true,viewEvent:{serial:'initial-global-search',search:true}});await f.ready();
 assert.match(f.main,/id="search-input"/);assert.deepEqual(selectedCards(f),[f.image]);
 f.releaseInitialState();await f.ready();
 assert.match(f.main,/id="search-input"/);assert.deepEqual(selectedCards(f),[f.image]);
});


test('custom shortcut overrides win over newly introduced defaults and hints show only the winning binding',async()=>{
 const f=fixture();await f.ready();await f.key('ArrowDown');await f.key('ArrowRight');
 f.api.emit({settings:{...f.state.settings,localShortcuts:{previous:'P'}}});await f.ready();
 await f.key('KeyP');assert.equal(focusedCard(f),f.text1);assert.equal(f.state.items.find(value=>value.id===f.text1).pinned,false);
 await f.key('KeyK',{ctrl:true});
 assert.match(f.overlay,/data-command="previous"[\s\S]*?<kbd>P<\/kbd>/);
 const pinRow=f.overlay.match(/<button[^>]*data-command="pin"[\s\S]*?<\/button>/)?.[0];assert.ok(pinRow);assert.doesNotMatch(pinRow,/<kbd>P(?: |<)/);assert.match(pinRow,/<kbd>Ctrl\+P<\/kbd>/);
 await f.key('Escape');await f.key('KeyP',{ctrl:true});assert.equal(f.state.items.find(value=>value.id===f.text1).pinned,true);
});

test('disabling or remapping copy, aliases, quick slots and range extension does not leave hardcoded keys active',async()=>{
 const f=fixture();await f.ready();await f.key('ArrowDown');
 f.api.emit({settings:{...f.state.settings,localShortcuts:{copy:'',pin:'',select2:'Q',extendNext:'Shift+J'}}});await f.ready();
 const before=f.commands.length;
 for(const [code,modifiers]of [['Enter',{}],['KeyC',{ctrl:true}],['KeyP',{}],['KeyP',{ctrl:true}]])await f.key(code,modifiers);
 assert.equal(f.commands.length,before);assert.equal(f.state.windowVisible,true);
 await f.key('KeyQ');assert.equal(focusedCard(f),f.text2);
 await f.key('ArrowLeft');await f.key('ArrowRight',{shift:true});assert.deepEqual(selectedCards(f),[f.text1],'Old Shift+Right binding is disabled after remapping');
 await f.key('KeyJ',{shift:true});assert.deepEqual(selectedCards(f),[f.text1,f.text2]);
 await f.key('ArrowLeft');await f.key('Digit2');assert.equal(focusedCard(f),f.text1,'Old number binding is disabled after remapping');
});

test('Library Backspace restores Library Trash when shelf undo has a custom binding',async()=>{
 const f=fixture();await f.ready();await f.key('KeyP');await f.key('KeyL');
 f.api.emit({settings:{...f.state.settings,localShortcuts:{undo:'U'}}});await f.ready();
 await f.key('KeyS');assert.ok(f.state.items.find(value=>value.id===f.image).trashedAt);await f.key('Backspace');assert.equal(f.state.items.find(value=>value.id===f.image).trashedAt,null);assert.equal(f.commands.filter(value=>value.action==='undo').length,0);assert.equal(f.commands.filter(value=>value.action==='undoTrash').length,1);
});

test('shortcut recorder rejects overlapping conflicts but allows a key owned by markup in a different context',async()=>{
 const f=fixture();await f.ready();await f.api.command('settings');await f.ready();await f.click('record-local',{keyAction:'pin'});
 await f.key('KeyS');await f.click('confirm-modal');assert.match(f.overlay,/Record shortcut/);assert.match(f.nodes.get('toast').textContent,/already used for Move to Trash/);
 assert.equal(f.state.settings.localShortcuts.pin,undefined);
 await f.key('KeyO');await f.click('confirm-modal');assert.equal(f.overlay,'');assert.equal(f.state.settings.localShortcuts.pin,'O');
 await f.api.command('show');await f.ready();await f.key('KeyO');assert.equal(f.state.items.find(value=>value.id===f.image).pinned,true);
 await f.key('Space');await f.key('KeyM');await f.key('KeyO');assert.match(f.overlay,/data-tool="ellipse" aria-pressed="true"/);
 await f.click('save-image');await f.api.command('settings');await f.click('reset-local-shortcuts');assert.deepEqual(f.state.settings.localShortcuts,{});
 await f.api.command('show');await f.key('KeyP',{ctrl:true});assert.equal(f.state.items.find(value=>value.id===f.image).pinned,false,'Reset restores the Ctrl+P alias');
});

test('remapped Actions works in native search but disabled Actions leaves editor typing alone',async()=>{
 const f=fixture();await f.ready();f.api.emit({settings:{...f.state.settings,localShortcuts:{actions:'Ctrl+J'}}});await f.ready();
 await f.key('KeyS',{shift:true});const editor=f.nodes.get('search-input');editor.matches=selector=>selector.includes('input');
 assert.equal((await f.key('KeyK',{ctrl:true,target:editor})).prevented,undefined);assert.equal(f.overlay,'');
 await f.key('KeyJ',{ctrl:true,target:editor});assert.match(f.overlay,/Search actions/);
 await f.key('Escape');f.api.emit({settings:{...f.state.settings,localShortcuts:{actions:''}}});await f.ready();
 assert.equal((await f.key('KeyK',{ctrl:true,target:editor})).prevented,undefined);assert.equal(f.overlay,'');
});

test('CtrlEnter finishes text and image editing without accidentally pasting; native field CtrlC is not intercepted',async()=>{
 const f=fixture();await f.ready();await f.key('ArrowDown');await f.key('Space');await f.key('KeyE');
 await f.input('text-editor','A retained edit');const editor=f.nodes.get('text-editor');editor.matches=selector=>selector.includes('textarea');
 assert.equal((await f.key('KeyC',{ctrl:true,target:editor})).prevented,undefined);
 await f.key('Enter',{ctrl:true,target:editor});assert.doesNotMatch(f.overlay,/id="text-editor"/);assert.equal(f.state.items.find(value=>value.id===f.text1).text,'A retained edit');
 assert.equal(f.commands.filter(value=>value.action==='paste').length,0);await f.key('ArrowUp');await f.key('KeyM');
 await f.key('Enter',{ctrl:true});assert.doesNotMatch(f.overlay,/id="markup-canvas"/);assert.match(f.overlay,/id="preview-dialog"/);assert.equal(f.commands.filter(value=>value.action==='paste').length,0);
 await f.key('Enter',{ctrl:true});assert.equal(f.commands.at(-1).action,'paste');assert.deepEqual(f.commands.at(-1).payload.ids,[f.image]);
});

test('text Finish editing can be remapped separately from paste and never consumes ordinary typing',async()=>{
 const f=fixture();await f.ready();await f.key('ArrowDown');await f.key('Space');await f.key('KeyE');
 f.api.emit({settings:{...f.state.settings,localShortcuts:{finishEditing:'Ctrl+D'}}});await f.ready();
 await f.input('text-editor','Remapped edit');const editor=f.nodes.get('text-editor');editor.matches=selector=>selector.includes('textarea');
 await f.key('Enter',{ctrl:true,target:editor});assert.match(f.overlay,/id="text-editor"/);assert.equal(f.commands.filter(value=>value.action==='paste').length,0);
 await f.key('KeyD',{ctrl:true,target:editor});assert.doesNotMatch(f.overlay,/id="text-editor"/);assert.equal(f.state.items.find(value=>value.id===f.text1).text,'Remapped edit');
});

test('action bar snapshots the focused member of a batch for Preview and keeps ordered IDs for batch naming',async()=>{
 const f=fixture();await f.ready();await f.key('ArrowDown');await f.key('ArrowRight',{shift:true});
 assert.equal(focusedCard(f),f.text2);assert.deepEqual(selectedCards(f),[f.text1,f.text2]);
 await f.key('KeyK',{ctrl:true});await f.input('modal-query','Preview');await f.key('Enter');assert.match(f.overlay,/aria-label="Text two"/);
 await f.key('Escape');await f.key('KeyK',{ctrl:true});await f.input('modal-query','Name and pin');await f.key('Enter');assert.match(f.overlay,/1 \/ 2/);await f.input('name-input','First batched note');await f.key('Enter');
 assert.equal(f.state.items.find(value=>value.id===f.text1).name,'First batched note');assert.match(f.overlay,/2 \/ 2/);
});

test('action bar exposes real navigation, image tools, Library views and Settings destinations without synthetic key presses',async()=>{
 const f=fixture();await f.ready();await f.key('KeyK',{ctrl:true});await f.input('modal-query','Marker');await f.key('Enter');assert.match(f.overlay,/id="markup-canvas"/);assert.match(f.overlay,/data-tool="marker" aria-pressed="true"/);
 await f.key('Enter',{ctrl:true});await f.key('KeyK',{ctrl:true});await f.input('modal-query','Next item');assert.match(f.overlay,/data-command="next"/);await f.key('Escape');await f.key('Escape');
 await f.key('KeyP');await f.key('KeyL');await f.key('KeyK',{ctrl:true});await f.input('modal-query','List view');await f.key('Enter');assert.match(f.main,/library-grid list/);
 await f.key('KeyK',{ctrl:true});await f.input('modal-query','Settings · History');await f.key('Enter');assert.match(f.main,/data-retention="text"/);assert.match(f.main,/data-retention="link"/);
});

test('action bar content search follows Library scope and disabled image commands cannot run on text',async()=>{
 const f=fixture();await f.ready();await f.key('ArrowDown');await f.key('KeyP');await f.key('KeyL');
 await f.key('KeyK',{ctrl:true});await f.input('modal-query','Search contents');await f.key('Enter');assert.equal(f.state.view,'library');assert.doesNotMatch(f.main,/search-hud/);
 await f.key('KeyK',{ctrl:true});await f.input('modal-query','Crop image');assert.match(f.overlay,/data-command="crop" disabled/);const before=f.commands.length;await f.key('Enter');assert.equal(f.commands.length,before);assert.doesNotMatch(f.overlay,/markup-canvas/);assert.match(f.overlay,/Search actions/);
});

test('crop Escape cancels direct crop to browsing while markup crop apply returns to the markup workspace',async()=>{
 const f=fixture();await f.ready();await f.key('Space');await f.key('KeyC');await f.pointer('pointerdown',60,30);await f.pointer('pointermove',500,150);await f.pointer('pointerup',500,150);
 await f.key('Escape');assert.doesNotMatch(f.overlay,/markup-canvas/);assert.match(f.overlay,/preview-dialog/);assert.equal(f.commands.filter(value=>value.action==='saveImage').length,0);
 await f.key('KeyM');await f.key('KeyC');await f.pointer('pointerdown',60,30);await f.pointer('pointermove',500,150);await f.pointer('pointerup',500,150);await f.key('Enter');
 assert.match(f.overlay,/markup-canvas/);assert.match(f.overlay,/data-tool="select" aria-pressed="true"/);assert.deepEqual(f.state.items.find(value=>value.id===f.image).crop,{x:60,y:30,width:440,height:120});
});

test('Settings records and directly disables optional global Library and copy-latest-image shortcuts',async()=>{
 const f=fixture();await f.ready();await f.api.command('settings');await f.ready();await f.click('settings-tab',{tab:'shortcuts'});
 assert.match(f.main,/data-action="record-global" data-key-action="library"/);assert.match(f.main,/data-action="record-global" data-key-action="copyLatest"/);
 await f.click('record-global',{keyAction:'library'});await f.key('KeyL');await f.click('confirm-modal');assert.match(f.overlay,/Record shortcut/);assert.match(f.nodes.get('toast').textContent,/Use Control or Alt/);
 await f.key('KeyL',{ctrl:true,alt:true});await f.click('confirm-modal');assert.equal(f.commands.filter(value=>value.action==='setSettings').at(-1).payload.patch.shortcuts.library,'Control+Alt+L');
 await f.click('record-global',{keyAction:'copyLatest'});await f.key('KeyC',{ctrl:true,alt:true});await f.click('confirm-modal');assert.equal(f.commands.filter(value=>value.action==='setSettings').at(-1).payload.patch.shortcuts.copyLatest,'Control+Alt+C');
 await f.click('disable-global',{keyAction:'copyLatest'});assert.equal(f.commands.filter(value=>value.action==='setSettings').at(-1).payload.patch.shortcuts.copyLatest,'');
});

for(const [width,height]of[[3840,2160],[7680,4320]])test('retained '+width+'×'+height+' markup coalesces pointer painting without dropping samples or copying the original',async()=>{
 const f=fixture({queuedAnimationFrames:true,imageRaster:{width,height}});await f.ready();await f.key('Space');f.flushAnimationFrames();await f.key('KeyM');f.flushAnimationFrames();await f.click('image-tool',{tool:'pen'});f.flushAnimationFrames();f.paintCalls.length=0;
 await f.pointer('pointerdown',90,44);for(let index=1;index<=96;index++)await f.pointer('pointermove',90+index*6,44+index);await f.pointer('pointerup',666,140);
 assert.equal(f.animationFrames.length,1);assert.equal(f.paintCalls.filter(value=>value.canvas==='markup-canvas').length,0,'No synchronous per-event raster work');f.flushAnimationFrames();
 assert.equal(f.paintCalls.filter(value=>value.canvas==='markup-canvas'&&value.operation==='clearRect').length,1);assert.equal(f.paintCalls.filter(value=>value.canvas==='markup-canvas'&&value.operation==='drawImage').length,0);assert.equal(f.imageLoads.length,1);
 await f.key('KeyS',{ctrl:true});const saved=f.commands.find(value=>value.action==='saveImage');assert.ok(saved);assert.equal(saved.payload.annotations[0].points.length,97);assert.deepEqual(saved.payload.annotations[0].points[0],{x:width*.1,y:height*.2});assert.ok(Math.abs(saved.payload.annotations[0].points.at(-1).x-width*666/900)<1e-7);
});
test('Turkish Settings toggles use the same localized visible and accessible label',async()=>{const f=fixture();await f.ready();await f.api.command('settings');await f.api.emit({settings:{...f.state.settings,language:'tr'}});await f.ready();assert.match(f.main,/aria-label="Sesler"/);assert.doesNotMatch(f.main,/aria-label="Sounds"/);});

test('closing an editor before its scheduled frame prevents stale overlay painting',async()=>{const f=fixture({queuedAnimationFrames:true});await f.ready();await f.key('Space');f.flushAnimationFrames();await f.key('KeyM');assert.equal(f.animationFrames.length,1);await f.key('Escape');assert.doesNotMatch(f.overlay,/id="markup-canvas"/);f.paintCalls.length=0;f.flushAnimationFrames();assert.equal(f.paintCalls.filter(value=>value.canvas==='markup-canvas').length,0);assert.match(f.overlay,/id="preview-dialog"/);});

async function historyCleanupFixture(language='en'){
 const f=fixture();await f.ready();const basedOn=(kind,id,extra)=>({...structuredClone(f.state.items.find(value=>value.kind===kind)),id,retainedAt:null,pinned:false,folderIds:[],tags:[],trashedAt:null,...extra});
 f.api.emit({settings:{...f.state.settings,language},items:[...f.state.items.map(value=>value.id===f.text2?{...value,retainedAt:1000}:value),
  basedOn('image','00000000-0000-4000-8000-000000000005',{pinned:true}),basedOn('link','00000000-0000-4000-8000-000000000006',{folderIds:['retained-folder']}),
  basedOn('text','00000000-0000-4000-8000-000000000007',{tags:['retained-tag']}),basedOn('link','00000000-0000-4000-8000-000000000008',{trashedAt:1000})]});
 await f.api.command('settings');await f.click('settings-tab',{tab:'history'});return f;
}
test('History cleanup selector counts each actual unsaved type and excludes saved organization and old Trash',async()=>{
 const f=await historyCleanupFixture();assert.match(f.main,/id="history-cleanup-kind" aria-label="Copies to clear"/);assert.match(f.main,/data-history-cleanup-count role="status">3 unsaved copies/);
 for(const kind of['image','text','link']){await f.change('history-cleanup-kind',kind);assert.match(f.main,new RegExp('value="'+kind+'" selected'));assert.match(f.main,/data-history-cleanup-count role="status">1 unsaved copies/);}
 f.api.emit({items:f.state.items.map(value=>value.id===f.link?{...value,retainedAt:2000}:value)});await f.ready();assert.match(f.main,/data-history-cleanup-count role="status">0 unsaved copies/);assert.match(f.main,/data-action="clear-history"[^>]*disabled/);
});
for(const cancel of['Escape','button'])test('History cleanup '+cancel+' cancel sends no backend operation and changes no records',async()=>{
 const f=await historyCleanupFixture(),before=structuredClone(f.state),calls=f.commands.length;await f.click('clear-history');assert.match(f.overlay,/aria-label="Clear unsaved copies\?"/);assert.match(f.overlay,/3 unsaved copies will move/);
 if(cancel==='Escape')await f.key('Escape');else await f.click('close-modal');assert.equal(f.overlay,'');assert.equal(f.commands.length,calls);assert.deepEqual(f.state,before);
});
test('History cleanup confirmation keeps the chosen kind and captured IDs when later copies arrive or an item is newly saved',async()=>{
 const f=await historyCleanupFixture();await f.change('history-cleanup-kind','text');await f.click('clear-history');assert.match(f.overlay,/1 unsaved copies will move/);const later='00000000-0000-4000-8000-000000000009';
 f.api.emit({items:[...f.state.items.map(value=>value.id===f.text1?{...value,retainedAt:3000}:value),{...structuredClone(f.state.items.find(value=>value.id===f.text1)),id:later,retainedAt:null,text:'Copied after confirmation opened'}]});await f.ready();await f.key('Enter');
 const commands=f.commands.filter(value=>value.action==='clearUnsavedHistory');assert.equal(commands.length,1);assert.deepEqual(commands[0].payload,{kind:'text',ids:[f.text1],captures:{[f.text1]:{revision:null,createdAt:900,updatedAt:900,lastCopiedAt:null}}});assert.equal(commands[0].payload.ids.includes(later),false);assert.equal(f.overlay,'');
});
test('Turkish History cleanup uses the same localized visible selector label, accessible label, count, action and confirmation',async()=>{
 const f=await historyCleanupFixture('tr');assert.match(f.main,/<strong>Temizlenecek kopyalar<\/strong>/);assert.match(f.main,/id="history-cleanup-kind" aria-label="Temizlenecek kopyalar"/);assert.match(f.main,/3 kaydedilmemiş kopya/);assert.match(f.main,/Kaydedilmemiş kopyaları temizle…/);
 await f.change('history-cleanup-kind','text');await f.click('clear-history');assert.match(f.overlay,/aria-label="Kaydedilmemiş kopyalar temizlensin mi\?"/);assert.match(f.overlay,/1 kaydedilmemiş kopya, Kütüphane/);assert.match(f.overlay,/>Çöp Kutusu(?:’|'|&#39;)na taşı</);assert.match(f.overlay,/>İptal</);
});

test('all recorder exits end their suspension and replacement recorder tokens remain distinct',async()=>{
 const f=fixture();await f.ready();await f.api.command('settings');await f.ready();
 await f.click('record-global',{keyAction:'search'});const first=f.commands.find(value=>value.action==='beginShortcutRecording').payload.token;assert.match(f.overlay,/data-recording-ready="true"/);
 await f.key('KeyS',{ctrl:true,alt:true});assert.match(f.overlay,/Ctrl\+Alt\+S/);assert.equal(f.state.view,'settings');await f.key('Escape');assert.equal(f.overlay,'');assert.ok(f.commands.some(value=>value.action==='endShortcutRecording'&&value.payload.token===first));
 await f.click('record-local',{keyAction:'pin'});const second=f.commands.filter(value=>value.action==='beginShortcutRecording').at(-1).payload.token;assert.notEqual(first,second);await f.blur();assert.equal(f.overlay,'');assert.ok(f.commands.some(value=>value.action==='endShortcutRecording'&&value.payload.token===second));
 await f.click('record-global',{keyAction:'library'});await f.click('record-local',{keyAction:'name'});const starts=f.commands.filter(value=>value.action==='beginShortcutRecording');assert.equal(starts.length,4);assert.ok(f.commands.some(value=>value.action==='endShortcutRecording'&&value.payload.token===starts[2].payload.token));assert.ok(f.commands.findIndex(value=>value.action==='beginShortcutRecording'&&value.payload.token===starts[3].payload.token)<f.commands.findIndex(value=>value.action==='endShortcutRecording'&&value.payload.token===starts[2].payload.token));await f.click('close-modal');assert.equal(f.overlay,'');assert.ok(f.commands.some(value=>value.action==='endShortcutRecording'&&value.payload.token===starts[3].payload.token));
});

test('History confirmation preserves the original capture stamp when the same item ID is recopied or edited while it is open',async()=>{
 const f=await historyCleanupFixture(),before='11111111-1111-4111-8111-111111111111',after='22222222-2222-4222-8222-222222222222';f.api.emit({items:f.state.items.map(value=>value.id===f.text1?{...value,captureRevision:before}:value)});await f.ready();await f.change('history-cleanup-kind','text');await f.click('clear-history');
 f.api.emit({items:f.state.items.map(value=>value.id===f.text1?{...value,captureRevision:after,createdAt:4000,updatedAt:5000}:value)});await f.ready();await f.key('Enter');const request=f.commands.find(value=>value.action==='clearUnsavedHistory');assert.ok(request);assert.deepEqual(request.payload,{kind:'text',ids:[f.text1],captures:{[f.text1]:{revision:before,createdAt:900,updatedAt:900,lastCopiedAt:null}}});
});

test('Escape while recorder startup is pending releases its token even after a late reply',async()=>{
 const f=fixture();await f.ready();await f.api.command('settings');await f.ready();const release=f.deferReply('beginShortcutRecording');
 await f.click('record-global',{keyAction:'search'});assert.match(f.overlay,/data-recording-ready="false"/);const token=f.commands.filter(value=>value.action==='beginShortcutRecording').at(-1).payload.token;
 await f.key('Escape');assert.equal(f.overlay,'');assert.ok(f.commands.some(value=>value.action==='endShortcutRecording'&&value.payload.token===token));release();await f.ready();assert.equal(f.overlay,'');
});

for(const row of [
 {code:'',key:'s',expected:'Ctrl+Alt+S',saved:'Control+Alt+S'},
 {code:'Unidentified',key:'s',expected:'Ctrl+Alt+S',saved:'Control+Alt+S'},
 {code:'',key:'s',shift:true,expected:'Ctrl+Alt+Shift+S',saved:'Control+Alt+Shift+S'},
 {code:'Unidentified',key:'S',shift:true,expected:'Ctrl+Alt+Shift+S',saved:'Control+Alt+Shift+S'},
 {code:'KeyS',key:'s',expected:'Ctrl+Alt+S',saved:'Control+Alt+S'},
 {code:'KeyQ',key:'x',expected:'Ctrl+Alt+Q',saved:'Control+Alt+Q'},
 {code:'Unidentified',key:'ı',expected:'Ctrl+Alt+ı',saved:'Control+Alt+ı'}
])test('recorder canonicalizes ASCII fallback without changing modifiers or hardware keys: '+JSON.stringify(row),async()=>{
 const f=fixture();await f.ready();await f.api.command('settings');await f.ready();await f.click('record-global',{keyAction:'search'});
 await f.key(row.code,{key:row.key,ctrl:true,alt:true,shift:!!row.shift});
 assert.ok(f.overlay.includes('>'+row.expected+'</div>'),f.overlay);
 await f.click('confirm-modal');assert.equal(f.overlay,'');assert.equal(f.commands.filter(value=>value.action==='setSettings').at(-1).payload.patch.shortcuts.search,row.saved);
});

test('unknown-code key events execute default shortcuts with the same letter and Shift meanings',async()=>{
 const f=fixture();await f.ready();await f.key('',{key:'p'});assert.equal(f.state.items.find(value=>value.id===f.image).pinned,true);
 await f.key('Unidentified',{key:'p'});assert.equal(f.state.items.find(value=>value.id===f.image).pinned,false);
 await f.key('Unidentified',{key:'p',shift:true});assert.match(f.overlay,/Pin to folder/);await f.key('Escape');
 await f.key('',{key:'l'});assert.equal(f.state.view,'library');
});

test('legacy lowercase remaps compare canonically without reviving disabled defaults or aliases',async()=>{
 const f=fixture();await f.ready();f.api.emit({settings:{...f.state.settings,localShortcuts:{pin:'Ctrl+Alt+j',library:'l',copy:'',remove:''}}});await f.ready();
 await f.key('KeyJ',{ctrl:true,alt:true});assert.equal(f.state.items.find(value=>value.id===f.image).pinned,true);
 await f.key('Unidentified',{key:'j',ctrl:true,alt:true});assert.equal(f.state.items.find(value=>value.id===f.image).pinned,false);
 const before=f.commands.length;await f.key('',{key:'p'});await f.key('KeyP',{ctrl:true});await f.key('Unidentified',{key:'s'});await f.key('Enter');await f.key('',{key:'c',ctrl:true});
 assert.equal(f.commands.length,before);assert.equal(f.state.windowVisible,true);
 await f.key('KeyL');assert.equal(f.state.view,'library');assert.equal(f.state.settings.localShortcuts.pin,'Ctrl+Alt+j','Reading a binding does not rewrite saved preferences');
});

test('recording a fallback letter detects a conflicting legacy lowercase remap',async()=>{
 const f=fixture();await f.ready();f.api.emit({settings:{...f.state.settings,localShortcuts:{remove:'j'}}});await f.ready();await f.api.command('settings');await f.ready();
 await f.click('record-local',{keyAction:'pin'});await f.key('Unidentified',{key:'j'});await f.click('confirm-modal');
 assert.match(f.overlay,/Record shortcut/);assert.match(f.nodes.get('toast').textContent,/already used for Take down/);assert.equal(f.state.settings.localShortcuts.pin,undefined);
 await f.key('Escape');
});

test('recording the same legacy lowercase global binding keeps its exact registration value',async()=>{
 const f=fixture();await f.ready();f.api.emit({settings:{...f.state.settings,shortcuts:{...f.state.settings.shortcuts,search:'Control+Alt+s'}}});await f.ready();await f.api.command('settings');await f.ready();
 await f.click('record-global',{keyAction:'search'});await f.key('Unidentified',{key:'s',ctrl:true,alt:true});assert.ok(f.overlay.includes('>Ctrl+Alt+S</div>'));await f.click('confirm-modal');
 assert.equal(f.commands.filter(value=>value.action==='setSettings').at(-1).payload.patch.shortcuts.search,'Control+Alt+s','An equal OS combination does not undergo a conflicting case-only re-registration');
});

async function keyboardSaved(f){f.api.emit({items:f.state.items.map(value=>({...value,pinned:true}))});await f.ready();await f.key('KeyL');}
test('Library first opening selects content and valid selection survives reentry and returning from shelves',async()=>{
 const f=fixture();await f.ready();await keyboardSaved(f);assert.equal(focusedCard(f),f.image);await f.key('ArrowRight');assert.equal(focusedCard(f),f.text1);
 await f.api.command('hide');await f.api.command('library');await f.ready();assert.equal(focusedCard(f),f.text1);await f.api.command('show');await f.api.command('library');await f.ready();assert.equal(focusedCard(f),f.text1);assert.equal(selectedCards(f).length,1);
});
test('Library S Delete and ControlBackspace use recoverable Trash; Backspace and ControlZ restore and keep the window',async()=>{
 const f=fixture();await f.ready();await keyboardSaved(f);
 for(const [remove,mods,undo,undoMods]of [['KeyS',{},'Backspace',{}],['Delete',{},'KeyZ',{ctrl:true}],['Backspace',{ctrl:true},'Backspace',{}]]){await f.key(remove,mods);assert.equal(f.overlay,'');assert.ok(f.state.items.find(value=>value.id===f.image).trashedAt);assert.equal(focusedCard(f),f.text1);await f.key(undo,undoMods);assert.equal(f.state.items.find(value=>value.id===f.image).trashedAt,null);assert.equal(focusedCard(f),f.image);}
 assert.equal(f.commands.filter(value=>value.action==='delete').length,0);assert.equal(f.state.windowVisible,true);
});
test('Library Trash and pane navigation respect disabled bindings and remapped aliases',async()=>{
 const f=fixture();await f.ready();await keyboardSaved(f);f.api.emit({settings:{...f.state.settings,localShortcuts:{remove:'Y',trash:'X',undoTrash:'U',focusNextPane:'',focusPreviousPane:''}}});await f.ready();const before=f.commands.length;
 for(const [key,extra]of [['KeyS',{}],['Delete',{}],['Backspace',{}],['KeyZ',{ctrl:true}],['F6',{}],['Tab',{ctrl:true}],['F6',{shift:true}],['Tab',{ctrl:true,shift:true}]])assert.equal((await f.key(key,extra)).prevented,undefined,key+' must not trigger a disabled binding');
 assert.equal(f.commands.length,before);await f.key('KeyX');assert.ok(f.state.items.find(value=>value.id===f.image).trashedAt);await f.key('KeyU');assert.equal(f.state.items.find(value=>value.id===f.image).trashedAt,null);
});
test('Library E M and C open the selected content editor without a pointer action',async()=>{
 const f=fixture();await f.ready();await keyboardSaved(f);await f.key('ArrowRight');await f.key('KeyE');assert.match(f.overlay,/id="text-editor"/);await f.key('Escape');await f.key('Escape');await f.key('ArrowLeft');await f.key('KeyC');assert.match(f.overlay,/id="markup-canvas"/);assert.match(f.overlay,/Apply crop/);await f.key('Escape');await f.key('Escape');await f.key('KeyM');assert.match(f.overlay,/id="markup-canvas"/);assert.match(f.overlay,/Done/);
});
test('Library focused buttons retain native Enter Space activation instead of selected-item copy or preview',async()=>{
 const f=fixture();await f.ready();await keyboardSaved(f);const button=f.nodes.get('app');button.closest=selector=>selector==='button'?button:null;button.tagName='BUTTON';const before=f.commands.length;
 for(const key of ['Enter','Space'])assert.equal((await f.key(key,{target:button})).prevented,undefined,'The native button activation default is preserved');assert.equal(f.commands.length,before);assert.equal(f.overlay,'');
});
test('Library ControlF works inside an editor; caret arrows stay native and Escape keeps the query',async()=>{
 const f=fixture();await f.ready();await keyboardSaved(f);await f.key('KeyF',{ctrl:true});const field=f.nodes.get('search-input');field.tagName='INPUT';field.matches=selector=>selector.includes('input');assert.equal((await f.key('KeyF',{ctrl:true,target:field})).prevented,true);await f.input('search-input','Text one');assert.equal((await f.key('ArrowLeft',{target:field})).prevented,undefined);assert.equal((await f.key('Escape',{target:field})).prevented,true);assert.match(f.main,/value="Text one"/);assert.equal(focusedCard(f),f.text1);
});

test('shared Library keyboard contract runs actual renderer handlers and durable Store transactions',async()=>{
 const os=require('node:os'),{Store}=require('../lib/model.cjs');
 const contractFile=path.resolve(__dirname,'../../contracts/library-keyboard.json'),raw=fs.readFileSync(contractFile),contract=JSON.parse(raw),observations=[],errors=[];
 assert.equal(contract.contractId,'clipboardline.library.keyboard.v1');
 for(const scenario of contract.scenarios){
  const directory=fs.mkdtempSync(path.join(os.tmpdir(),'clipboardline-library-contract-'));
  try{
   const store=new Store(directory),now=Date.now(),f=fixture(),aliases=new Map(),ids=new Map();await f.ready();f.grid(scenario.columns);
   store.data.items=contract.records.map((entry,index)=>{const id='30000000-0000-4000-8000-'+String(index+1).padStart(12,'0');aliases.set(id,entry.id);ids.set(entry.id,id);const source=f.state.items.find(value=>value.kind===entry.kind);return{...structuredClone(source),id,createdAt:now-index*1000,updatedAt:now-index*1000,retainedAt:now,pinned:entry.pinned,hiddenFromShelf:!entry.onShelf,name:entry.title,title:entry.kind==='link'?entry.title:'',text:entry.kind==='text'?entry.text:'',url:entry.kind==='link'?'https://example.com/library-contract/'+entry.id:'',captureRevision:crypto.randomUUID(),...(entry.kind==='image'?{imageFile:'0'.repeat(64)+'.png'}:{})};});
   store.persist();let surface={view:'shelves',windowVisible:false,version:'1.7.7'};
   f.api.command=async(action,payload={})=>{f.commands.push({action,payload:structuredClone(payload)});let result;if(['library','show','settings'].includes(action))surface={...surface,view:action==='show'?'shelves':action,windowVisible:true};else if(action==='hide')surface.windowVisible=false;else if(action==='searchImages')result={ids:[],scores:[],available:false,indexing:false};else result=store.modify(action,payload);const next={...store.publicState(),...surface,result};f.api.emit(next);return structuredClone(next);};
   f.api.emit({...store.publicState(),...surface});await f.ready();
   for(let index=0;index<scenario.steps.length;index++){
    const step=scenario.steps[index];
    if(step.action==='open')await f.api.command('library');
    else if(step.action==='close')await f.api.command('hide');
    else if(step.action==='mode')await f.click('view-mode');
    else if(step.action==='select'){await f.key('ArrowLeft',{ctrl:true});const target=contract.records.findIndex(value=>value.id===step.id);for(let n=0;n<target;n++)await f.key('ArrowRight');}
    else if(step.action==='scope'){await f.click('scope',{scope:step.scope});await f.key('Enter',{target:f.editor('search-input')});}
    else if(step.action==='searchHandoff'){const editor=f.editor('search-input');await f.input('search-input',step.value);await f.key('Enter',{target:editor});}
    else if(step.action==='remap'){const value=step.key?.startsWith('Key')?step.key.slice(3):step.key;await f.api.command('setSettings',{patch:{localShortcuts:{[step.binding]:value}}});}
    else if(step.action==='key')await f.key(step.code,{ctrl:step.modifiers.some(value=>['primary','control'].includes(value)),alt:step.modifiers.includes('alt'),shift:step.modifiers.includes('shift'),...(step.editing?{target:f.editor('detail-text')}:{})});
    else throw new Error('Unknown Library contract action '+step.action);
    await f.ready();const actual={focused:aliases.get(focusedCard(f))||null,selected:selectedCards(f).map(id=>aliases.get(id)),visible:[...f.main.matchAll(/<article class="[^"]*"[^>]*data-item-id="([^"]+)"/g)].map(value=>aliases.get(value[1])),scope:f.main.match(/data-action="scope" data-scope="([^"]+)" class="active"/)?.[1]||'saved',kind:f.main.match(/data-action="(allTypes|images|texts|links)" aria-pressed="true"/)?.[1]||'allTypes',search:f.nodes.get('search-input')?.value||'',list:/class="library-grid list"/.test(f.main),trashed:contract.records.filter(value=>store.item(ids.get(value.id)).trashedAt).map(value=>value.id),pinned:contract.records.filter(value=>store.item(ids.get(value.id)).pinned).map(value=>value.id),pinnedOnly:/data-action="pinnedOnly"[^>]*aria-pressed="true"/.test(f.main)};
    actual.kind={allTypes:'all',images:'image',texts:'text',links:'link'}[actual.kind];
    // The DOM fixture stores input values only after input/focus events; the
    // rendered field remains the source of truth after a keyboard filter.
    actual.search=(f.main.match(/id="search-input"[^>]*value="([^"]*)"/)?.[1]||'').replaceAll('&quot;','"').replaceAll('&amp;','&');
    const expected={...step.expect,visible:contract.views[step.expect.visible]};observations.push({scenarioId:scenario.id,step:index,actual});try{assert.deepEqual(actual,expected);}catch(error){errors.push(scenario.id+' step '+index+': '+error.message);}
   }
  }finally{fs.rmSync(directory,{recursive:true,force:true});}
 }
 const libraryReportDestination=process.env.CLIPBOARDLINE_LIBRARY_KEYBOARD_REPORT || (process.env.CLIPBOARDLINE_PARITY_REPORT && path.join(path.dirname(process.env.CLIPBOARDLINE_PARITY_REPORT),'library-windows.json'));
 if(libraryReportDestination){const revision=process.env.GITHUB_SHA||execFileSync('git',['rev-parse','HEAD'],{cwd:path.resolve(__dirname,'../..'),encoding:'utf8'}).trim(),report={schemaVersion:1,contractId:contract.contractId,contractSHA256:crypto.createHash('sha256').update(raw).digest('hex'),platform:'windows',hostPlatform:process.platform,mode:'renderer',sourceRevision:revision,observations,errors,passed:errors.length===0};fs.mkdirSync(path.dirname(path.resolve(libraryReportDestination)),{recursive:true});fs.writeFileSync(libraryReportDestination,JSON.stringify(report,null,2)+'\n');}
 assert.deepEqual(errors,[]);
});


test('Library noncontiguous Trash chooses the survivor after the focused removed item, or previous at the end',async()=>{
 for(const focusedIndex of [5,7]){const f=fixture();await f.ready();const values=navigationItems(f,{image:8,text:0,link:0}).image.map(value=>({...value,pinned:true}));f.api.emit({items:values});await f.ready();await f.key('KeyL');await f.cardClick(values[1].id);await f.cardClick(values[focusedIndex].id,{ctrl:true});assert.deepEqual(selectedCards(f),[values[1].id,values[focusedIndex].id]);assert.equal(focusedCard(f),values[focusedIndex].id);await f.key('KeyS');assert.equal(focusedCard(f),values[6].id);assert.deepEqual(selectedCards(f),[values[6].id]);await f.key('Backspace');assert.deepEqual(values.map(value=>f.state.items.find(item=>item.id===value.id).trashedAt),Array(8).fill(null));}
});

test('confirmed Library Trash preserves its captured dialog and selection when commit fails, then retries with next-item focus',async()=>{
 const f=fixture();await f.ready();await keyboardSaved(f);await f.click('trash');assert.match(f.overlay,/aria-label="Move to Trash"/);const command=f.api.command;
 f.api.command=async(action,payload)=>{if(action==='trashUndoably')throw new Error('Synthetic Trash persistence failure');return command(action,payload);};
 await f.key('Enter');await f.ready();assert.match(f.overlay,/aria-label="Move to Trash"/);assert.match(f.nodes.get('toast').textContent,/Synthetic Trash persistence failure/);assert.equal(focusedCard(f),f.image);assert.deepEqual(selectedCards(f),[f.image]);assert.equal(f.state.items.find(value=>value.id===f.image).trashedAt,null);
 f.api.command=command;await f.key('Enter');await f.ready();assert.equal(f.overlay,'');assert.equal(focusedCard(f),f.text1);assert.deepEqual(selectedCards(f),[f.text1]);
});


test('IME composing Enter Escape and arrows stay native in Library search, text preview editing and modal fields',async()=>{
 for(const ime of [{composing:true},{keyCode:229}]){
  const search=fixture();await search.ready();await keyboardSaved(search);await search.input('search-input','Text');const field=search.editor('search-input'),before=search.commands.length,initialFocus=focusedCard(search),initialSelection=selectedCards(search);
  for(const code of ['Enter','Escape','ArrowDown','ArrowRight'])assert.equal((await search.key(code,{...ime,target:field})).prevented,undefined);
  assert.equal(focusedCard(search),initialFocus);assert.deepEqual(selectedCards(search),initialSelection);assert.equal(search.nodes.get('search-input').value,'Text');assert.equal(search.commands.length,before);
  const text=fixture();await text.ready();await keyboardSaved(text);await text.key('ArrowRight');await text.key('KeyE');await text.input('text-editor','Synthetic composing draft');const editor=text.editor('text-editor'),textCommands=text.commands.length;
  for(const [code,mods]of [['Enter',{ctrl:true}],['Escape',{}],['ArrowLeft',{}],['KeyP',{}]])assert.equal((await text.key(code,{...ime,...mods,target:editor})).prevented,undefined);
  assert.match(text.overlay,/id="text-editor"/);assert.equal(text.nodes.get('text-editor').value,'Synthetic composing draft');assert.equal(text.commands.length,textCommands);
  const modal=fixture();await modal.ready();await keyboardSaved(modal);await modal.key('KeyP',{shift:true});await modal.input('modal-query','Synthetic composing folder');const query=modal.editor('modal-query'),modalCommands=modal.commands.length;
  for(const code of ['Enter','Escape','ArrowDown'])assert.equal((await modal.key(code,{...ime,target:query})).prevented,undefined);
  assert.match(modal.overlay,/aria-label="Pin to folder"/);assert.equal(modal.nodes.get('modal-query').value,'Synthetic composing folder');assert.equal(modal.commands.length,modalCommands);
 }
});

test('an old shortcut save completion cannot close a newer recorder or release its owned global-shortcut lease',async()=>{
 const f=fixture();await f.ready();await f.api.command('settings');await f.ready();await f.click('record-local',{keyAction:'pin'});await f.ready();await f.key('KeyO');const release=f.deferReply('setSettings');await f.click('confirm-modal');await f.key('Escape');await f.click('record-local',{keyAction:'copy'});await f.ready();const begin=f.commands.filter(value=>value.action==='beginShortcutRecording').at(-1);assert.ok(begin);release();await f.ready();assert.match(f.overlay,/Record shortcut/);assert.equal(f.commands.some(value=>value.action==='endShortcutRecording'&&value.payload.token===begin.payload.token),false);await f.key('Escape');assert.equal(f.commands.some(value=>value.action==='endShortcutRecording'&&value.payload.token===begin.payload.token),true);
});

test('Cloudflare R2 upload shortcut caches public link, skips multi-selection, redirects when unconfigured, and manages settings',async()=>{
 const f=fixture();await f.ready();
 // Single-selection KeyU uploads and caches URL; second KeyU copies cached link.
 await f.key('KeyU');assert.equal(f.state.items[0].uploadedUrl,'https://cdn.example.com/'+f.image);assert.match(f.nodes.get('toast').textContent,/Uploaded — link copied/);
 await f.key('KeyU');assert.match(f.nodes.get('toast').textContent,/Public link copied/);
 assert.equal(f.commands.filter(value=>value.action==='uploadItem').length,2);

 // Multi-selection KeyU is a safe no-op.
 await f.key('ArrowDown');await f.key('ArrowRight',{shift:true});assert.equal(selectedCards(f).length,2);
 const beforeMulti=f.commands.filter(value=>value.action==='uploadItem').length;
 await f.key('KeyU');assert.equal(f.commands.filter(value=>value.action==='uploadItem').length,beforeMulti);

 // Unconfigured single-selection KeyU navigates to Settings -> Cloud upload.
 await f.key('ArrowLeft');assert.equal(selectedCards(f).length,1);
 f.api.emit({r2Configured:false,r2HasSecret:false});await f.ready();
 await f.key('KeyU');assert.equal(f.state.view,'settings');assert.match(f.main,/Account ID or HTTPS endpoint/);assert.match(f.nodes.get('toast').textContent,/Configure Cloudflare R2 in Settings first/);

 // Saving secret, testing connection, and clearing secret dispatch IPC commands.
 await f.input('r2-secret-key','s'.repeat(24));await f.click('save-r2-secret');
 assert.equal(f.commands.some(value=>value.action==='setR2Secret'),true);
 await f.click('test-r2-connection');
 assert.equal(f.commands.some(value=>value.action==='testR2Connection'),true);
 await f.click('clear-r2-secret');
 assert.equal(f.commands.some(value=>value.action==='clearR2Secret'),true);
});
