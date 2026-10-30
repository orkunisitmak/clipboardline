'use strict';
const fs=require('node:fs'),path=require('node:path');
const MARKER='.clipboardline-drag.json',OWNER='clipboardline-native-drag-v1';
function regular(file){const value=fs.lstatSync(file);return value.isFile()&&!value.isSymbolicLink();}
class DragFiles {
  constructor(directory){
    this.directory=path.join(path.resolve(directory),'native-drag');this.batches=new Set();
    fs.mkdirSync(this.directory,{recursive:true,mode:0o700});const value=fs.lstatSync(this.directory);
    if(!value.isDirectory()||value.isSymbolicLink())throw new Error('Unsafe drag staging directory');
    // A single app instance owns this user-data folder. Remove only verified
    // generated batches left by an interrupted previous instance.
    for(const name of fs.readdirSync(this.directory))if(/^batch-[A-Za-z0-9]{6}$/.test(name))this.remove(path.join(this.directory,name));
  }
  prepare(selected,mediaPath){
    if(!Array.isArray(selected)||!selected.length||selected.length>1000)throw new Error('Select up to 1000 items to drag.');
    const records=selected.map(value=>{
      if(!value||typeof value.id!=='string'||!/^[-0-9a-f]{36}$/.test(value.id)||!['image','text','link'].includes(value.kind)||value.trashedAt)throw new Error('A dragged item is no longer available.');
      if(value.kind!=='image'&&(typeof(value.kind==='link'?value.url:value.text)!=='string'||Buffer.byteLength(value.kind==='link'?value.url:value.text,'utf8')>1024*1024))throw new Error('Invalid drag content.');
      if(value.kind==='link'){let url;try{url=new URL(value.url);}catch{}if(!url||!['http:','https:'].includes(url.protocol)||/[\r\n\0]/.test(value.url))throw new Error('Invalid dragged link.');}
      return{id:value.id,kind:value.kind,text:value.text,url:value.url};
    });
    let batch,generated=[];
    try{
      if(records.some(value=>value.kind!=='image')){
        batch=fs.mkdtempSync(path.join(this.directory,'batch-'));fs.chmodSync(batch,0o700);
        const names=records.flatMap((value,index)=>value.kind==='image'?[]:[String(index+1).padStart(4,'0')+'-'+value.id+(value.kind==='link'?'.url':'.txt')]);
        fs.writeFileSync(path.join(batch,MARKER),JSON.stringify({owner:OWNER,files:names}),{flag:'wx',mode:0o600});
      }
      const files=records.map((value,index)=>{
        if(value.kind==='image'){const file=mediaPath(value.id);if(!regular(file))throw new Error('Managed image is unavailable.');return file;}
        // UUID/index-only labels never reveal copied API keys, titles or URLs.
        const name=String(index+1).padStart(4,'0')+'-'+value.id+(value.kind==='link'?'.url':'.txt');
        const file=path.join(batch,name),bytes=value.kind==='link'?'[InternetShortcut]\r\nURL='+value.url+'\r\n':value.text;
        fs.writeFileSync(file,bytes,{flag:'wx',mode:0o600});generated.push(name);return file;
      });
      if(batch)this.batches.add(batch);
      return{files,batch};
    }catch(error){
      if(batch){for(const name of generated){try{fs.unlinkSync(path.join(batch,name));}catch{}}try{fs.unlinkSync(path.join(batch,MARKER));}catch{}try{fs.rmdirSync(batch);}catch{}}
      throw error;
    }
  }
  remove(batch){
    try{
      if(path.dirname(batch)!==this.directory||!/^batch-[A-Za-z0-9]{6}$/.test(path.basename(batch)))return false;
      const stat=fs.lstatSync(batch);if(!stat.isDirectory()||stat.isSymbolicLink())return false;
      const marker=path.join(batch,MARKER);if(!regular(marker)||fs.statSync(marker).size>100000)return false;
      const value=JSON.parse(fs.readFileSync(marker,'utf8'));
      if(value.owner!==OWNER||!Array.isArray(value.files)||value.files.length>1000||new Set(value.files).size!==value.files.length||value.files.some(name=>typeof name!=='string'||!/^\d{4}-[-0-9a-f]{36}\.(txt|url)$/.test(name)))return false;
      const expected=new Set([...value.files,MARKER]),actual=fs.readdirSync(batch);
      if(actual.length>expected.size||actual.some(name=>!expected.has(name)||!regular(path.join(batch,name))))return false;
      for(const name of value.files)if(actual.includes(name))fs.unlinkSync(path.join(batch,name));fs.unlinkSync(marker);fs.rmdirSync(batch);this.batches.delete(batch);return true;
    }catch{return false;}
  }
  dispose(){for(const batch of this.batches)this.remove(batch);}
}
module.exports={DragFiles};
