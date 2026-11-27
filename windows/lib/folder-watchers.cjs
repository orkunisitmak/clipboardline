'use strict';
const fs=require('node:fs');
const path=require('node:path');
const {folderKey}=require('./watch-folders.cjs');
const WATCHED_MEDIA=/[.](png|jpe?g|webp|bmp|mov|mp4)$/i;
// Same shared catalog key as the macOS notice for a watched image that cannot
// be hung, so the renderer shows it in the selected language.
const IMPORT_FAILED='File could not be read or safely saved';
// Only a confirmed missing path counts as removed; an unreadable one is present.
function sourceExists(file){try{fs.lstatSync(file);return true;}catch(error){return error?.code!=='ENOENT';}}

// Watches the "Also watch folders" list and, while its setting is on, the
// system Screenshots folder. Each new image is imported once after its writes
// settle. Like macOS, a folder that cannot be watched is skipped, and a file
// removed before its import is not a failure. Any other import failure,
// including ENOENT from the library while the source still exists, shows the
// shared notice. Every skipped folder, watcher error and failed import is
// also written to the console log, as before.
class FolderWatchers{
  constructor({importFile,imported,notify,closing=()=>false,watch=fs.watch,stat=fs.statSync,exists=sourceExists,delay=700}){
    Object.assign(this,{importFile,imported,notify,closing,watch,stat,exists,delay});this.active=[];this.folders=new Set();this.timers=new Map();
  }
  // A debounced import still pending when the list changes is kept while its
  // folder stays watched and dropped when the folder stops being watched (for
  // example the screenshot setting is turned off).
  configure(folders){
    for(const watcher of this.active)watcher.close();this.active=[];
    this.folders=new Set(folders.map(folder=>folderKey(folder)));
    for(const [file,{key,timer}] of this.timers)if(!this.folders.has(key)){clearTimeout(timer);this.timers.delete(file);}
    for(const folder of folders){
      try{
        if(!this.stat(folder).isDirectory())continue;
        const watcher=this.watch(folder,(_event,name)=>this.changed(folder,name));
        watcher.on('error',error=>{console.warn('Watch folder watcher error:',error?.message||error);});this.active.push(watcher);
      }catch(error){console.warn('Watch folder configure error:',error?.message||error);}
    }
  }
  changed(folder,name){
    const key=folderKey(folder);
    // An event already queued for a watcher that has since been closed arms nothing.
    if(!this.folders.has(key)||!name||!WATCHED_MEDIA.test(String(name)))return;
    const file=path.join(folder,path.basename(String(name)));clearTimeout(this.timers.get(file)?.timer);
    this.timers.set(file,{key,timer:setTimeout(()=>{this.timers.delete(file);
      Promise.resolve().then(()=>this.importFile(file)).then(record=>this.imported(record),error=>this.failed(file,error));
    },this.delay)});
  }
  failed(file,error){
    if(this.closing()||error?.code==='ENOENT'&&!this.exists(file))return;
    console.warn('Watch folder import error:',error?.message||error);
    this.notify(IMPORT_FAILED);
  }
  close(){this.configure([]);}
}
module.exports={FolderWatchers,IMPORT_FAILED};
