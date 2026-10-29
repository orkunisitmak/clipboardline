'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),os=require('node:os'),vm=require('node:vm');
const {Store}=require('../lib/model.cjs');
const TYPE='application/x-clipboardline-ids';

function renderer(){
 const listeners=new Map(),windowListeners=new Map(),nodes=new Map(),commands=[];
 class Element{
  constructor(){this.dataset={};this.style={};this.innerHTML='';this.textContent='';const classes=new Set();this.classList={add:value=>classes.add(value),remove:value=>classes.delete(value),contains:value=>classes.has(value)};}
  set innerHTML(value){this.htmlWrites=(this.htmlWrites||0)+1;this._innerHTML=value;}get innerHTML(){return this._innerHTML;}
  closest(){return null;}querySelector(){return null;}querySelectorAll(){return [];}matches(){return false;}setAttribute(){}focus(){}blur(){}scrollIntoView(){}contains(){return false;}
 }
 const document={body:new Element(),activeElement:null,getElementById(id){if(!nodes.has(id))nodes.set(id,new Element());return nodes.get(id);},querySelector(){return null;},querySelectorAll(){return [];},addEventListener(type,callback){if(!listeners.has(type))listeners.set(type,[]);listeners.get(type).push(callback);}};
 const ids=['00000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000002','00000000-0000-4000-8000-000000000003'],folders=['00000000-0000-4000-8000-000000000010','00000000-0000-4000-8000-000000000011'];
 const state={items:ids.map((id,index)=>({id,kind:['image','text','link'][index],name:'',title:'',text:index===1?'Synthetic text':'',url:index===2?'https://example.com/reference':'',createdAt:1000-index,pinned:index===1,retainedAt:1,folderIds:index===0?[folders[0]]:[],tags:[],trashedAt:null,mediaUrl:'appmedia://media/'+id})),folders:folders.map((id,index)=>({id,name:'Folder '+index})),settings:{visibleKinds:['image','text','link'],retentionDays:{image:30,text:30,link:30},shortcuts:{},localShortcuts:{},language:'en'},view:'library',windowVisible:true,canUndo:false};
 let subscriber;
 const api={state:async()=>structuredClone(state),subscribe(callback){subscriber=callback;},emit(patch){Object.assign(state,patch);subscriber?.(structuredClone(state));},async command(action,payload){commands.push({action,payload:structuredClone(payload)});if(action==='folder')for(const item of state.items.filter(item=>payload.ids.includes(item.id))){item.folderIds=[...new Set([...item.folderIds,payload.folderId])];if(payload.pinning!==false)item.pinned=true;}const result=structuredClone(state);subscriber?.(result);return result;}};
 const context={window:{clipboardLine:api,addEventListener(type,callback){if(!windowListeners.has(type))windowListeners.set(type,[]);windowListeners.get(type).push(callback);}},document,HTMLElement:Element,HTMLTextAreaElement:class extends Element{},Image:class{},structuredClone,console,URL,Set,Date,JSON,Math,Number,String,requestAnimationFrame:callback=>callback(),setTimeout:callback=>{queueMicrotask(callback);return 1;},clearTimeout(){}};
 vm.createContext(context);vm.runInContext(fs.readFileSync(path.join(__dirname,'../renderer.js'),'utf8'),context,{filename:'renderer.js'});
 const ready=()=>new Promise(setImmediate);
 async function dispatch(type,event={},list=listeners){event.preventDefault??=function(){this.prevented=true;};event.stopPropagation??=function(){};for(const callback of list.get(type)||[])await callback(event);await ready();return event;}
 function card(id){const element=new Element();element.dataset.itemId=id;element.closest=selector=>selector==='[data-item-id]'?element:null;return element;}
 function folder(id){const row=new Element(),button=new Element();button.dataset.folder=id;row.querySelector=selector=>selector==='[data-action="folder-scope"]'?button:null;button.closest=selector=>selector==='.folder-row'?row:selector==='[data-action="folder-scope"]'?button:null;return{row,button};}
 async function drag(id,{alt=false}={}){const values=new Map(),dataTransfer={effectAllowed:'',dropEffect:'',setData:(key,value)=>values.set(key,value),getData:key=>values.get(key)||'',get types(){return [...values.keys()];}};const event=await dispatch('dragstart',{target:card(id),altKey:alt,dataTransfer});return{...event,dataTransfer,values};}
 return{ready,dispatch,drag,folder,ids,folders,state,commands,api,get html(){return nodes.get('app').innerHTML;},get writes(){return nodes.get('app').htmlWrites;},async selectAll(){await dispatch('keydown',{target:new Element(),code:'KeyA',key:'a',ctrlKey:true,metaKey:false,altKey:false,shiftKey:false,repeat:false});},async end(){await dispatch('dragend');},async blur(){await dispatch('blur',{},windowListeners);}};
}

test('Library image and mixed selections drag onto folders additively without pinning or native file export',async()=>{
 const f=renderer();await f.ready();assert.match(f.html,/aria-description="Drag to add to a folder · Alt\+drag to export file copies"/);
 let drag=await f.drag(f.ids[0]),target=f.folder(f.folders[1]);assert.equal(drag.prevented,undefined);assert.deepEqual(JSON.parse(drag.values.get(TYPE)),[f.ids[0]]);assert.equal(f.commands.length,0);
 const over=await f.dispatch('dragover',{target:target.button,dataTransfer:drag.dataTransfer});assert.equal(over.prevented,true);assert.equal(drag.dataTransfer.dropEffect,'copy');assert.equal(target.row.classList.contains('folder-drop-target'),true);
 await f.dispatch('drop',{target:target.button,dataTransfer:drag.dataTransfer});assert.deepEqual(f.commands.at(-1),{action:'folder',payload:{ids:[f.ids[0]],folderId:f.folders[1],pinning:false}});assert.deepEqual(f.state.items[0].folderIds,f.folders);assert.equal(f.state.items[0].pinned,false);assert.equal(target.row.classList.contains('folder-drop-target'),false);
 await f.selectAll();drag=await f.drag(f.ids[1]);assert.equal(drag.prevented,undefined);assert.equal(drag.values.get('text/plain'),'Synthetic text\n\nhttps://example.com/reference');target=f.folder(f.folders[0]);await f.dispatch('drop',{target:target.button,dataTransfer:drag.dataTransfer});assert.deepEqual(f.commands.at(-1).payload,{ids:f.ids,folderId:f.folders[0],pinning:false});assert.equal(f.state.items[0].pinned,false);assert.equal(f.state.items[1].pinned,true);assert.equal(f.commands.some(value=>value.action==='startDrag'),false);
});

test('Library Alt exports and shelf native image dragging remain separate from owned internal folder drops',async()=>{
 const f=renderer();await f.ready();await f.selectAll();const drag=await f.drag(f.ids[0],{alt:true});assert.equal(drag.prevented,true);assert.deepEqual(f.commands.at(-1),{action:'startDrag',payload:{ids:f.ids}});const target=f.folder(f.folders[1]);assert.equal((await f.dispatch('dragover',{target:target.button,dataTransfer:drag.dataTransfer})).prevented,undefined);await f.dispatch('drop',{target:target.button,dataTransfer:drag.dataTransfer});assert.equal(f.commands.filter(value=>value.action==='folder').length,0);
 f.api.emit({view:'shelves'});await f.ready();const shelf=await f.drag(f.ids[0]);assert.equal(shelf.prevented,true);assert.equal(f.commands.at(-1).action,'startDrag');
});

test('ordinary state packets preserve a live internal drag DOM and ordered batch until a validated drop flushes latest state',async()=>{
 const f=renderer();await f.ready();await f.selectAll();const drag=await f.drag(f.ids[1]),target=f.folder(f.folders[1]),writes=f.writes;f.state.items[0].name='Updated during the gesture';f.api.emit({items:f.state.items,imageSearch:{available:true,indexing:true,revision:7}});await f.ready();assert.equal(f.writes,writes);assert.doesNotMatch(f.html,/Updated during the gesture/);assert.deepEqual(JSON.parse(drag.values.get(TYPE)),f.ids);await f.dispatch('dragover',{target:target.button,dataTransfer:drag.dataTransfer});await f.dispatch('drop',{target:target.button,dataTransfer:drag.dataTransfer});assert.deepEqual(f.commands.at(-1),{action:'folder',payload:{ids:f.ids,folderId:f.folders[1],pinning:false}});assert.ok(f.writes>writes);assert.match(f.html,/Updated during the gesture/);assert.equal(target.row.classList.contains('folder-drop-target'),false);
});

test('a state refresh before dragstart renders normally, then the actual gesture anchors its selection and defers later packets',async()=>{
 const f=renderer();await f.ready();const before=f.writes;f.state.items[1].name='Pre-start refresh';f.api.emit({items:f.state.items,imageSearch:{available:true,revision:3}});await f.ready();assert.ok(f.writes>before);assert.match(f.html,/Pre-start refresh/);
 const drag=await f.drag(f.ids[1]),target=f.folder(f.folders[1]),started=f.writes;assert.deepEqual(JSON.parse(drag.values.get(TYPE)),[f.ids[1]]);f.state.items[1].name='Post-start refresh';f.api.emit({items:f.state.items,imageSearch:{available:true,revision:4}});await f.ready();assert.equal(f.writes,started);assert.match(f.html,/Pre-start refresh/);assert.doesNotMatch(f.html,/Post-start refresh/);
 await f.dispatch('drop',{target:target.button,dataTransfer:drag.dataTransfer});assert.deepEqual(f.commands.at(-1),{action:'folder',payload:{ids:[f.ids[1]],folderId:f.folders[1],pinning:false}});assert.match(f.html,/Post-start refresh/);assert.ok(f.writes>started);
});

test('dragend and blur flush deferred Library updates while a replacement internal drag keeps them deferred until its own end',async()=>{
 for(const finish of ['end','blur']){const f=renderer();await f.ready();await f.drag(f.ids[0]);const writes=f.writes;f.state.items[0].name='Pending '+finish;f.api.emit({items:f.state.items});await f.ready();assert.equal(f.writes,writes);await f[finish]();assert.ok(f.writes>writes);assert.match(f.html,new RegExp('Pending '+finish));}
 const f=renderer();await f.ready();await f.drag(f.ids[0]);const writes=f.writes;f.api.emit({imageSearch:{available:true,revision:9}});await f.ready();const replacement=await f.drag(f.ids[1]);assert.equal(f.writes,writes);assert.deepEqual(JSON.parse(replacement.values.get(TYPE)),[f.ids[1]]);await f.end();assert.ok(f.writes>writes);
});

test('hidden windows, native view transitions and source/hovered-target deletion cancel live drag ownership before any drop can mutate data',async()=>{
 for(const change of ['hide','view','source','target']){const f=renderer();await f.ready();const drag=await f.drag(f.ids[0]),target=f.folder(f.folders[1]);await f.dispatch('dragover',{target:target.button,dataTransfer:drag.dataTransfer});const writes=f.writes;f.api.emit({imageSearch:{available:true,revision:5}});await f.ready();assert.equal(f.writes,writes);if(change==='hide')f.api.emit({windowVisible:false});if(change==='view')f.api.emit({view:'shelves'});if(change==='source'){f.state.items[0].trashedAt=1;f.api.emit({items:f.state.items});}if(change==='target')f.api.emit({folders:f.state.folders.filter(folder=>folder.id!==f.folders[1])});await f.ready();assert.ok(f.writes>writes,change);assert.equal(target.row.classList.contains('folder-drop-target'),false);await f.dispatch('drop',{target:target.button,dataTransfer:drag.dataTransfer});assert.equal(f.commands.some(value=>value.action==='folder'),false,change);}
});

test('folder drops ignore external, changed, trashed, ended and invalid-destination payloads',async()=>{
 const f=renderer();await f.ready();const target=f.folder(f.folders[1]),external={types:[TYPE],getData:()=>JSON.stringify([f.ids[0]])};await f.dispatch('drop',{target:target.button,dataTransfer:external});assert.equal(f.commands.length,0);
 let drag=await f.drag(f.ids[0]);drag.values.set(TYPE,JSON.stringify([f.ids[1]]));await f.dispatch('drop',{target:target.button,dataTransfer:drag.dataTransfer});assert.equal(f.commands.length,0);
 drag=await f.drag(f.ids[0]);f.state.items[0].trashedAt=1;f.api.emit({items:f.state.items});await f.ready();await f.dispatch('drop',{target:target.button,dataTransfer:drag.dataTransfer});assert.equal(f.commands.length,0);f.state.items[0].trashedAt=null;f.api.emit({items:f.state.items});await f.ready();
 drag=await f.drag(f.ids[0]);await f.end();await f.dispatch('drop',{target:target.button,dataTransfer:drag.dataTransfer});assert.equal(f.commands.length,0);
 drag=await f.drag(f.ids[0]);await f.blur();await f.dispatch('drop',{target:target.button,dataTransfer:drag.dataTransfer});assert.equal(f.commands.length,0);
 drag=await f.drag(f.ids[0]);await f.dispatch('drop',{target:f.folder('missing').button,dataTransfer:drag.dataTransfer});assert.equal(f.commands.length,0);
});

test('folder model opt-out retains existing memberships and pins while default ShiftP still pins',()=>{
 const directory=fs.mkdtempSync(path.join(os.tmpdir(),'clipboardline-folder-drop-'));
 try{const store=new Store(directory),first=store.insert('text','First'),second=store.insert('text','Second'),a=store.modify('createFolder',{name:'A'}),b=store.modify('createFolder',{name:'B'});store.modify('folder',{ids:[first.id],folderId:a.id,pinning:false});assert.equal(first.pinned,false);assert.ok(first.retainedAt!=null);store.modify('pin',{ids:[second.id],value:true});store.modify('folder',{ids:[first.id,second.id],folderId:b.id,pinning:false});store.modify('folder',{ids:[first.id],folderId:b.id,pinning:false});assert.deepEqual(first.folderIds,[a.id,b.id]);assert.equal(first.pinned,false);assert.equal(second.pinned,true);assert.throws(()=>store.modify('folder',{ids:[first.id],folderId:a.id,pinning:0}),/pin option/);assert.equal(store.item(first.id).pinned,false);store.modify('folder',{ids:[first.id],folderId:b.id});assert.equal(store.item(first.id).pinned,true);}finally{fs.rmSync(directory,{recursive:true,force:true});}
});

test('new folders have two levels while legacy deeper folders load and subtree removal keeps their saved items',()=>{
 const directory=fs.mkdtempSync(path.join(os.tmpdir(),'clipboardline-folder-tree-'));
 try{
  let store=new Store(directory);const root=store.modify('createFolder',{name:'Root'}),child=store.modify('createFolder',{name:'Child',parentId:root.id}),other=store.modify('createFolder',{name:'Other'});
  assert.throws(()=>store.modify('createFolder',{name:'Not permitted',parentId:child.id}),/top-level/);assert.equal(store.data.folders.length,3);
  const legacy='00000000-0000-4000-8000-000000000021',deeper='00000000-0000-4000-8000-000000000022';store.data.folders.push({id:legacy,name:'Legacy third level',parentId:child.id},{id:deeper,name:'Legacy fourth level',parentId:legacy});
  const item=store.insert('text','Preserve this legacy saved content');store.modify('folder',{ids:[item.id],folderId:deeper,pinning:false});store.modify('folder',{ids:[item.id],folderId:other.id,pinning:false});const retained=store.item(item.id).retainedAt;store.persist();
  store=new Store(directory);assert.equal(store.data.folders.length,5);assert.deepEqual(store.item(item.id).folderIds,[deeper,other.id]);store.modify('removeFolder',{id:root.id});
  assert.deepEqual(store.data.folders.map(folder=>folder.id),[other.id]);assert.equal(store.data.items.length,1);assert.deepEqual(store.item(item.id).folderIds,[other.id]);assert.equal(store.item(item.id).retainedAt,retained);assert.equal(store.item(item.id).text,'Preserve this legacy saved content');assert.equal(store.item(item.id).pinned,false);assert.equal(store.item(item.id).trashedAt,null);
 }finally{fs.rmSync(directory,{recursive:true,force:true});}
});
