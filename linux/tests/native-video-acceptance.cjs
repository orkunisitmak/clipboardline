'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),os=require('node:os'),crypto=require('node:crypto'),zlib=require('node:zlib');
const {MediaJobs}=require('../lib/media.cjs'),{Store}=require('../lib/model.cjs');
function pngCenter(file){
 const bytes=fs.readFileSync(file);assert.equal(bytes.subarray(0,8).toString('hex'),'89504e470d0a1a0a');let at=8,width,height,color,depth,interlace;const parts=[];
 while(at+12<=bytes.length){const length=bytes.readUInt32BE(at),type=bytes.toString('ascii',at+4,at+8),data=bytes.subarray(at+8,at+8+length);if(type==='IHDR'){width=data.readUInt32BE(0);height=data.readUInt32BE(4);depth=data[8];color=data[9];interlace=data[12];}if(type==='IDAT')parts.push(data);at+=length+12;}
 assert.equal(depth,8);assert.equal(interlace,0);assert.ok([2,6].includes(color),`Unsupported acceptance PNG ${color}`);const channels=color===6?4:3,rowBytes=width*channels,raw=zlib.inflateSync(Buffer.concat(parts)),decoded=Buffer.alloc(height*rowBytes);let input=0;
 for(let y=0;y<height;y++){const filter=raw[input++];for(let x=0;x<rowBytes;x++){const left=x>=channels?decoded[y*rowBytes+x-channels]:0,up=y?decoded[(y-1)*rowBytes+x]:0,upperLeft=y&&x>=channels?decoded[(y-1)*rowBytes+x-channels]:0;let predict=0;if(filter===1)predict=left;else if(filter===2)predict=up;else if(filter===3)predict=Math.floor((left+up)/2);else if(filter===4){const p=left+up-upperLeft,dl=Math.abs(p-left),du=Math.abs(p-up),dul=Math.abs(p-upperLeft);predict=dl<=du&&dl<=dul?left:du<=dul?up:upperLeft;}else assert.equal(filter,0);decoded[y*rowBytes+x]=(raw[input++]+predict)&255;}}
 const index=(Math.floor(height/2)*width+Math.floor(width/2))*channels;return{width,height,rgb:[...decoded.subarray(index,index+3)]};
}
function pcmTone(file){
 const bytes=fs.readFileSync(file);assert.equal(bytes.toString('ascii',0,4),'RIFF');assert.equal(bytes.toString('ascii',8,12),'WAVE');let format,data;
 for(let at=12;at+8<=bytes.length;){const type=bytes.toString('ascii',at,at+4),length=bytes.readUInt32LE(at+4),chunk=bytes.subarray(at+8,Math.min(bytes.length,at+8+length));if(type==='fmt ')format={tag:chunk.readUInt16LE(0),channels:chunk.readUInt16LE(2),sampleRate:chunk.readUInt32LE(4),bits:chunk.readUInt16LE(14)};if(type==='data')data=chunk;at+=8+length+(length&1);}
 assert.ok(format&&data);assert.ok([1,65534].includes(format.tag),JSON.stringify(format));assert.equal(format.bits,16);let square=0,crossings=0,previous=0,count=0;for(let at=0;at+2<=data.length;at+=2*format.channels){const sample=data.readInt16LE(at)/32768;square+=sample*sample;if(sample>=0&&previous<0)crossings++;previous=sample;count++;}const duration=count/format.sampleRate,rms=Math.sqrt(square/count),hz=crossings/duration;assert.ok(rms>.01&&rms<.9,`Decoded audio RMS ${rms}`);assert.ok(hz>420&&hz<460,`Decoded tone ${hz}Hz`);return{...format,durationMs:duration*1000,rms,hz};
}
async function runNativeVideo({fixtureDirectory=path.join(__dirname,'fixtures','recordings'),outputDirectory=process.env.CLIPBOARDLINE_VIDEO_VALIDATION||path.join(os.tmpdir(),'clipboardline-video-evidence')}={}){
 if(process.platform!=='win32')throw new Error('Recording acceptance requires an actual Windows host.');
 const directory=fs.mkdtempSync(path.join(os.tmpdir(),'clipboardline-native-video-')),store=new Store(directory),jobs=new MediaJobs({directory:path.join(directory,'jobs')}),evidence={hostPlatform:process.platform,engine:'Windows.Media.Editing',sourceRevision:process.env.GITHUB_SHA||'',checks:[]};
 fs.mkdirSync(outputDirectory,{recursive:true});
 try{
  for(const extension of ['mp4','mov']){
   const source=path.join(fixtureDirectory,'synthetic-rgb-tone.'+extension),before=crypto.createHash('sha256').update(fs.readFileSync(source)).digest('hex');let inspected,trimmed;
   try{
    inspected=await jobs.probe(source,{verifyAudio:true});assert.ok(Math.abs(inspected.durationMs-6000)<200);assert.equal(inspected.width,160);assert.equal(inspected.height,120);assert.ok(inspected.audioTracks>0);const first=pngCenter(inspected.posterFile);assert.ok(first.rgb[0]>150&&first.rgb[1]<100&&first.rgb[2]<100,JSON.stringify(first));const originalAudio=pcmTone(inspected.audioFile);
    const record=await store.insertRecording(inspected),fingerprint=store.publicState().items.find(item=>item.id===record.id).sourceFingerprint;store.modify('name',{id:record.id,name:'Synthetic recording '+extension});const originalFile=store.mediaPath(record.id,true);
    trimmed=await jobs.trim(store.mediaPath(record.id),{startMs:2000,endMs:4000,verifyAudio:true});assert.ok(Math.abs(trimmed.durationMs-2000)<150);assert.equal(trimmed.width,160);assert.equal(trimmed.height,120);const poster=pngCenter(trimmed.posterFile);assert.ok(poster.rgb[1]>100&&poster.rgb[0]<100&&poster.rgb[2]<100,JSON.stringify(poster));const trimmedAudio=pcmTone(trimmed.audioFile);assert.ok(Math.abs(trimmedAudio.durationMs-2000)<200);
    await store.commitRecordingTrim({id:record.id,sourceFingerprint:fingerprint,...trimmed});assert.equal(store.mediaPath(record.id,true),originalFile);assert.notEqual(store.mediaPath(record.id),originalFile);assert.equal(store.item(record.id).name,'Synthetic recording '+extension);assert.equal(crypto.createHash('sha256').update(fs.readFileSync(source)).digest('hex'),before);assert.equal(crypto.createHash('sha256').update(fs.readFileSync(originalFile)).digest('hex'),before);
    evidence.checks.push({extension,passed:true,sourceDurationMs:inspected.durationMs,trimmedDurationMs:trimmed.durationMs,sourcePoster:first,trimmedPoster:poster,originalAudio,trimmedAudio});
   }finally{if(inspected)jobs.release(inspected);if(trimmed)jobs.release(trimmed);}
  }
  {
   const source=path.join(fixtureDirectory,'synthetic-rgb-silent.mp4'),before=crypto.createHash('sha256').update(fs.readFileSync(source)).digest('hex');let inspected,trimmed;
   try{
    // This file has no audio track at all. WinRT's actual vector size must be
    // zero; PowerShell's scalar RCW Count=1 cannot satisfy this assertion.
    inspected=await jobs.probe(source);assert.ok(Math.abs(inspected.durationMs-6000)<200);assert.equal(inspected.width,160);assert.equal(inspected.height,120);assert.equal(inspected.audioTracks,0);assert.equal(inspected.audioFile,undefined);
    const first=pngCenter(inspected.posterFile);assert.ok(first.rgb[0]>150&&first.rgb[1]<100&&first.rgb[2]<100,JSON.stringify(first));
    trimmed=await jobs.trim(source,{startMs:2000,endMs:4000});assert.ok(Math.abs(trimmed.durationMs-2000)<150);assert.equal(trimmed.width,160);assert.equal(trimmed.height,120);assert.equal(trimmed.audioTracks,0);assert.equal(trimmed.audioFile,undefined);
    const poster=pngCenter(trimmed.posterFile);assert.ok(poster.rgb[1]>100&&poster.rgb[0]<100&&poster.rgb[2]<100,JSON.stringify(poster));assert.equal(crypto.createHash('sha256').update(fs.readFileSync(source)).digest('hex'),before);
    evidence.checks.push({fixture:'synthetic-rgb-silent.mp4',passed:true,sourceDurationMs:inspected.durationMs,trimmedDurationMs:trimmed.durationMs,sourceAudioTracks:inspected.audioTracks,trimmedAudioTracks:trimmed.audioTracks,sourcePoster:first,trimmedPoster:poster,originalPreserved:true});
   }finally{if(inspected)jobs.release(inspected);if(trimmed)jobs.release(trimmed);}
  }
  const source=path.join(fixtureDirectory,'synthetic-rgb-tone.mp4'),before=crypto.createHash('sha256').update(fs.readFileSync(source)).digest('hex'),controller=new AbortController(),pending=jobs.probe(source,{signal:controller.signal});setTimeout(()=>controller.abort(),10);
  await assert.rejects(pending,error=>error.name==='AbortError');assert.equal(crypto.createHash('sha256').update(fs.readFileSync(source)).digest('hex'),before);assert.equal(fs.readdirSync(jobs.directory).length,0);
  const unsupported=path.join(directory,'unsupported.mp4');fs.writeFileSync(unsupported,Buffer.from('00000000000000000000000066747970','hex'));await assert.rejects(jobs.probe(unsupported),/codec|incomplete|decode|process/i);assert.equal(fs.readdirSync(jobs.directory).length,0);assert.equal(crypto.createHash('sha256').update(fs.readFileSync(source)).digest('hex'),before);
  evidence.checks.push({cancellation:true,unsupportedRejected:true,originalPreserved:true,tempJobsCleaned:true});
  fs.writeFileSync(path.join(outputDirectory,'native-video.json'),JSON.stringify(evidence,null,2)+'\n');return evidence;
 }catch(error){evidence.error=String(error.message);evidence.errorDiagnostic={code:error.code,stage:error.stage,hresult:error.hresult,exceptionType:error.exceptionType,errorId:error.errorId,scriptLine:error.scriptLine,exitCode:error.exitCode,stdoutBytes:error.stdoutBytes,stderrBytes:error.stderrBytes};fs.writeFileSync(path.join(outputDirectory,'native-video.json'),JSON.stringify(evidence,null,2)+'\n');throw error;}
 finally{jobs.dispose();fs.rmSync(directory,{recursive:true,force:true});}
}
module.exports={runNativeVideo,pngCenter,pcmTone};
if(require.main===module)runNativeVideo().then(value=>process.stdout.write(JSON.stringify(value)+'\n')).catch(error=>{process.stderr.write(error.message+'\n');process.exitCode=1;});
