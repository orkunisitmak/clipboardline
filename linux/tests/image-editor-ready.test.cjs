'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm');
const {imageEditorRasterReady}=require('./image-editor-ready.cjs');
function sample(overlay,original){
 const context=vm.createContext({document:{getElementById:id=>id==='markup-canvas'?overlay:original,createElement:()=>({getContext:()=>({drawImage(){if(original.fail)throw new Error('Synthetic unavailable pixels');},getImageData(){return{data:new Uint8ClampedArray([223,164,76,original.alpha])};}})})}});
 return vm.runInContext('('+imageEditorRasterReady.toString()+')({width:96,height:64})',context);
}
const overlay=patch=>({width:96,height:64,isConnected:true,dataset:{overlayReady:'true'},...patch});
const original=patch=>({naturalWidth:96,naturalHeight:64,isConnected:true,complete:true,alpha:255,...patch});
test('markup acceptance requires the actual decoded retained original and the first transparent overlay frame',()=>{
 assert.equal(sample(null,original()),false);
 assert.equal(sample(overlay({width:300,height:150}),original()),false);
 assert.equal(sample(overlay({dataset:{}}),original()),false);
 assert.equal(sample(overlay({isConnected:false}),original()),false);
 assert.equal(sample(overlay(),null),false);
 for(const patch of [{naturalWidth:300},{complete:false},{isConnected:false},{alpha:0},{fail:true}])assert.equal(sample(overlay(),original(patch)),false);
 assert.equal(sample(overlay(),original()),true);
});
