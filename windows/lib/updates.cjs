'use strict';
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const {boundedFetch} = require('./network.cjs');
const FEED = 'https://github.com/orkunisitmak/clipboardline-desktop/releases/latest/download/windows-update.json';
const PUBLIC_KEY = 's9DO901wav4VK/hfnLROxJYk4+oNFYvxdOK974E3PgI=';
const REPOSITORY = 'orkunisitmak/clipboardline-desktop';
const UPDATE_ARGUMENTS=Object.freeze(['/S','--updated','--force-run']);
const REFRESH_THROTTLE=60_000;
// Offline OCR/semantic models increase the signed installer size. Permit a
// bounded five-minute socket wait; the authenticated exact byte/PE/hash gates
// still apply and feed checks retain their short network timeout.
const INSTALLER_DOWNLOAD_TIMEOUT=300_000;
function verifyEnvelope(bytes, publicKey = PUBLIC_KEY) {
  if (!Buffer.isBuffer(bytes) || bytes.length > 200000) throw new Error('Update manifest is too large');
  const envelope = JSON.parse(bytes.toString('utf8'));
  if (!envelope || typeof envelope.payload !== 'string' || typeof envelope.signature !== 'string' || !/^[A-Za-z0-9+/]*={0,2}$/.test(envelope.payload) || !/^[A-Za-z0-9+/]*={0,2}$/.test(envelope.signature)) throw new Error('Invalid signed update encoding');
  const payload = Buffer.from(envelope.payload, 'base64'); const signature = Buffer.from(envelope.signature, 'base64');
  const key = crypto.createPublicKey({key: Buffer.concat([Buffer.from('302a300506032b6570032100','hex'), Buffer.from(publicKey,'base64')]), format:'der',type:'spki'});
  if (signature.length !== 64 || !crypto.verify(null, payload, key, signature)) throw new Error('Update signature was rejected');
  const manifest = JSON.parse(payload.toString('utf8'));
  if (manifest.schemaVersion !== 1 || manifest.repository !== REPOSITORY || manifest.platform !== 'win32' || manifest.arch !== 'x64' ||
      !Number.isSafeInteger(manifest.build) || manifest.build < 1 || typeof manifest.version !== 'string' || manifest.version.length>100 || !/^\d+\.\d+\.\d+(?:-[a-zA-Z0-9]+(?:[.-][a-zA-Z0-9]+)*)?$/.test(manifest.version) ||
      !/^[a-f0-9]{64}$/.test(manifest.sha256) || !Number.isInteger(manifest.size) || manifest.size < 1000 || manifest.size > 1024 ** 3 ||
      typeof manifest.url !== 'string' || !/^https:\/\/github\.com\/orkunisitmak\/clipboardline-desktop\/releases\/download\/[a-zA-Z0-9._-]+\/ClipBoardLine-Setup-[a-zA-Z0-9._-]+\.exe$/.test(manifest.url)) throw new Error('Invalid Windows update metadata');
  return manifest;
}
function compareVersions(left,right){
  const split=value=>{const [core,...pre]=value.split('-');return{core:core.split('.').map(BigInt),pre:pre.join('-').split('.').filter(Boolean)};};
  const a=split(left),b=split(right);
  for(let i=0;i<3;i++){if(a.core[i]!==b.core[i])return a.core[i]>b.core[i]?1:-1;}
  if(!a.pre.length||!b.pre.length)return a.pre.length===b.pre.length?0:a.pre.length?-1:1;
  for(let i=0;i<Math.max(a.pre.length,b.pre.length);i++){
    if(a.pre[i]===undefined)return-1;if(b.pre[i]===undefined)return 1;if(a.pre[i]===b.pre[i])continue;
    const numericA=/^\d+$/.test(a.pre[i]),numericB=/^\d+$/.test(b.pre[i]);
    if(numericA&&numericB){const x=BigInt(a.pre[i]),y=BigInt(b.pre[i]);if(x!==y)return x>y?1:-1;}
    else if(numericA!==numericB)return numericA?-1:1;else return a.pre[i]>b.pre[i]?1:-1;
  }return 0;
}
function verifiedInstaller(file,manifest){
  const stat=fs.lstatSync(file);if(!stat.isFile()||stat.isSymbolicLink()||stat.size!==manifest.size)throw new Error('Installer changed after verification');
  const descriptor=fs.openSync(file,'r');let offset=0;const hash=crypto.createHash('sha256'),buffer=Buffer.alloc(1024*1024);
  try{while(true){const count=fs.readSync(descriptor,buffer,0,buffer.length,null);if(!count)break;if(offset===0&&buffer.subarray(0,2).toString()!=='MZ')throw new Error('Installer integrity check failed');hash.update(buffer.subarray(0,count));offset+=count;}}
  finally{fs.closeSync(descriptor);}
  if(offset!==manifest.size||hash.digest('hex')!==manifest.sha256)throw new Error('Installer integrity check failed');return file;
}
class Updates {
  constructor(directory, {build = 0, version='0.0.0', fetcher = boundedFetch, publicKey = PUBLIC_KEY, changed = () => {}, available=()=>{},clock=Date.now} = {}) {
    this.directory = path.resolve(directory); this.build = build;this.version=version;this.clock=clock; this.fetcher = fetcher; this.publicKey = publicKey; this.changed = changed;this.available=available;
    this.manifest=null;this.installer=null;this.envelope=null;this.announcedBuild=0;this.checkPromise=null;this.downloadPromise=null;this.installPromise=null;
    this.state = {status:'idle',message:'Updates use a public, cryptographically signed Windows channel.',error:null,checkedAt:null,lastAttemptAt:null,currentVersion:version,currentBuild:build};
    this.restore();this.derive();
  }
  newer(manifest){return manifest.build>this.build&&compareVersions(manifest.version,this.version)>=0;}
  derive(){this.state.busy=['checking','downloading','installing'].includes(this.state.status);this.state.availableVersion=this.manifest?.version||null;this.state.availableBuild=this.manifest?.build||null;this.state.canInstall=!!this.manifest&&!this.state.busy;}
  set(state) { this.state = {...this.state, ...state};this.derive();try{this.changed();}catch{} }
  safeDirectory(){fs.mkdirSync(this.directory,{recursive:true,mode:0o700});if(fs.lstatSync(this.directory).isSymbolicLink())throw new Error('Unsafe update cache');}
  cachePath(){return path.join(this.directory,'update-state.json');}
  save(){
    this.safeDirectory();const destination=this.cachePath();if(fs.existsSync(destination)&&fs.lstatSync(destination).isSymbolicLink())throw new Error('Unsafe update cache');
    const temporary=destination+'.tmp-'+crypto.randomUUID();
    try{fs.writeFileSync(temporary,JSON.stringify({envelope:this.envelope?.toString('base64'),checkedAt:this.state.checkedAt,lastAttemptAt:this.state.lastAttemptAt,announcedBuild:this.announcedBuild,installer:this.installer?path.basename(this.installer):null}),{flag:'wx',mode:0o600});fs.renameSync(temporary,destination);}
    finally{if(fs.existsSync(temporary))fs.unlinkSync(temporary);}
  }
  saveQuietly(){try{this.save();}catch{}}
  restore(){
    try{
      if(fs.lstatSync(this.directory).isSymbolicLink())return;const cache=this.cachePath(),stat=fs.lstatSync(cache);if(!stat.isFile()||stat.isSymbolicLink()||stat.size>400000)return;
      const value=JSON.parse(fs.readFileSync(cache,'utf8'));if(typeof value.envelope!=='string'||value.envelope.length>300000)return;
      const envelope=Buffer.from(value.envelope,'base64'),manifest=verifyEnvelope(envelope,this.publicKey);this.envelope=envelope;
      const date=value.checkedAt;this.state.checkedAt=Number.isFinite(date)&&date>0&&date<=this.clock()+60000?date:null;
      this.state.lastAttemptAt=this.state.checkedAt;this.announcedBuild=Number.isSafeInteger(value.announcedBuild)?value.announcedBuild:0;
      if(this.newer(manifest)){
        this.manifest=manifest;const file=path.join(this.directory,`ClipBoardLine-Setup-${manifest.build}.exe`);
        if(value.installer===path.basename(file)){try{this.installer=verifiedInstaller(file,manifest);}catch{}}
        this.state.status=this.installer?'ready':'available';this.state.message=`ClipBoardLine ${manifest.version} is available.`;this.state.version=manifest.version;
      }else{this.state.status='current';this.state.message='You are up to date.';}
    }catch{}
  }
  announce(){if(this.manifest&&this.manifest.build>this.announcedBuild){this.announcedBuild=this.manifest.build;this.saveQuietly();try{this.available({...this.manifest});}catch{}}}
  check({force=true}={}) {
    if(this.checkPromise)return this.checkPromise;
    if(this.downloadPromise||this.installPromise)return Promise.resolve(this.state);
    if(!force&&this.state.lastAttemptAt!=null&&this.clock()-this.state.lastAttemptAt<REFRESH_THROTTLE)return Promise.resolve(this.state);
    const operation=Promise.resolve().then(async()=>{
      this.set({status:'checking',message:'Checking for updates…',error:null,lastAttemptAt:this.clock()});
      try {
        const response = await this.fetcher(FEED,{maximum:200000});
        const manifest = verifyEnvelope(response.bytes, this.publicKey);
        const previous=this.manifest;this.envelope=Buffer.from(response.bytes);this.manifest=this.newer(manifest)?manifest:null;
        if(!this.manifest||previous?.build!==this.manifest.build||previous?.sha256!==this.manifest.sha256)this.installer=null;
        this.set({status:this.manifest?(this.installer?'ready':'available'):'current',version:manifest.version,message:this.manifest?`ClipBoardLine ${manifest.version} is available.`:'You are up to date.',checkedAt:this.clock(),error:null});
        this.saveQuietly();this.announce();
      } catch (error) {
        this.set({status:this.manifest?(this.installer?'ready':'available'):'error',error:String(error.message).slice(0,300),message:'Update check failed: '+String(error.message).slice(0,300)});
      }return this.state;
    });
    this.checkPromise=operation;operation.finally(()=>{if(this.checkPromise===operation)this.checkPromise=null;});return operation;
  }
  download() {
    if(this.downloadPromise)return this.downloadPromise;
    if(this.installPromise&&this.state.status==='installing')return Promise.reject(new Error('An update is already installing'));
    if(!this.manifest)return Promise.reject(new Error('Check for a signed update first'));
    const manifest={...this.manifest};
    const operation=Promise.resolve().then(async()=>{
      if(this.installer){try{return verifiedInstaller(this.installer,manifest);}catch{this.installer=null;}}
      this.set({status:'downloading',message:'Downloading verified update…',error:null});
      let temporary;
      try {
        const response = await this.fetcher(manifest.url,{maximum:manifest.size,timeout:INSTALLER_DOWNLOAD_TIMEOUT});
        if (!Buffer.isBuffer(response.bytes)||response.bytes.length !== manifest.size || crypto.createHash('sha256').update(response.bytes).digest('hex') !== manifest.sha256 || response.bytes.subarray(0,2).toString() !== 'MZ') throw new Error('Installer integrity check failed');
        this.safeDirectory();const destination=path.join(this.directory,`ClipBoardLine-Setup-${manifest.build}.exe`);
        if(fs.existsSync(destination)&&fs.lstatSync(destination).isSymbolicLink())throw new Error('Unsafe update installer');
        temporary=destination+'.tmp-'+crypto.randomUUID();fs.writeFileSync(temporary,response.bytes,{flag:'wx',mode:0o600});fs.renameSync(temporary,destination);temporary=null;
        this.installer=verifiedInstaller(destination,manifest);this.save();this.set({status:'ready',message:'Verified update is ready to install.',error:null});return destination;
      } catch(error) {this.installer=null;this.set({status:'available',error:String(error.message).slice(0,300),message:'Update download failed: '+String(error.message).slice(0,300)});throw error;}
      finally{if(temporary&&fs.existsSync(temporary))fs.unlinkSync(temporary);}
    });
    this.downloadPromise=operation;operation.then(()=>{if(this.downloadPromise===operation)this.downloadPromise=null;},()=>{if(this.downloadPromise===operation)this.downloadPromise=null;});return operation;
  }
  install(launch){
    if(this.installPromise)return this.installPromise;
    if(typeof launch!=='function')return Promise.reject(new Error('A Windows installer launcher is required'));
    const operation=Promise.resolve().then(async()=>{
      try{if(this.checkPromise)await this.checkPromise;const manifest=this.manifest?{...this.manifest}:null;if(!manifest)throw new Error('Check for a signed update first');const file=await this.download();verifiedInstaller(file,manifest);this.set({status:'installing',message:'Installing update and reopening ClipBoardLine…',error:null});await launch(file,[...UPDATE_ARGUMENTS]);return file;}
      catch(error){this.set({status:this.manifest?(this.installer?'ready':'available'):'error',error:String(error.message).slice(0,300),message:'Update installation failed: '+String(error.message).slice(0,300)});throw error;}
    });
    this.installPromise=operation;operation.then(()=>{},()=>{if(this.installPromise===operation)this.installPromise=null;});return operation;
  }
}
class AutomaticUpdateScheduler{
  constructor(updates,{enabled=()=>true,clock=Date.now,interval=3600000,retry=300000}={}){this.updates=updates;this.enabled=enabled;this.clock=clock;this.interval=interval;this.retry=retry;}
  tick({force=false}={}){
    if(!this.enabled()||this.updates.state.busy)return Promise.resolve(this.updates.state);
    const state=this.updates.state,attempt=state.lastAttemptAt;
    const due=attempt==null?0:state.error?attempt+this.retry:(state.checkedAt??attempt)+this.interval;
    return force||this.clock()>=due?this.updates.check({force}):Promise.resolve(state);
  }
}
module.exports = {Updates,AutomaticUpdateScheduler,verifyEnvelope,compareVersions,verifiedInstaller,UPDATE_ARGUMENTS,FEED,PUBLIC_KEY,REPOSITORY};
