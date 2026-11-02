'use strict';
// Behavioral coverage for private mode on the real Windows application: the
// polling fallback, an in-flight explicit capture, and a watched-folder
// debounce that outlives the watcher. Runs only in the native Windows suite.
const assert=require('node:assert/strict');
module.exports=async function privateModeAcceptance({application,check}){
 const result=await application.evaluate(async({clipboard,nativeImage})=>{
  const api=global.__clipboardLineTest,count=()=>api.store.data.items.length;
  const fs=process.getBuiltinModule('node:fs'),path=process.getBuiltinModule('node:path'),os=process.getBuiltinModule('node:os');
  const settle=async()=>{const end=Date.now()+5000;while(Date.now()<end){const value=api.getCaptureAdmissionState();if(!value.capturing&&!value.pendingClipboard)return;await new Promise(resolve=>setTimeout(resolve,25));}throw new Error('Clipboard admission did not settle.');};
  const read=async()=>{await api.readClipboard();await settle();};
  const out={},watchedFolder=fs.mkdtempSync(path.join(os.tmpdir(),'clipboardline-private-mode-'));
  try{
   // The bounded polling fallback reads once a second. A copy made during the
   // pause is never read then, so resuming has to adopt its generation itself.
   api.store.modify('setSettings',{patch:{paused:true}});
   const beforeResume=count();
   await clipboard.writeText('synthetic paused copy the fallback never read');
   await api.command('togglePause');
   await read();
   if(count()!==beforeResume)throw new Error('Resuming imported a copy made during the pause.');
   await clipboard.writeText('synthetic copy after the resume adoption');
   await read();
   if(count()!==beforeResume+1)throw new Error('Resuming blocked the next copy.');
   out.pauseResumeAdoption={beforeResume,after:count()};

   // An explicit capture that started before private mode came on must be
   // dropped after its awaits and never reach the library.
   const beforeCapture=count();
   setTimeout(()=>api.store.modify('setSettings',{patch:{paused:true}}),20);
   const refusal=await api.capture().then(()=>null,error=>error.message);
   if(count()!==beforeCapture)throw new Error('Private mode saved a screenshot taken while it was turning on.');
   if(!/Private mode is on\. New captures are paused\./.test(refusal||''))throw new Error('Private mode did not refuse the in-flight capture: '+String(refusal));
   api.store.modify('setSettings',{patch:{paused:false}});
   out.captureRacedPause=refusal;

   // A folder event whose 700 ms debounce is still pending when private mode
   // comes on must not import the file afterwards.
   api.store.modify('setSettings',{patch:{watchFolders:[watchedFolder]}});
   api.configureWatchers();
   const beforeWatch=count();
   fs.writeFileSync(path.join(watchedFolder,'synthetic-watched.png'),nativeImage.createFromDataURL('data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==').toPNG());
   await new Promise(resolve=>setTimeout(resolve,250));
   await api.command('setSettings',{patch:{paused:true}});
   await new Promise(resolve=>setTimeout(resolve,1400));
   if(count()!==beforeWatch)throw new Error('A watched-folder file was imported after private mode came on.');
   // The same folder imports normally again once capture resumes.
   await api.command('setSettings',{patch:{paused:false}});
   fs.writeFileSync(path.join(watchedFolder,'synthetic-watched-after.png'),nativeImage.createFromDataURL('data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==').toPNG());
   const end=Date.now()+6000;
   while(Date.now()<end&&count()===beforeWatch)await new Promise(resolve=>setTimeout(resolve,50));
   if(count()!==beforeWatch+1)throw new Error('A watched-folder file was not imported after the resume.');
   out.watchedFolderDebounce=true;
   return out;
  }finally{
   api.store.modify('setSettings',{patch:{paused:false,watchFolders:[]}});
   api.configureWatchers();
   try{fs.rmSync(watchedFolder,{recursive:true,force:true});}catch{}
  }
 },{});
 assert.ok(result.pauseResumeAdoption.after===result.pauseResumeAdoption.beforeResume+1);
 assert.ok(result.captureRacedPause&&result.watchedFolderDebounce);
 check('private mode adopts the paused clipboard generation on resume, drops a capture raced by the pause and cancels pending watched-folder imports',result);
};
