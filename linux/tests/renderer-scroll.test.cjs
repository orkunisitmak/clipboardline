'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
function renderer(){
 const nodes=new Map(),ranges=new Map(),frames=[],listeners=new Map();let document,root;
 class Element{
  constructor(id=''){this.id=id;this.dataset={};this.style={};this.scrollTop=0;this.scrollLeft=0;this.scrollHeight=1200;this.clientHeight=300;this.scrollWidth=1000;this.clientWidth=400;this.classList={contains:()=>false};}
  matches(){return this.id.startsWith('detail-')||this.id==='search-input';}closest(){return null;}setAttribute(){}querySelectorAll(){return [];}querySelector(selector){return nodes.get(selector)||null;}focus(){document.activeElement=this;if(nodes.get('.library-results'))nodes.get('.library-results').scrollTop=999;}setSelectionRange(start,end){this.selectionStart=start;this.selectionEnd=end;}scrollIntoView(){const results=nodes.get('.library-results');if(results)results.scrollTop=777;}
  set innerHTML(value){this._html=value;if(this!==root)return;nodes.clear();for(const selector of ['.library-results','.sidebar','.inspector','.settings-main','.settings-tabs','#detail-text','#detail-note','.shelf[data-shelf="image"] .cards','.shelf[data-shelf="text"] .cards','.shelf[data-shelf="link"] .cards']){
    const marker=selector.startsWith('#')?'id="'+selector.slice(1)+'"':selector.startsWith('.shelf')?'data-shelf="'+selector.match(/data-shelf="([^"]+)"/)[1]+'"':'class="'+selector.slice(1)+'"';if(!value.includes(marker))continue;const node=new Element(selector.startsWith('#')?selector.slice(1):'');Object.assign(node,ranges.get(selector)||{});nodes.set(selector,node);
   }
   for(const name of ['name','text','note']){const id='detail-'+name,match=value.match(new RegExp('id="'+id+'" data-detail-id="([^"]+)"'));if(!match)continue;const node=nodes.get('#'+id)||new Element(id);node.dataset={detailId:match[1],focus:id};node.value=name==='name'?value.match(/id="detail-name"[^>]+value="([^"]*)"/)?.[1]:value.match(new RegExp('id="'+id+'"[^>]*>([^<]*)<'))?.[1];node.selectionStart=0;node.selectionEnd=0;nodes.set('#'+id,node);}
   const search=new Element('search-input');search.value='';nodes.set('#search-input',search);document.activeElement=document.body;
  }get innerHTML(){return this._html||'';}
 }
 root=new Element('app');const overlay=new Element('overlay-root');document={body:new Element('body'),activeElement:null,getElementById:id=>id==='app'?root:id==='overlay-root'?overlay:id==='toast'?new Element(id):nodes.get('#'+id)||null,querySelector:selector=>nodes.get(selector)||null,querySelectorAll:()=>[],addEventListener:(type,callback)=>listeners.set(type,callback)};
 const ids=['00000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000002'];let raw={items:ids.map((id,index)=>({id,kind:'text',name:['First','Second'][index],text:['First body','Second body'][index],note:'Note '+index,pinned:false,retainedAt:1,folderIds:[],tags:[],createdAt:20-index,updatedAt:20-index})),folders:[],settings:{visibleKinds:['image','text','link'],retentionDays:{image:30,text:30,link:30},localShortcuts:{},shortcuts:{},language:'en'},view:'library',windowVisible:true,canUndo:false};let subscriber;
 const api={state:async()=>structuredClone(raw),subscribe:callback=>subscriber=callback,command:async()=>structuredClone(raw)};
 const context={window:{clipboardLine:api,addEventListener(){}},document,HTMLElement:Element,HTMLTextAreaElement:class extends Element{},Image:class{},console,structuredClone,URL,Set,Map,Date,Math,Number,String,JSON,setTimeout:()=>1,clearTimeout(){},requestAnimationFrame:callback=>frames.push(callback)};vm.createContext(context);
 const source=fs.readFileSync(path.join(__dirname,'../renderer.js'),'utf8').replace(/\}\)\(\);\s*$/,'window.__scrollTest={ui,render,select,revealFocused};})();');vm.runInContext(source,context);
 return{ids,nodes,ranges,frames,context,ready:()=>new Promise(setImmediate),get settings(){return raw.settings;},get ui(){return context.window.__scrollTest.ui;},render:()=>context.window.__scrollTest.render(),select:id=>context.window.__scrollTest.select(raw.items.find(value=>value.id===id)),emit(patch){raw={...raw,...patch};subscriber(structuredClone(raw));},focus(id){document.activeElement=nodes.get('#'+id);},reveal(){context.window.__scrollTest.revealFocused();},get active(){return document.activeElement;}};
}
const position=node=>[node.scrollTop,node.scrollLeft];
test('ordinary same-context packets preserve independent Library viewports and clamp changed content ranges',async()=>{
 const f=renderer();await f.ready();for(const [selector,top,left]of [['.library-results',240,120],['.sidebar',180,20],['.inspector',210,40],['#detail-text',70,10],['#detail-note',50,5]]){const node=f.nodes.get(selector);node.scrollTop=top;node.scrollLeft=left;}
 f.emit({imageSearch:{revision:2,available:true}});assert.deepEqual(position(f.nodes.get('.library-results')),[240,120]);assert.deepEqual(position(f.nodes.get('.sidebar')),[180,20]);assert.deepEqual(position(f.nodes.get('.inspector')),[210,40]);assert.deepEqual(position(f.nodes.get('#detail-text')),[70,10]);
 f.ranges.set('.library-results',{scrollHeight:330,clientHeight:300,scrollWidth:425,clientWidth:400});f.emit({imageSearch:{revision:3}});assert.deepEqual(position(f.nodes.get('.library-results')),[30,25]);
});
test('Library query, scope, view mode and selection boundaries reset only their changed viewport context',async()=>{
 const f=renderer();await f.ready();for(const selector of ['.library-results','.sidebar','.inspector'])f.nodes.get(selector).scrollTop=200;
 f.ui.search='First';f.render();assert.equal(f.nodes.get('.library-results').scrollTop,0);assert.equal(f.nodes.get('.sidebar').scrollTop,200);assert.equal(f.nodes.get('.inspector').scrollTop,200);
 f.ui.search='';f.render();f.nodes.get('.inspector').scrollTop=200;f.select(f.ids[1]);f.render();assert.equal(f.nodes.get('.inspector').scrollTop,0);
 f.nodes.get('.library-results').scrollTop=200;f.ui.list=true;f.render();assert.equal(f.nodes.get('.library-results').scrollTop,0);
 f.nodes.get('.library-results').scrollTop=200;f.ui.scope='recent';f.render();assert.equal(f.nodes.get('.library-results').scrollTop,0);assert.equal(f.nodes.get('.sidebar').scrollTop,200);
});
test('a committed list-mode projection establishes its new context before same-context horizontal preservation is measured',async()=>{
 const f=renderer();await f.ready();f.nodes.get('.library-results').scrollTop=240;f.nodes.get('.library-results').scrollLeft=120;f.ui.list=true;f.render();assert.deepEqual(position(f.nodes.get('.library-results')),[0,0]);
 f.emit({settings:{...f.settings,libraryListMode:true}});f.nodes.get('.library-results').scrollTop=160;f.nodes.get('.library-results').scrollLeft=100;f.emit({imageSearch:{revision:15}});assert.deepEqual(position(f.nodes.get('.library-results')),[160,100]);
});

test('Settings keep same-tab scroll but reset on tab, query, surface and hidden-session changes',async()=>{
 const f=renderer();await f.ready();f.emit({view:'settings'});f.ui.settingsTab='shortcuts';f.render();f.nodes.get('.settings-main').scrollTop=230;f.nodes.get('.settings-tabs').scrollTop=50;f.emit({imageSearch:{revision:5}});assert.equal(f.nodes.get('.settings-main').scrollTop,230);assert.equal(f.nodes.get('.settings-tabs').scrollTop,50);
 f.ui.shortcutsQuery='pin';f.render();assert.equal(f.nodes.get('.settings-main').scrollTop,0);f.nodes.get('.settings-main').scrollTop=210;f.ui.settingsTab='general';f.render();assert.equal(f.nodes.get('.settings-main').scrollTop,0);
 f.emit({view:'library'});f.nodes.get('.library-results').scrollTop=200;f.emit({windowVisible:false});f.emit({windowVisible:true});assert.equal(f.nodes.get('.library-results').scrollTop,0);
});
test('explicit keyboard reveal remains authoritative after restoring an unchanged Library viewport',async()=>{
 const f=renderer();await f.ready();f.nodes.get('.library-results').scrollTop=200;f.render();assert.equal(f.nodes.get('.library-results').scrollTop,200);const selected=new f.context.HTMLElement();f.nodes.set('[data-item-id="'+f.ids[0]+'"]',selected);f.reveal();for(const frame of f.frames)frame();assert.equal(f.nodes.get('.library-results').scrollTop,777);
});
test('a native inspector item change renders its own body instead of copying the previous focused field value',async()=>{
 const f=renderer();await f.ready();const first=f.nodes.get('#detail-text');first.value='Only first-record draft';f.focus('detail-text');f.emit({viewEvent:{selectId:f.ids[1],kind:'text'}});assert.equal(f.nodes.get('#detail-text').dataset.detailId,f.ids[1]);assert.equal(f.nodes.get('#detail-text').value,'Second body');assert.notEqual(f.active,f.nodes.get('#detail-text'));
});
