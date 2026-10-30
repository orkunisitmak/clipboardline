'use strict';
const fs=require('node:fs');
const path=require('node:path');
const WATCHED_MEDIA=/[.](png|jpe?g|webp|bmp|mov|mp4)$/i;
// Same shared catalog key as the macOS notice for a watched image that cannot
// be hung, so the renderer shows it in the selected language.
const IMPORT_FAILED='File could not be read or safely saved';
// Only a confirmed missing path counts as removed; an unreadable one is present.
function sourceExists(file){try{fs.lstatSync(file);return true;}catch(error){return error?.code!=='ENOENT';}}

// Watches the "Also watch folders" list. Each new image is imported once after
// its writes settle. Like macOS, a folder that cannot be watched is skipped,
// and a file removed before its import is not a failure. Any other import
// failure, including ENOENT from the library while the source still exists,
// shows the shared notice.
class FolderWatchers{
  constructor({importFile,imported,notify,closing=()=>false,watch=fs.watch,stat=fs.statSync,exists=sourceExists,delay=700}){
    Object.assign(this,{importFile,imported,notify,closing,watch,stat,exists,delay});this.active=[];
  }
  configure(folders){
    this.close();
    for(const folder of folders){
      try{
        if(!this.stat(folder).isDirectory())continue;
        const timers=new Map(),watcher=this.watch(folder,(_event,name)=>this.changed(folder,timers,name));
        watcher.on('error',()=>{});this.active.push({watcher,timers});
      }catch{}
    }
  }
  changed(folder,timers,name){
    if(!name||!WATCHED_MEDIA.test(String(name)))return;
    const file=path.join(folder,path.basename(String(name)));clearTimeout(timers.get(file));
    timers.set(file,setTimeout(()=>{timers.delete(file);
      Promise.resolve().then(()=>this.importFile(file)).then(record=>this.imported(record),error=>this.failed(file,error));
    },this.delay));
  }
  failed(file,error){
    if(this.closing()||error?.code==='ENOENT'&&!this.exists(file))return;
    this.notify(IMPORT_FAILED);
  }
  close(){for(const {watcher,timers} of this.active){watcher.close();for(const timer of timers.values())clearTimeout(timer);}this.active=[];}
}
module.exports={FolderWatchers,IMPORT_FAILED};
