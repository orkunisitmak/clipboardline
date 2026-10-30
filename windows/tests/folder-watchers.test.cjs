'use strict';
// Drives the shipped watched-folder path with real file-system events. Imports
// use the actual Store, so an unreadable image fails exactly where it would.
const {test}=require('node:test');const assert=require('node:assert/strict');const fs=require('node:fs');const os=require('node:os');const path=require('node:path');const vm=require('node:vm');
const {Store}=require('../lib/model.cjs');const {FolderWatchers,IMPORT_FAILED}=require('../lib/folder-watchers.cjs');
const png=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==','base64');
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function until(check,timeout=5000){const end=Date.now()+timeout;while(Date.now()<end){if(check())return;await sleep(20);}assert.fail('Timed out waiting for the watched folder');}
async function fixture(run,{closing=()=>false,failImport=null}={}){
 const directory=fs.mkdtempSync(path.join(os.tmpdir(),'clipboardline-watch-')),folder=path.join(directory,'Watched'),store=new Store(path.join(directory,'data'));fs.mkdirSync(folder);
 const notices=[],imported=[],watchers=new FolderWatchers({delay:150,closing,notify:message=>notices.push(message),imported:record=>imported.push(record.id),
  importFile:file=>{if(failImport)throw failImport;const stat=fs.lstatSync(file);if(!stat.isFile())throw new Error('Select a regular file.');return store.insert('image',fs.readFileSync(file));}});
 try{return await run({directory,folder,store,notices,imported,watchers});}finally{watchers.close();fs.rmSync(directory,{recursive:true,force:true});}
}

test('an unreadable image dropped into a watched folder shows the shared failure notice once',()=>fixture(async({folder,store,notices,imported,watchers})=>{
 watchers.configure([folder]);fs.writeFileSync(path.join(folder,'broken.png'),'not a png');fs.appendFileSync(path.join(folder,'broken.png'),' still writing');
 await until(()=>notices.length);await sleep(300);
 assert.deepEqual(notices,[IMPORT_FAILED]);assert.deepEqual(imported,[]);assert.equal(store.data.items.length,0);
 const context={window:{}};vm.createContext(context);vm.runInContext(fs.readFileSync(path.join(__dirname,'../locales.js'),'utf8'),context);
 assert.equal(context.window.clipboardLineTranslations.tr[IMPORT_FAILED],'Dosya okunamadı veya güvenli biçimde kaydedilemedi');
}));

test('a valid image is imported and an unrelated file is ignored without a notice',()=>fixture(async({folder,store,notices,imported,watchers})=>{
 watchers.configure([folder]);fs.writeFileSync(path.join(folder,'notes.txt'),'not watched');fs.writeFileSync(path.join(folder,'shot.png'),png);
 await until(()=>imported.length);await sleep(300);
 assert.deepEqual(notices,[]);assert.deepEqual(imported,[store.data.items[0].id]);assert.equal(store.data.items.length,1);
}));

test('a file removed before its debounced import produces no notice and no item',()=>fixture(async({folder,store,notices,imported,watchers})=>{
 watchers.configure([folder]);const file=path.join(folder,'temporary.png');fs.writeFileSync(file,png);fs.unlinkSync(file);
 await sleep(700);assert.deepEqual(notices,[]);assert.deepEqual(imported,[]);assert.equal(store.data.items.length,0);
}));

test('ENOENT from the library while the source still exists is still reported',()=>fixture(async({folder,notices,imported,watchers})=>{
 watchers.configure([folder]);fs.writeFileSync(path.join(folder,'shot.png'),png);
 await until(()=>notices.length);await sleep(300);assert.deepEqual(notices,[IMPORT_FAILED]);assert.deepEqual(imported,[]);
},{failImport:Object.assign(new Error('ENOENT: managed media directory is missing'),{code:'ENOENT'})}));

test('folders that cannot be watched are skipped like macOS and the rest keep working',()=>fixture(async({directory,folder,notices,imported,watchers})=>{
 const file=path.join(directory,'plain-file');fs.writeFileSync(file,'x');
 watchers.configure([path.join(directory,'Missing'),file,folder]);assert.deepEqual(notices,[]);
 fs.writeFileSync(path.join(folder,'shot.png'),png);await until(()=>imported.length);assert.deepEqual(notices,[]);
}));

test('reconfiguring cancels pending imports and quitting suppresses notices',async()=>{
 await fixture(async({folder,notices,imported,watchers})=>{watchers.configure([folder]);fs.writeFileSync(path.join(folder,'late.png'),png);await sleep(50);watchers.configure([]);await sleep(500);assert.deepEqual(imported,[]);assert.deepEqual(notices,[]);});
 let quitting=false;
 await fixture(async({folder,notices,watchers})=>{watchers.configure([folder]);fs.writeFileSync(path.join(folder,'broken.png'),'bad');quitting=true;await sleep(600);assert.deepEqual(notices,[]);},{closing:()=>quitting});
});
