'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm');
const {sampleImagePreviewGeometry,assertImagePreviewFit,sampleLinkPreviewGeometry}=require('./preview-geometry.cjs');

function renderer({auto=false,change,missing=false,complete=true}={}){
 const state={frame:auto?{x:111,y:159,width:802,height:402}:{x:112,y:160,width:800,height:400},image:auto?{x:112,y:160,width:800,height:400}:{x:114,y:161,width:796,height:398},fitted:!auto,missing,complete};
 const panel={isConnected:true,get style(){return state.fitted?{width:'800px',height:'400px'}:{width:'',height:''};},getBoundingClientRect:()=>state.frame};
 const image={isConnected:true,get complete(){return state.complete;},naturalWidth:800,naturalHeight:400,getBoundingClientRect:()=>state.image};
 let currentImage=image;
 const context=vm.createContext({document:{getElementById:id=>state.missing?null:id==='preview-dialog'?panel:currentImage},getComputedStyle:()=>({borderLeftWidth:'1px',borderRightWidth:'1px',borderTopWidth:'1px',borderBottomWidth:'1px',paddingLeft:'0px',paddingRight:'0px',paddingTop:'0px',paddingBottom:'0px',display:'flex',visibility:'visible'}),innerWidth:1024,innerHeight:720,requestAnimationFrame(callback){change?.(state,()=>{currentImage={...image};});callback();}});
 return{state,sample:()=>vm.runInContext('('+sampleImagePreviewGeometry.toString()+')()',context)};
}

test('image preview geometry compares the contained image to its actual content box, excluding borders',async()=>{
 const geometry=await renderer().sample();assert.equal(geometry.stable,true);assert.deepEqual(JSON.parse(JSON.stringify(geometry.content)),{x:113,y:161,width:798,height:398});assert.deepEqual(JSON.parse(JSON.stringify(geometry.expected)),{width:796,height:398,x:114,y:161});assertImagePreviewFit(geometry);
});

test('image preview geometry rejects the auto-size to fitted animation frame transition instead of mixing boxes',async()=>{
 const fixture=renderer({auto:true,change(state){state.frame={x:112,y:160,width:800,height:400};state.image={x:114,y:161,width:796,height:398};state.fitted=true;}});
 const transitioning=await fixture.sample();assert.equal(transitioning.ready,true);assert.equal(transitioning.stable,false);assert.equal(transitioning.dimensions.width,800);assert.equal(transitioning.displayed.width,796);assert.throws(()=>assertImagePreviewFit(transitioning),/must be fitted and stable/);
 const settled=await fixture.sample();assert.equal(settled.stable,true);assertImagePreviewFit(settled);
});

test('image preview geometry rejects a same-size replacement during the observation frame',async()=>{
 const geometry=await renderer({change(_state,replace){replace();}}).sample();assert.equal(geometry.ready,true);assert.equal(geometry.stable,false);
});

test('image preview geometry waits for loaded, connected fitted nodes',async()=>{
 for(const options of [{missing:true},{complete:false},{auto:true}]){const geometry=await renderer(options).sample();assert.equal(geometry.stable,false);assert.equal(geometry.ready,false);}
});

test('image preview fit still rejects a real inset or incorrect aspect despite stable measurements',async()=>{
 const fixture=renderer();fixture.state.image={x:118,y:163,width:788,height:394};const inset=await fixture.sample();assert.equal(inset.stable,true);assert.throws(()=>assertImagePreviewFit(inset),/must fill its aspect-fitting preview content/);
 fixture.state.image={x:114,y:161,width:796,height:380};const stretched=await fixture.sample();assert.equal(stretched.stable,true);assert.throws(()=>assertImagePreviewFit(stretched),/must fill its aspect-fitting preview content/);
});

function linkRenderer({change,...options}={}){
 const state={missing:false,complete:true,width:660,height:600,visible:true,...options};
 const image={isConnected:true,get complete(){return state.complete;},naturalWidth:480,naturalHeight:270,dataset:{letterboxRemoved:'true'}};
 let panel={isConnected:true,contains:node=>node===image,getBoundingClientRect:()=>({width:state.width,height:state.height})};
 const context=vm.createContext({document:{getElementById:id=>state.missing?null:id==='preview-dialog'?panel:image},getComputedStyle:()=>({display:state.visible?'flex':'none',visibility:'visible'}),requestAnimationFrame(callback){change?.(state,()=>{panel={...panel};});callback();}});
 return{sample:()=>vm.runInContext('('+sampleLinkPreviewGeometry.toString()+')()',context)};
}

test('link preview geometry observes the decoded thumbnail with its visible stable panel',async()=>{
 const geometry=await linkRenderer().sample();
 assert.equal(geometry.ready,true);assert.equal(geometry.stable,true);
 assert.deepEqual(JSON.parse(JSON.stringify(geometry.dimensions)),{width:660,height:600});
 assert.equal(geometry.naturalHeight,270);assert.equal(geometry.letterboxRemoved,true);
});

test('link preview geometry waits through missing or hidden previews instead of returning a null box',async()=>{
 for(const options of [{missing:true},{visible:false},{width:0},{complete:false},{change(state){state.missing=true;}}]){
  const geometry=await linkRenderer(options).sample();assert.equal(geometry.ready,false);assert.equal(geometry.stable,false);
 }
});

test('link preview geometry rejects a same-size panel replacement or a resize during observation',async()=>{
 for(const change of [(_state,replace)=>replace(),state=>{state.width=640;}]){
  const geometry=await linkRenderer({change}).sample();assert.equal(geometry.ready,true);assert.equal(geometry.stable,false);
 }
});
