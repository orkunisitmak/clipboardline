'use strict';
const {spawn}=require('node:child_process');
const path=require('node:path');
// The shared MediaJobs class owns queueing, immutable originals, cancellation,
// private directories and output validation. Only the codec boundary differs.
async function runLinuxMedia({mode,source,directory,startMs,endMs,verifyAudio,signal,timeout,jobs}){
 const deadline=Date.now()+timeout;
 function run(executable,args){return new Promise((resolve,reject)=>{
  const remaining=deadline-Date.now();if(remaining<=0)return reject(new Error('Video operation timed out.'));
  if(signal?.aborted)return reject(Object.assign(new Error('Video operation canceled.'),{name:'AbortError'}));
  const child=spawn(executable,args,{stdio:['ignore','pipe','pipe']});jobs.set(directory,child);
  let stdout='',failure=null;
  const stop=error=>{failure??=error;child.kill('SIGKILL');};
  const cancel=()=>stop(Object.assign(new Error('Video operation canceled.'),{name:'AbortError'}));
  const timer=setTimeout(()=>stop(new Error('Video operation timed out.')),remaining);
  child.on('spawn',()=>{if(failure)child.kill('SIGKILL');});
  signal?.addEventListener('abort',cancel,{once:true});if(signal?.aborted)cancel();
  child.stdout.on('data',chunk=>{stdout+=chunk.toString();if(stdout.length>64000)stop(new Error('Invalid video metadata.'));});
  child.stderr.resume(); // Paths and decoder diagnostics never enter user-facing errors.
  child.on('error',()=>{failure??=new Error('Install FFmpeg and ffprobe to process recordings.');});
  child.on('close',code=>{clearTimeout(timer);signal?.removeEventListener('abort',cancel);jobs.delete(directory);if(failure||code!==0)reject(failure||new Error('FFmpeg could not decode this recording.'));else resolve(stdout);});
 });}
 const probe=async file=>{
  const value=JSON.parse(await run('ffprobe',['-v','error','-protocol_whitelist','file,pipe','-show_entries','format=duration:stream=codec_type,codec_name,width,height,duration','-of','json',file]));
  const video=value.streams?.find(stream=>stream.codec_type==='video');
  if(!video)throw new Error('The recording has no video stream.');
  const result={durationMs:Number(value.format?.duration||video.duration)*1000,width:video.width,height:video.height,videoCodec:video.codec_name,audioTracks:value.streams.filter(stream=>stream.codec_type==='audio').length};
  return require('./media.cjs').metadata(result);
 };
 const ffmpeg=async args=>run('ffmpeg',['-nostdin','-hide_banner','-loglevel','error','-n','-threads','2','-filter_threads','1','-protocol_whitelist','file,pipe',...args]);
 let file=source,details=await probe(source);
 if(mode==='Trim'){
  if(endMs>details.durationMs+1)throw new Error('Trim exceeds the recording duration.');
  file=path.join(directory,'trimmed.mp4');
  await ffmpeg(['-ss',String(startMs/1000),'-i',source,'-t',String((endMs-startMs)/1000),'-map','0:v:0','-map','0:a:0?','-c:v','libx264','-preset','veryfast','-crf','20','-pix_fmt','yuv420p','-vf','scale=trunc(iw/2)*2:trunc(ih/2)*2','-threads','2','-c:a','aac','-movflags','+faststart','-fs',String(2*1024*1024*1024-1),file]);
  details=await probe(file);
  if(Math.abs(details.durationMs-(endMs-startMs))>1000)throw new Error('The trimmed recording is incomplete.');
 }
 await ffmpeg(['-i',file,'-map','0:v:0','-frames:v','1','-vf','scale=960:960:force_original_aspect_ratio=decrease','-threads','1',path.join(directory,'poster.png')]);
 let audioFile;
 if(verifyAudio&&details.audioTracks){audioFile='audio.wav';await ffmpeg(['-i',file,'-t','5','-vn','-ac','1','-ar','16000',path.join(directory,audioFile)]);}
 return{ok:true,...details,posterFile:'poster.png',...(mode==='Trim'?{trimmedFile:'trimmed.mp4'}:{}),...(audioFile?{audioFile}:{})};
}
module.exports={runLinuxMedia};
