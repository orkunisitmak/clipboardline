'use strict';
const fs=require('node:fs'),path=require('node:path');
const {spawn}=require('node:child_process');

// Linux counterpart of native/windows-media.ps1. The distribution's FFmpeg
// decodes and encodes; ClipBoardLine downloads no codec binaries.
function failure(message,stage,extra={}){const error=new Error(message);error.code='MEDIA_UNSUPPORTED_OR_FAILED';if(stage)error.stage=stage;return Object.assign(error,extra);}
function aborted(){const error=new Error('Video operation canceled.');error.name='AbortError';return error;}
function runTool(file,args,{signal,timeout=600000,track=()=>{},spawner=spawn,limit=4*1024*1024,stage='Run'}={}){
 return new Promise((resolve,reject)=>{
  if(signal?.aborted){reject(aborted());return;}
  let child;try{child=spawner(file,args,{stdio:['ignore','pipe','pipe']});}catch(error){reject(failure('FFmpeg could not start: '+error.message,stage));return;}
  track(child);let stdout='',stderr='',problem=null,finished=false;
  const stop=error=>{problem??=error;child.kill('SIGKILL');};const cancel=()=>stop(aborted());
  const timer=setTimeout(()=>stop(failure('Video operation timed out after ten minutes.',stage)),timeout);
  signal?.addEventListener('abort',cancel,{once:true});
  child.stdout.on('data',chunk=>{stdout+=chunk.toString('utf8');if(stdout.length>limit)stop(failure('Invalid FFmpeg response.',stage));});
  child.stderr.on('data',chunk=>{if(stderr.length<8000)stderr+=chunk.toString('utf8');});
  const done=(error,code)=>{
   if(finished)return;finished=true;clearTimeout(timer);signal?.removeEventListener('abort',cancel);
   if(problem)return reject(problem);
   if(error)return reject(failure(error.code==='ENOENT'?'Install FFmpeg (ffmpeg and ffprobe) to import or trim recordings on Linux.':'FFmpeg could not start: '+error.message,stage,{missing:error.code==='ENOENT'}));
   if(code!==0)return reject(failure(('FFmpeg could not process this recording: '+(stderr.trim().split('\n').pop()||'exit '+code)).slice(0,500),stage,{exitCode:code}));
   resolve(stdout);
  };
  child.on('error',error=>done(error));child.on('close',code=>done(null,code));
 });
}
function rotation(stream){
 for(const value of stream.side_data_list||[])if(Number.isFinite(Number(value?.rotation)))return Number(value.rotation);
 const tag=Number(stream.tags?.rotate);return Number.isFinite(tag)?tag:0;
}
function describe(probe){
 const streams=Array.isArray(probe?.streams)?probe.streams:[];
 const video=streams.find(stream=>stream?.codec_type==='video'&&stream.disposition?.attached_pic!==1);
 if(!video)throw failure('The recording has no usable video track.','Decode');
 const seconds=Number(probe.format?.duration)||Number(video.duration);
 let width=Number(video.width),height=Number(video.height);
 if(Math.abs(rotation(video))%180===90)[width,height]=[height,width];
 const durationMs=Math.round(seconds*1000*1000)/1000;
 if(!Number.isFinite(durationMs)||durationMs<=0||!Number.isInteger(width)||!Number.isInteger(height)||width<1||height<1)throw failure('The recording has no usable video track.','Decode');
 return{durationMs,width,height,videoCodec:String(video.codec_name||'').slice(0,80),audioTracks:streams.filter(stream=>stream?.codec_type==='audio').length,bitRate:Number(video.bit_rate)||Number(probe.format?.bit_rate)||0};
}
// H.264/AAC first, as on Windows. Distribution builds may list an encoder
// whose library is a stub (Fedora's noopenh264), so trimming falls back in
// order; VP9/Opus in MP4 remains playable by Chromium's media stack.
const VIDEO_ENCODERS=['libx264','libopenh264','libvpx-vp9'],AUDIO_ENCODERS=['aac','libfdk_aac','libopus'];
function chooseEncoders(listing){
 const names=new Set(String(listing).split('\n').map(line=>/^\s*[VAS][A-Z.]{5}\s+(\S+)/.exec(line)?.[1]).filter(Boolean));
 return{videos:VIDEO_ENCODERS.filter(name=>names.has(name)),audios:AUDIO_ENCODERS.filter(name=>names.has(name))};
}
function encoderAttempts({videos,audios},audioTracks){
 const attempts=[];for(const video of videos)for(const audio of audioTracks?audios:[null])attempts.push({video,audio});
 return attempts.slice(0,4);
}
function trimArguments({source,output,startMs,endMs,encoders,details}){
 const video=encoders.video==='libx264'?['-c:v','libx264','-preset','veryfast','-crf','20']:encoders.video==='libopenh264'?['-c:v','libopenh264','-b:v',String(Math.max(1_000_000,Math.min(details.bitRate||8_000_000,40_000_000)))]:['-c:v','libvpx-vp9','-deadline','realtime','-cpu-used','8','-row-mt','1','-crf','32','-b:v','0'];
 const audio=details.audioTracks&&encoders.audio?['-map','0:a:0','-c:a',encoders.audio,'-b:a','128k','-ar',encoders.audio==='libopus'?'48000':'44100','-ac','2']:['-an'];
 return['-nostdin','-hide_banner','-loglevel','error','-ss',(startMs/1000).toFixed(3),'-i',source,'-t',((endMs-startMs)/1000).toFixed(3),'-map','0:v:0','-vf','scale=trunc(iw/2)*2:trunc(ih/2)*2',...video,'-pix_fmt','yuv420p',...audio,'-movflags','+faststart','-y',output];
}
class LinuxMedia{
 constructor({ffmpeg,ffprobe,spawner=spawn}={}){this.ffmpeg=ffmpeg;this.ffprobe=ffprobe;this.spawner=spawner;this.encoders=null;}
 tool(name,args,options){const file=this[name];if(!file)return Promise.reject(failure('Install FFmpeg (ffmpeg and ffprobe) to import or trim recordings on Linux.','Runtime',{missing:true}));return runTool(file,args,{...options,spawner:this.spawner});}
 async probe(file,options){
  const output=await this.tool('ffprobe',['-v','error','-print_format','json','-show_format','-show_streams',file],{...options,stage:'Decode'});
  let value;try{value=JSON.parse(output);}catch{throw failure('Invalid FFmpeg response.','Decode');}return describe(value);
 }
 async run(mode,{source,outputDirectory,startMs,endMs,verifyAudio=false},{signal,timeout,track}={}){
  const options={signal,timeout,track};let details=await this.probe(source,options),posterSource=source,result;
  if(mode==='Trim'){
   if(!Number.isFinite(startMs)||!Number.isFinite(endMs)||startMs<0||endMs>details.durationMs+1||endMs-startMs<50)throw failure('Choose a nonempty interval within this recording.','Trim');
   this.encoders??=chooseEncoders(await this.tool('ffmpeg',['-hide_banner','-encoders'],{...options,stage:'Trim'}));
   const attempts=encoderAttempts(this.encoders,details.audioTracks);
   if(!attempts.length)throw failure(this.encoders.videos.length?'This FFmpeg build has no AAC or Opus audio encoder.':'This FFmpeg build has no H.264 or VP9 encoder.','Trim');
   const output=path.join(outputDirectory,'trimmed.mp4');let problem;
   for(const encoders of attempts){
    try{await this.tool('ffmpeg',trimArguments({source,output,startMs,endMs,encoders,details}),{...options,stage:'TrimRender'});problem=null;break;}
    catch(error){if(error.name==='AbortError'||signal?.aborted)throw error;problem=error;}
   }
   if(problem)throw problem;
   details=await this.probe(output,options);posterSource=output;
   if(Math.abs(details.durationMs-(endMs-startMs))>150)throw failure('The encoded trim duration did not match the selection.','TrimReopen');
   result={...details,trimmedFile:'trimmed.mp4'};
  }else result={...details};
  delete result.bitRate;
  await this.tool('ffmpeg',['-nostdin','-hide_banner','-loglevel','error','-i',posterSource,'-frames:v','1','-vf','scale=320:-2','-c:v','png','-f','image2','-y',path.join(outputDirectory,'poster.png')],{...options,stage:'Poster'});
  if(verifyAudio===true&&result.audioTracks>0){
   await this.tool('ffmpeg',['-nostdin','-hide_banner','-loglevel','error','-i',posterSource,'-vn','-map','0:a:0','-ac','1','-ar','44100','-c:a','pcm_s16le','-y',path.join(outputDirectory,'audio.wav')],{...options,stage:'AudioVerify'});
   result.audioFile='audio.wav';
  }
  if(!fs.existsSync(path.join(outputDirectory,'poster.png')))throw failure('Video poster is unavailable.','Poster');
  return{...result,posterFile:'poster.png',ok:true,engine:'FFmpeg'};
 }
}
module.exports={LinuxMedia,describe,chooseEncoders,encoderAttempts,trimArguments,runTool};
