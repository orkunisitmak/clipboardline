'use strict';
const fs=require('node:fs'),path=require('node:path');
const {which,runTool}=require('./linux-desktop.cjs');

// Linux counterpart of windows-media.ps1, using the distribution's FFmpeg.
// It returns the same response object; media.cjs keeps every validation.
const ENCODERS=[['libx264','-preset','veryfast','-crf','20'],['libopenh264','-b:v','6M'],['mpeg4','-q:v','3']];
function inspectFields(probe){
 const streams=Array.isArray(probe?.streams)?probe.streams:[];
 const video=streams.find(stream=>stream.codec_type==='video'&&!stream.disposition?.attached_pic);
 if(!video)throw new Error('This file has no video track.');
 let width=Number(video.width),height=Number(video.height);
 const rotation=Math.abs(Number(video.tags?.rotate??video.side_data_list?.find(value=>value.rotation!==undefined)?.rotation??0))%360;
 if(rotation===90||rotation===270)[width,height]=[height,width];
 const seconds=Number(probe.format?.duration??video.duration);
 return{durationMs:Math.round(seconds*1000*1000)/1000,width,height,videoCodec:String(video.codec_name||'').toUpperCase().slice(0,80),audioTracks:streams.filter(stream=>stream.codec_type==='audio').length};
}
async function inspect(file,{signal,run}){
 const ffprobe=which('ffprobe');if(!ffprobe)throw new Error('Recording support on Linux needs FFmpeg (ffprobe).');
 const bytes=await run(ffprobe,['-v','error','-print_format','json','-show_format','-show_streams','--',file],{timeout:60000,maximum:4*1024*1024,signal});
 let value;try{value=JSON.parse(bytes.toString('utf8'));}catch{throw new Error('FFmpeg could not read this recording.');}
 return inspectFields(value);
}
function ffmpeg(){const file=which('ffmpeg');if(!file)throw new Error('Recording support on Linux needs FFmpeg.');return file;}
async function poster(source,destination,durationMs,{signal,run}){
 // Skip the frequently black first frame of screen recordings when possible.
 const at=Math.max(0,Math.min(500,durationMs/2))/1000;
 await run(ffmpeg(),['-nostdin','-v','error','-y','-ss',at.toFixed(3),'-i',source,'-frames:v','1','-vf',"scale='min(1920,iw)':-2",'-f','image2','-c:v','png',destination],{timeout:120000,signal});
}
async function trim(source,destination,{startMs,endMs,audioTracks,signal,run}){
 let failure;
 for(const [encoder,...options] of ENCODERS){
  try{
   await run(ffmpeg(),['-nostdin','-v','error','-y','-ss',(startMs/1000).toFixed(3),'-i',source,'-t',((endMs-startMs)/1000).toFixed(3),'-map','0:v:0',...(audioTracks?['-map','0:a:0?','-c:a','aac','-b:a','160k']:['-an']),'-c:v',encoder,...options,'-pix_fmt','yuv420p','-movflags','+faststart','-f','mp4',destination],{timeout:9*60*1000,maximum:1024*1024,signal});
   return;
  }catch(error){if(error.name==='AbortError')throw error;failure=error;try{fs.unlinkSync(destination);}catch{}}
 }
 throw new Error('FFmpeg could not encode the trimmed recording'+(failure?.stderr?': '+failure.stderr:'.'));
}
async function job(mode,request,{signal,run=runTool}={}){
 const {source,outputDirectory}=request;
 const original=await inspect(source,{signal,run});let result={...original};
 let posterSource=source;
 if(mode==='Trim'){
  const {startMs,endMs}=request;
  if(!Number.isFinite(startMs)||!Number.isFinite(endMs)||startMs<0||endMs>original.durationMs+1||endMs-startMs<50)throw new Error('Choose a nonempty trim interval inside the recording.');
  const output=path.join(outputDirectory,'trimmed.mp4');
  await trim(source,output,{startMs,endMs,audioTracks:original.audioTracks,signal,run});
  result=await inspect(output,{signal,run});
  if(Math.abs(result.durationMs-(endMs-startMs))>150)throw new Error('The encoded trim duration did not match the selection.');
  result.trimmedFile='trimmed.mp4';posterSource=output;
 }
 await poster(posterSource,path.join(outputDirectory,'poster.png'),result.durationMs,{signal,run});
 if(request.verifyAudio===true&&result.audioTracks>0){
  await run(ffmpeg(),['-nostdin','-v','error','-y','-i',posterSource,'-vn','-map','0:a:0','-t','60','-ac','1','-ar','16000','-c:a','pcm_s16le',path.join(outputDirectory,'audio.wav')],{timeout:120000,signal});
  result.audioFile='audio.wav';
 }
 return{...result,posterFile:'poster.png',ok:true,engine:'FFmpeg'};
}
module.exports={job,inspectFields};
