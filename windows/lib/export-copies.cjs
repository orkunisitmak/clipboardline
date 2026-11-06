'use strict';
const fs=require('node:fs');
const path=require('node:path');
const {linkFile}=require('./link-file.cjs');

// Windows opens these device names whatever follows the first dot, so a copy
// named "con" would report success and leave no file on disk.
const RESERVED=/^(?:con|prn|aux|nul|com[1-9¹²³]|lpt[1-9¹²³])(?=\.|$)/i;
// UTF-16 slicing can split a supplementary character; do not export a replacement glyph.

// Match the Mac export: keep copying after one failure, then report both
// counts with the shared "Exported %d · failed %d" catalog template.
async function exportCopies(selected,directory,{mediaPath}){
  let exported=0,failed=0;
  for(const item of selected){try{const label=(item.name||item.title||item.kind).replace(/[<>:"/\\|?*\x00-\x1F]/g,'-').replace(/[. ]+$/g,'').slice(0,100).replace(/[\uD800-\uDBFF]$/,'').replace(RESERVED,'_$&')||item.kind;const link=item.kind==='link'?linkFile(item.url):null,extension=item.kind==='image'?(item.recording?path.extname(mediaPath(item.id)):'.png'):link?link.extension:'.txt';let index=1,destination;
    do{destination=path.join(directory,label+(index>1?'-'+index:'')+extension);index++;}while(fs.existsSync(destination));
    if(item.kind==='image')await fs.promises.copyFile(mediaPath(item.id),destination,fs.constants.COPYFILE_EXCL);
    else fs.writeFileSync(destination,Buffer.from(link?link.bytes:item.text),{flag:'wx'});
    exported++;}catch{failed++;}
  }
  if(!exported)throw new Error('Could not export copies');
  return{count:exported,failed,message:`Exported ${exported} · failed ${failed}`};
}
module.exports={exportCopies};
