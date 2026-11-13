'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const crypto=require('node:crypto');
const fs=require('node:fs');
const os=require('node:os');
const path=require('node:path');
const {Updates,FEED,REPOSITORY}=require('../lib/updates.cjs');

const day=24*60*60*1000;
function signedUpdate(pair,manifest){
 const payload=Buffer.from(JSON.stringify(manifest));
 return Buffer.from(JSON.stringify({payload:payload.toString('base64'),signature:crypto.sign(null,payload,pair.privateKey).toString('base64')}));
}

test('a verified installer download prunes stale generated installers and temp files only',async t=>{
 const pair=crypto.generateKeyPairSync('ed25519');
 const publicKey=pair.publicKey.export({format:'der',type:'spki'}).subarray(-32).toString('base64');
 const bytes=Buffer.alloc(2500,7);bytes.write('MZ');
 const manifest={schemaVersion:1,repository:REPOSITORY,platform:'win32',arch:'x64',version:'1.7.1',build:63,sourceRevision:'a'.repeat(40),url:`https://github.com/${REPOSITORY}/releases/download/windows-1.7.1-build63/ClipBoardLine-Setup-1.7.1-x64.exe`,size:bytes.length,sha256:crypto.createHash('sha256').update(bytes).digest('hex')};
 const directory=fs.mkdtempSync(path.join(os.tmpdir(),'clipboardline-update-cache-'));t.after(()=>fs.rmSync(directory,{recursive:true,force:true}));
 const updates=new Updates(directory,{build:62,version:'1.7.0',publicKey,fetcher:async url=>({bytes:url===FEED?signedUpdate(pair,manifest):bytes})});
 await updates.check();const current=await updates.download();
 const staleInstaller=path.join(directory,'ClipBoardLine-Setup-61.exe');
 const staleTemporary=path.join(directory,`ClipBoardLine-Setup-60.exe.tmp-${crypto.randomUUID()}`);
 const recentInstaller=path.join(directory,'ClipBoardLine-Setup-59.exe');
 const futureInstaller=path.join(directory,'ClipBoardLine-Setup-58.exe');
 for(const file of [staleInstaller,staleTemporary,recentInstaller,futureInstaller])fs.writeFileSync(file,bytes);
 const now=Date.now(),stale=now-11*day,future=now+day;
 fs.utimesSync(staleInstaller,stale/1000,stale/1000);fs.utimesSync(staleTemporary,stale/1000,stale/1000);
 fs.utimesSync(recentInstaller,(now-day)/1000,(now-day)/1000);fs.utimesSync(futureInstaller,future/1000,future/1000);
 manifest.version='1.7.2';manifest.build=64;manifest.url=`https://github.com/${REPOSITORY}/releases/download/windows-1.7.2-build64/ClipBoardLine-Setup-1.7.2-x64.exe`;
 await updates.check();assert.equal(fs.existsSync(staleInstaller),true);assert.equal(fs.existsSync(staleTemporary),true);
 updates.fetcher=async()=>{throw new Error('offline');};await assert.rejects(updates.download(),/offline/);
 assert.equal(fs.existsSync(staleInstaller),true);assert.equal(fs.existsSync(staleTemporary),true);
 updates.fetcher=async url=>({bytes:url===FEED?signedUpdate(pair,manifest):bytes});
 const latest=await updates.download();assert.equal(fs.existsSync(current),true);assert.equal(fs.existsSync(latest),true);
 assert.equal(fs.existsSync(staleInstaller),false);assert.equal(fs.existsSync(staleTemporary),false);
 assert.equal(fs.existsSync(recentInstaller),true);assert.equal(fs.existsSync(futureInstaller),true);
 const staleAfterDownload=path.join(directory,'ClipBoardLine-Setup-57.exe');fs.writeFileSync(staleAfterDownload,bytes);fs.utimesSync(staleAfterDownload,stale/1000,stale/1000);
 fs.utimesSync(latest,stale/1000,stale/1000);
 assert.equal(await updates.download(),latest);assert.equal(fs.existsSync(latest),true);assert.equal(fs.existsSync(staleAfterDownload),false);
});

