'use strict';
// "Copy new screenshots to the clipboard": a screenshot or a watched-folder image
// also goes to the clipboard when the user turned the setting on, like macOS.
// Recordings and text files only hang; an item removed before the copy is left alone.
function copiesNewCapture(settings,item,items){
  return settings?.copyNewCaptures===true&&item?.kind==='image'&&!item.recording&&!item.trashedAt&&Array.isArray(items)&&items.includes(item);
}
async function copyNewCapture({settings,item,items,write,warn=console.warn}){
  if(!copiesNewCapture(settings,item,items))return false;
  try{await write([item]);return true;}
  catch(error){warn('New capture copy error:',error?.message||error);return false;}
}
module.exports={copiesNewCapture,copyNewCapture};
