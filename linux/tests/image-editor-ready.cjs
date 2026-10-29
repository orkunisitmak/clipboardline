'use strict';

// The editor's original is a retained native image layer. Its transparent
// overlay intentionally has no base pixels; dimensions alone still cannot
// certify that the asynchronous original and first overlay frame are ready.
function imageEditorRasterReady({width,height}){
 const canvas=document.getElementById('markup-canvas'),base=document.getElementById('markup-base');
 if(!canvas?.isConnected||canvas.width!==width||canvas.height!==height||canvas.dataset.overlayReady!=='true'
   ||!base?.isConnected||!base.complete||base.naturalWidth!==width||base.naturalHeight!==height)return false;
 try{const probe=document.createElement('canvas');probe.width=probe.height=1;const context=probe.getContext('2d');context.drawImage(base,0,0,1,1,0,0,1,1);return context.getImageData(0,0,1,1).data[3]===255;}
 catch{return false;}
}

async function waitForImageEditorRaster(page,raster){
 const loaded=await page.waitForFunction(imageEditorRasterReady,raster);
 await loaded.dispose();
}

module.exports={imageEditorRasterReady,waitForImageEditorRaster};
