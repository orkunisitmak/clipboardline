'use strict';
// "Copy new screenshots to the clipboard": a screenshot or a watched-folder image
// also goes to the clipboard when the user turned the setting on, like macOS.
// Recordings and text files only hang; an item removed before the copy is left alone.
// A direct paste writes the clipboard and sends Ctrl+V; the target app reads the
// clipboard after that keystroke, so a capture arriving during a paste or within
// PASTE_SETTLE_MS after it hangs without replacing what is being pasted.
const PASTE_SETTLE_MS=1000;
function copiesNewCapture(settings,item,items,pasting=false){
  return settings?.copyNewCaptures===true&&!pasting&&item?.kind==='image'&&!item.recording&&!item.trashedAt&&Array.isArray(items)&&items.includes(item);
}
async function copyNewCapture({settings,item,items,write,pasting=false,warn=console.warn,failed=()=>{}}){
  if(!copiesNewCapture(settings,item,items,pasting))return false;
  try{await write([item]);return true;}
  catch(error){warn('New capture copy error:',error?.message||error);failed('The new screenshot was not copied');return false;}
}
module.exports={copiesNewCapture,copyNewCapture,PASTE_SETTLE_MS};
