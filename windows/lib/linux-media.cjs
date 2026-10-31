'use strict';
const {spawn}=require('node:child_process');
const path=require('node:path');

// FFmpeg replaces Windows.Media.Editing on Linux. The result object has the
// exact shape the Windows helper prints, so media.cjs keeps one validation path.
// Inputs are only .mov/.mp4 files; never let content select a playlist or
// network demuxer that could read other files or contact a host.
const INPUT=['-protocol_whitelist','file','-f','mov'];
function tool(file,args,{signal,timeout,spawner=spawn,maximum=4*1024*1024}={}){
  return new Promise((resolve,reject)=>{
    const child=spawner(file,args,{stdio:['ignore','pipe','pipe']});
    let stdout='',failure=null;const stop=error=>{failure??=error;child.kill('SIGKILL');};
    const cancel=()=>{const error=new Error('Video operation canceled.');error.name='AbortError';stop(error);};
    signal?.addEventListener('abort',cancel,{once:true});
    const timer=setTimeout(()=>stop(new Error('Video operation timed out after ten minutes.')),timeout);
    child.stdout.on('data',chunk=>{stdout+=chunk.toString('utf8');if(stdout.length>maximum)stop(new Error('Invalid video helper response.'));});
    child.stderr.on('data',()=>{});
    child.on('error',error=>{clearTimeout(timer);signal?.removeEventListener('abort',cancel);reject(failure||(error.code==='ENOENT'?new Error('Video processing needs FFmpeg. Install the ffmpeg package.'):error));});
    child.on('close',code=>{clearTimeout(timer);signal?.removeEventListener('abort',cancel);if(failure)return reject(failure);if(code!==0)return reject(Object.assign(new Error('FFmpeg could not process this recording.'),{code:'MEDIA_UNSUPPORTED_OR_FAILED'}));resolve(stdout);});
  });
}
async function probe(file,options){
  const value=JSON.parse(await tool('ffprobe',['-v','error','-print_format','json','-show_format','-show_streams',...INPUT,file],options));
  const streams=Array.isArray(value.streams)?value.streams:[],video=streams.find(stream=>stream.codec_type==='video');
  if(!video)throw Object.assign(new Error('The recording has no video track.'),{code:'MEDIA_UNSUPPORTED_OR_FAILED'});
  const seconds=Number(value.format?.duration??video.duration);
  const rotation=Math.abs(Number(video.side_data_list?.find(data=>data.rotation!==undefined)?.rotation??video.tags?.rotate??0))%180===90;
  return{durationMs:seconds*1000,width:rotation?video.height:video.width,height:rotation?video.width:video.height,videoCodec:String(video.codec_name||'').slice(0,80),audioTracks:streams.filter(stream=>stream.codec_type==='audio').length};
}
async function processRecording(mode,{source,outputDirectory,startMs,endMs,verifyAudio=false},{signal,timeout,spawner}={}){
  const options={signal,timeout,spawner},original=await probe(source,options);
  let result=original,media=source;
  if(mode==='Trim'){
    if(!Number.isFinite(startMs)||!Number.isFinite(endMs)||startMs<0||endMs>original.durationMs+1||endMs-startMs<50)throw new Error('Choose a nonempty trim interval inside the recording.');
    media=path.join(outputDirectory,'trimmed.mp4');
    await tool('ffmpeg',['-nostdin','-v','error','-ss',(startMs/1000).toFixed(3),...INPUT,'-i',source,'-t',((endMs-startMs)/1000).toFixed(3),'-map','0:v:0','-map','0:a?','-c:v','libx264','-preset','veryfast','-crf','20','-pix_fmt','yuv420p','-c:a','aac','-movflags','+faststart','-n',media],options);
    result=await probe(media,options);
    if(Math.abs(result.durationMs-(endMs-startMs))>150)throw new Error('The encoded trim duration did not match the selection.');
  }
  await tool('ffmpeg',['-nostdin','-v','error','-ss',String(Math.min(0.1,result.durationMs/2000)),...INPUT,'-i',media,'-frames:v','1','-vf',"scale='min(1280,iw)':-2",'-n',path.join(outputDirectory,'poster.png')],options);
  const output={...result,ok:true,posterFile:'poster.png',engine:'ffmpeg'};
  if(mode==='Trim')output.trimmedFile='trimmed.mp4';
  if(verifyAudio===true&&result.audioTracks>0){
    await tool('ffmpeg',['-nostdin','-v','error',...INPUT,'-i',media,'-map','0:a:0','-t','30','-ac','1','-ar','16000','-c:a','pcm_s16le','-n',path.join(outputDirectory,'audio.wav')],options);
    output.audioFile='audio.wav';
  }
  return output;
}
module.exports={processRecording,probe};
