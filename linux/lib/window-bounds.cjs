'use strict';
const keys=['x','y','width','height'];
const same=(left,right)=>!!left&&!!right&&keys.every(key=>left[key]===right[key]);
const copy=value=>Object.fromEntries(keys.map(key=>[key,value[key]]));

// Windows can realize frameless work-area bounds differently from the request
// or report that work-area window as maximized. Remember both sides. A repeated
// request is cheap only while the actual window still has that realized frame.
class WindowBounds {
 constructor(){this.requested=null;this.realized=null;}
 retains(window,requested){return same(this.requested,requested)&&same(this.realized,window.getBounds());}
 apply(window,requested,{overlay=false}={}){
  if(window.isMinimized())window.restore();
  const retained=overlay&&this.retains(window,requested);
  if(window.isMaximized()&&!retained)window.unmaximize();
  if(!same(window.getBounds(),requested)&&!retained)window.setBounds(requested);
  this.requested=overlay?copy(requested):null;this.realized=overlay?copy(window.getBounds()):null;
 }
 shown(window){if(this.requested)this.realized=copy(window.getBounds());}
}
module.exports={WindowBounds};
