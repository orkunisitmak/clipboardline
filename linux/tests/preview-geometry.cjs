'use strict';
const assert=require('node:assert/strict');

// Sent directly to the renderer by Playwright. A locator boundingBox pair can
// straddle the requestAnimationFrame that fits the newly loaded image: its first
// box then describes the intrinsic auto-sized panel and its second the fitted
// image. Read every box in one task, then require the same nodes and geometry on
// the next animation frame before checking the actual content-box contain fit.
async function sampleImagePreviewGeometry(){
 const box=node=>{const rect=node.getBoundingClientRect();return{x:rect.x,y:rect.y,width:rect.width,height:rect.height};};
 const read=()=>{
  const panel=document.getElementById('preview-dialog'),image=document.getElementById('preview-media');
  if(!panel||!image)return{ready:false,reason:'preview nodes missing'};
  const dimensions=box(panel),displayed=box(image),style=getComputedStyle(panel),pixels=key=>parseFloat(style[key])||0;
  const left=pixels('borderLeftWidth')+pixels('paddingLeft'),right=pixels('borderRightWidth')+pixels('paddingRight'),top=pixels('borderTopWidth')+pixels('paddingTop'),bottom=pixels('borderBottomWidth')+pixels('paddingBottom');
  const content={x:dimensions.x+left,y:dimensions.y+top,width:dimensions.width-left-right,height:dimensions.height-top-bottom};
  const natural={width:image.naturalWidth,height:image.naturalHeight},scale=Math.min(1,content.width/natural.width,content.height/natural.height),expected={width:natural.width*scale,height:natural.height*scale};expected.x=content.x+(content.width-expected.width)/2;expected.y=content.y+(content.height-expected.height)/2;
  const fitted={width:panel.style.width,height:panel.style.height},viewport={width:innerWidth,height:innerHeight};
  const geometry={dimensions,displayed,content,natural,expected,fitted,viewport};
  return{panel,image,geometry,ready:panel.isConnected&&image.isConnected&&image.complete&&natural.width>0&&natural.height>0&&content.width>0&&content.height>0&&!!fitted.width&&!!fitted.height&&style.display!=='none'&&style.visibility!=='hidden'};
 };
 const first=read();await new Promise(resolve=>requestAnimationFrame(resolve));const next=read();
 return{...next.geometry,ready:!!next.ready,reason:next.reason,stable:!!first.ready&&!!next.ready&&first.panel===next.panel&&first.image===next.image&&JSON.stringify(first.geometry)===JSON.stringify(next.geometry)};
}

function assertImagePreviewFit(geometry){
 assert.ok(geometry.ready&&geometry.stable,'The image preview must be fitted and stable: '+JSON.stringify(geometry));
 const {dimensions,displayed,expected,natural,content}=geometry;
 assert.ok(dimensions.width>100&&Math.abs(dimensions.width/dimensions.height-natural.width/natural.height)<.035,'The preview frame must follow the source aspect: '+JSON.stringify(geometry));
 assert.ok(content.x>=dimensions.x&&content.y>=dimensions.y&&content.width<=dimensions.width&&content.height<=dimensions.height,'Preview content must remain inside its border box: '+JSON.stringify(geometry));
 for(const key of ['x','y','width','height'])assert.ok(Math.abs(displayed[key]-expected[key])<=1,'The image must fill its aspect-fitting preview content ('+key+'): '+JSON.stringify(geometry));
}

// Thumbnail decoding can trigger a native state packet that replaces the
// preview between a separate image-ready check and a locator boundingBox().
// Observe the thumbnail and its own visible panel together on two frames.
// A disappearing or replaced preview remains pending instead of returning a
// null box (or accidentally accepting the next preview's dimensions).
async function sampleLinkPreviewGeometry(){
 const read=()=>{
  const panel=document.getElementById('preview-dialog'),image=document.getElementById('preview-link-media');
  if(!panel||!image||!panel.contains(image))return{ready:false,reason:'link preview nodes missing'};
  const rect=panel.getBoundingClientRect(),style=getComputedStyle(panel);
  const geometry={dimensions:{width:rect.width,height:rect.height},naturalHeight:image.naturalHeight,letterboxRemoved:image.dataset.letterboxRemoved==='true'};
  return{panel,image,geometry,ready:panel.isConnected&&image.isConnected&&image.complete&&image.naturalWidth>0&&image.naturalHeight>0&&rect.width>0&&rect.height>0&&style.display!=='none'&&style.visibility!=='hidden'};
 };
 const first=read();await new Promise(resolve=>requestAnimationFrame(resolve));const next=read();
 return{...next.geometry,ready:!!next.ready,reason:next.reason,stable:!!first.ready&&!!next.ready&&first.panel===next.panel&&first.image===next.image&&JSON.stringify(first.geometry)===JSON.stringify(next.geometry)};
}

module.exports={sampleImagePreviewGeometry,assertImagePreviewFit,sampleLinkPreviewGeometry};
