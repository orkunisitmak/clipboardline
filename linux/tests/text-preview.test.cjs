'use strict';
// Execute the actual preview renderer/DOM events with a controlled clock and
// delayed/failing IPC. These are renderer state tests; native Windows acceptance
// separately verifies real focus, browser geometry, input and clipboard formats.
const test=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
function fixture({deferInitialState=false,initialVisible=true}={}){
 const listeners=new Map(),nodes=new Map(),commands=[],imageLoads=[];let exportFailures=0,clock=0,timerID=0,activeEdits=0,maxActiveEdits=0;
 const timers=new Map();
 const schedule=(fn,delay=0)=>{const id=++timerID;timers.set(id,{at:clock+Math.max(0,delay),fn});return id;};
 const cancel=id=>timers.delete(id);
 class Element{
  constructor(id=''){this.id=id;this.innerHTML='';this.textContent='';this.dataset={};this.style={};this.className='';this.value='';this.selectionStart=0;this.selectionEnd=0;this.classList={add(){},remove(){},contains(){return false;}};}
  set innerHTML(value){this.htmlWrites=(this.htmlWrites||0)+1;this.html=value;if(this.id==='overlay-root'){
   const match=value.match(/<textarea id="text-editor" data-preview-id="([^"]+)"[^>]*>([\s\S]*?)<\/textarea>/);
   if(match){const editor=new TextArea('text-editor');editor.dataset.previewId=match[1];editor.value=match[2];editor.matches=selector=>selector.includes('textarea');nodes.set('text-editor',editor);}else nodes.delete('text-editor');
  }}get innerHTML(){return this.html;}
  setAttribute(key,value){this[key]=value;}querySelector(){return null;}querySelectorAll(){return [];}focus(){document.activeElement=this;}blur(){if(document.activeElement===this)document.activeElement=null;}select(){}setSelectionRange(start,end){this.selectionStart=start;this.selectionEnd=end;}scrollIntoView(){}matches(){return false;}closest(){return null;}
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
 const document={body:new Element('body'),activeElement:null,getElementById(id){if(!nodes.has(id))nodes.set(id,id==='markup-canvas'?new Canvas(id):new Element(id));return nodes.get(id);},createElement(tag){return tag==='canvas'?new Canvas():new Element();},querySelector(){return null;},addEventListener(name,listener){if(!listeners.has(name))listeners.set(name,[]);listeners.get(name).push(listener);}};
 const image='00000000-0000-4000-8000-000000000001',text1='00000000-0000-4000-8000-000000000002',text2='00000000-0000-4000-8000-000000000003',link='00000000-0000-4000-8000-000000000004';
 const base=(id,kind,createdAt,extra)=>({id,kind,createdAt,updatedAt:createdAt,name:'',title:'',text:'',url:'',pinned:false,folderIds:[],tags:[],trashedAt:null,hiddenFromShelf:false,...extra});
 const state={items:[base(image,'image',1000,{name:'Synthetic image',mediaUrl:'appmedia://media/'+image,originalMediaUrl:'appmedia://media/'+image+'/original'}),base(text1,'text',900,{text:'Text one'}),base(text2,'text',800,{text:'Text two'}),base(link,'link',700,{url:'https://example.com/reference',title:'Reference link'})],folders:[],settings:{visibleKinds:['image','text','link'],retentionDays:{image:30,text:30,link:30},shortcuts:{toggle:'Control+Alt+Space',search:'Control+Alt+S'},localShortcuts:{},language:'en',theme:'soft',cardSize:'medium'},view:'shelves',version:'1.7.0',windowVisible:initialVisible,canUndo:false};
 let subscriber,removed=[],cleanupFailures=0,editFailures=0,delayedReply=null,releaseInitialState;
 const clone=value=>structuredClone(value);
 const api={emit(patch){Object.assign(state,patch);subscriber?.(clone(state));},state:async()=>{const initial=clone(state);if(deferInitialState)await new Promise(resolve=>{releaseInitialState=resolve;});return initial;},subscribe(fn){subscriber=fn;return()=>{};},async command(action,payload={}){commands.push({action,payload:clone(payload)});const selected=state.items.filter(item=>(payload.ids||[payload.id]).includes(item.id));
  let cleanupError;if(action==='cleanup'){if(cleanupFailures){cleanupFailures--;cleanupError='Permanent deletion cleanup is still pending.';}else state.needsDeletionCleanup=false;}
  if(action==='editText'){activeEdits++;maxActiveEdits=Math.max(maxActiveEdits,activeEdits);try{if(delayedReply?.action===action){const pending=delayedReply;delayedReply=null;await pending.promise;}if(editFailures){editFailures--;cleanupError='Synthetic draft write failure';}else selected.forEach(item=>item.text=payload.text);}finally{activeEdits--;}}
  if(action==='setSettings'){const patch=payload.patch||{},localShortcuts={...state.settings.localShortcuts,...patch.localShortcuts};for(const [action,value]of Object.entries(localShortcuts))if(value===null)delete localShortcuts[action];state.settings={...state.settings,...patch,localShortcuts};}
  if(action==='saveImage')selected.forEach(item=>{item.crop=clone(payload.crop);item.annotations=clone(payload.annotations);});
  if(action==='pin')selected.forEach(item=>item.pinned=typeof payload.value==='boolean'?payload.value:!item.pinned);
  if(action==='name')selected.forEach(item=>{item.name=payload.name;item.pinned=true;});
  if(action==='remove'){removed=selected.map(clone);selected.forEach(item=>{if(item.pinned)item.hiddenFromShelf=true;else item.trashedAt=Date.now();});state.canUndo=true;}
  if(action==='undo'){for(const before of removed)Object.assign(state.items.find(item=>item.id===before.id),before);state.canUndo=false;}
  if(action==='copy'&&!payload.keepOpen||action==='paste'||action==='hide')state.windowVisible=false;
  if(action==='show'){state.view='shelves';state.windowVisible=true;state.viewEvent={serial:String(commands.length)};}
  if(action==='library'||action==='settings'){state.view=action;state.windowVisible=true;}
  const output=clone(state);if(cleanupError)output.result={error:cleanupError};subscriber?.(output);
  if(delayedReply?.action===action){const pending=delayedReply;delayedReply=null;await pending.promise;}
  return output;
 }};
 const context={window:{clipboardLine:api,addEventListener(){}},document,HTMLElement:Element,HTMLTextAreaElement:TextArea,Image:FixtureImage,console,structuredClone,URL,Set,Date,JSON,Math,Number,String,requestAnimationFrame:fn=>fn(),setTimeout:schedule,clearTimeout:cancel};
 vm.createContext(context);vm.runInContext(fs.readFileSync(path.join(__dirname,'../renderer.js'),'utf8'),context,{filename:'renderer.js'});
 async function ready(){await new Promise(setImmediate);}
 async function key(code,{ctrl=false,alt=false,shift=false,key,target}={}){const event={code,key:key||(/^Key/.test(code)?code.slice(3).toLowerCase():code==='Space'?' ':code),ctrlKey:ctrl,metaKey:false,altKey:alt,shiftKey:shift,repeat:false,target:target||new Element(),preventDefault(){this.prevented=true;}};for(const listener of listeners.get('keydown')||[])await listener(event);await ready();return event;}
 async function click(action,extra={}){const target=new Element();target.dataset.action=action;Object.assign(target.dataset,extra);target.closest=selector=>selector==='[data-action]'?target:null;for(const listener of listeners.get('click')||[])listener({target,stopPropagation(){}});await ready();}
 async function pointer(type,x,y){const target=document.getElementById('markup-canvas');for(const listener of listeners.get(type)||[])listener({target,clientX:x,clientY:y,pointerId:1,shiftKey:false,preventDefault(){}});await ready();}
 async function input(id,value){const target=document.getElementById(id);target.value=value;target.selectionStart=value.length;for(const listener of listeners.get('input')||[])await listener({target});await ready();}
 return{ready,key,input,click,pointer,imageLoads,
 async advance(ms){const end=clock+ms;for(;;){const next=[...timers.entries()].filter(([,timer])=>timer.at<=end).sort((a,b)=>a[1].at-b[1].at||a[0]-b[0])[0];if(!next)break;clock=next[1].at;timers.delete(next[0]);next[1].fn();await ready();}clock=end;await ready();},
 get maxActiveEdits(){return maxActiveEdits;},get overlayWrites(){return nodes.get('overlay-root').htmlWrites;},get activeElement(){return document.activeElement;},releaseInitialState(){releaseInitialState?.();},deferReply(action){let release;const promise=new Promise(resolve=>{release=resolve;});delayedReply={action,promise};return release;},failExportOnce(){exportFailures++;},failCleanupOnce(){cleanupFailures++;},failEditOnce(){editFailures++;},state,commands,nodes,image,text1,text2,link,api,get main(){return nodes.get('app').innerHTML;},get overlay(){return nodes.get('overlay-root').innerHTML;}};
}

const edits=f=>f.commands.filter(value=>value.action==='editText');
async function preview(f){await f.ready();await f.key('ArrowDown');await f.key('Space');}
async function edit(f){await preview(f);await f.key('KeyE');await f.advance(0);}

test('clicking preview text starts editing and autosaves the exact draft after 300ms',async()=>{
 const f=fixture();await preview(f);assert.match(f.overlay,/<pre class="preview-text" data-action="edit"/);await f.click('edit');await f.advance(0);
 assert.equal(f.activeElement,f.nodes.get('text-editor'));const body='  Cafe\u0301\r\nIndents\n\n';await f.input('text-editor',body);await f.advance(299);assert.equal(edits(f).length,0);await f.advance(1);
 assert.equal(edits(f).length,1);assert.equal(edits(f)[0].payload.text,body);assert.equal(f.state.items.find(value=>value.id===f.text1).text,body);assert.match(f.overlay,/id="text-editor"/);
});
test('typing coalesces into one save and untouched Done does not rewrite content',async()=>{
 const f=fixture();await edit(f);await f.input('text-editor','First');await f.advance(250);await f.input('text-editor','Second');await f.advance(299);assert.equal(edits(f).length,0);await f.advance(1);assert.equal(edits(f).length,1);assert.equal(edits(f)[0].payload.text,'Second');
 await f.key('Enter',{ctrl:true,target:f.nodes.get('text-editor')});assert.equal(edits(f).length,1);await f.key('KeyE');await f.key('Escape');assert.equal(edits(f).length,1);
});
test('in-flight autosave serializes and saves only the latest subsequent draft',async()=>{
 const f=fixture();await edit(f);const release=f.deferReply('editText');await f.input('text-editor','First revision');await f.advance(300);assert.equal(edits(f).length,1);
 await f.input('text-editor','Intermediate revision');await f.input('text-editor','Final revision');await f.advance(300);assert.equal(edits(f).length,1);release();await f.ready();
 assert.equal(f.maxActiveEdits,1);assert.deepEqual(edits(f).map(value=>value.payload.text),['First revision','Final revision']);assert.equal(f.state.items.find(value=>value.id===f.text1).text,'Final revision');
});
test('autosave preserves the live textarea, selection and undo session across state packets',async()=>{
 const f=fixture();await edit(f);const editor=f.nodes.get('text-editor');editor.undoSession={marker:'native undo retained'};editor.setSelectionRange(3,5);await f.input('text-editor','Retained draft');editor.setSelectionRange(3,5);const writes=f.overlayWrites;await f.advance(300);
 assert.equal(f.nodes.get('text-editor'),editor);assert.equal(f.overlayWrites,writes);assert.deepEqual(editor.undoSession,{marker:'native undo retained'});assert.equal(editor.selectionStart,3);assert.equal(editor.selectionEnd,5);assert.equal(f.activeElement,editor);
});
test('failed autosave retains the draft, stops automatic retries, and Done retries',async()=>{
 const f=fixture();await edit(f);f.failEditOnce();await f.input('text-editor','Draft after failure');await f.advance(300);assert.equal(edits(f).length,1);assert.match(f.overlay,/id="text-editor"/);assert.equal(f.state.items.find(value=>value.id===f.text1).text,'Text one');
 await f.advance(4000);assert.equal(edits(f).length,1);await f.key('Enter',{ctrl:true,target:f.nodes.get('text-editor')});assert.equal(edits(f).length,2);assert.equal(f.state.items.find(value=>value.id===f.text1).text,'Draft after failure');assert.doesNotMatch(f.overlay,/id="text-editor"/);assert.equal(f.commands.filter(value=>value.action==='paste').length,0);
});
test('failed explicit save vetoes closing while Escape retry saves then returns to browsing',async()=>{
 const f=fixture();await edit(f);await f.input('text-editor','Unsaved body');f.failEditOnce();await f.click('close-preview');assert.match(f.overlay,/id="text-editor"/);assert.equal(f.state.items.find(value=>value.id===f.text1).text,'Text one');await f.key('Escape',{target:f.nodes.get('text-editor')});assert.doesNotMatch(f.overlay,/id="text-editor"/);assert.match(f.overlay,/id="preview-dialog"/);assert.equal(f.state.items.find(value=>value.id===f.text1).text,'Unsaved body');await f.key('ArrowRight');assert.match(f.overlay,/Text two/);
});
test('plain typing and caret commands stay native; modified pin/filter/Actions remain available',async()=>{
 const f=fixture();await edit(f);let editor=f.nodes.get('text-editor');for(const code of ['KeyP','KeyF','ArrowLeft','ArrowRight','ArrowUp','ArrowDown','Enter'])assert.equal((await f.key(code,{target:editor})).prevented,undefined,code);assert.equal((await f.key('KeyC',{ctrl:true,target:editor})).prevented,undefined);
 await f.input('text-editor','Pin this edited body');assert.equal((await f.key('KeyP',{ctrl:true,target:editor})).prevented,true);assert.equal(f.state.items.find(value=>value.id===f.text1).pinned,true);assert.equal(f.state.items.find(value=>value.id===f.text1).text,'Pin this edited body');assert.match(f.overlay,/id="text-editor"/);
 editor=f.nodes.get('text-editor');assert.equal((await f.key('KeyF',{ctrl:true,shift:true,target:editor})).prevented,true);assert.doesNotMatch(f.overlay,/id="text-editor"/);await f.key('KeyE');await f.advance(0);editor=f.nodes.get('text-editor');await f.key('KeyK',{ctrl:true,target:editor});assert.match(f.overlay,/Search actions/);
});
test('remapping or disabling editing pin shortcuts replaces default aliases without capturing plain letters',async()=>{
 const f=fixture();await edit(f);f.api.emit({settings:{...f.state.settings,localShortcuts:{pin:'Ctrl+O',pinnedOnly:'Ctrl+J'}}});await f.ready();let editor=f.nodes.get('text-editor');assert.equal((await f.key('KeyP',{ctrl:true,target:editor})).prevented,undefined);assert.equal((await f.key('KeyO',{target:editor})).prevented,undefined);assert.equal((await f.key('KeyO',{ctrl:true,target:editor})).prevented,true);assert.equal(f.state.items.find(value=>value.id===f.text1).pinned,true);
 editor=f.nodes.get('text-editor');assert.equal((await f.key('KeyF',{ctrl:true,shift:true,target:editor})).prevented,undefined);assert.equal((await f.key('KeyJ',{ctrl:true,target:editor})).prevented,true);f.api.emit({settings:{...f.state.settings,localShortcuts:{pin:'',pinnedOnly:''}}});await f.ready();editor=f.nodes.get('text-editor');assert.equal((await f.key('KeyP',{ctrl:true,target:editor})).prevented,undefined);assert.equal((await f.key('KeyF',{ctrl:true,shift:true,target:editor})).prevented,undefined);
});

test('filtering while editing saves and finishes before preview changes to a different pinned item',async()=>{
 const f=fixture();await edit(f);await f.api.command('pin',{ids:[f.text2]});await f.input('text-editor','Edited unpinned note');const editor=f.nodes.get('text-editor');await f.key('KeyF',{ctrl:true,shift:true,target:editor});
 assert.equal(f.state.items.find(value=>value.id===f.text1).text,'Edited unpinned note');assert.equal(f.state.items.find(value=>value.id===f.text2).text,'Text two');assert.doesNotMatch(f.overlay,/id="text-editor"/);assert.match(f.overlay,/Text two/);await f.key('KeyE');await f.advance(0);assert.equal(f.nodes.get('text-editor').value,'Text two');
});
