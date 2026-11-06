'use strict';
// Linux desktop integration; the Linux CI runs it, and Windows hosts skip it.
const linuxOnly={skip:process.platform==='win32'&&'Linux desktop integration'};
const test=(name,options,body)=>typeof options==='function'?require('node:test').test(name,linuxOnly,options):require('node:test').test(name,{...options,...linuxOnly},body);
const assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {EventEmitter}=require('node:events');
const {LinuxMedia,describe,chooseEncoders,encoderAttempts,trimArguments,runTool}=require('../lib/linux-media.cjs');

const stream=(value)=>({codec_type:'video',codec_name:'h264',width:1920,height:1080,...value});
test('ffprobe metadata matches the native recording contract, including rotation and audio tracks',()=>{
  assert.deepEqual(describe({format:{duration:'6.0405',bit_rate:'900000'},streams:[stream({}),{codec_type:'audio'},{codec_type:'audio'}]}),{durationMs:6040.5,width:1920,height:1080,videoCodec:'h264',audioTracks:2,bitRate:900000});
  assert.equal(describe({format:{duration:'2'},streams:[stream({side_data_list:[{rotation:-90}]})]}).width,1080);
  assert.equal(describe({format:{duration:'2'},streams:[stream({tags:{rotate:'270'}})]}).height,1920);
  assert.equal(describe({format:{},streams:[stream({codec_name:'mjpeg',disposition:{attached_pic:1}}),stream({duration:'3',codec_name:'hevc'})]}).videoCodec,'hevc','cover art is not the recording');
  for(const invalid of [{streams:[{codec_type:'audio'}]},{format:{duration:'0'},streams:[stream({})]},{format:{duration:'1'},streams:[stream({width:0})]},{}])assert.throws(()=>describe(invalid),/no usable video track/);
});
test('encoder selection prefers H.264/AAC and keeps Chromium-playable fallbacks',()=>{
  const listing=(...names)=>' V....D libx264xx  fake\n V.S..D mpeg4  MPEG-4 part 2\n'+names.map(name=>(['libx264','libopenh264','libvpx-vp9'].includes(name)?' V....D ':' A....D ')+name+'   description').join('\n');
  assert.deepEqual(chooseEncoders(listing('libx264','libopenh264','aac')),{videos:['libx264','libopenh264'],audios:['aac']});
  assert.deepEqual(chooseEncoders(listing('libopenh264','libvpx-vp9','aac','libfdk_aac','libopus')),{videos:['libopenh264','libvpx-vp9'],audios:['aac','libfdk_aac','libopus']},'Fedora ffmpeg-free');
  assert.deepEqual(chooseEncoders(listing('libmp3lame')),{videos:[],audios:[]},'MPEG-4 Part 2 and MP3 are not offered: Chromium cannot preview them');
  assert.deepEqual(encoderAttempts({videos:['libopenh264','libvpx-vp9'],audios:['aac','libopus']},1),[{video:'libopenh264',audio:'aac'},{video:'libopenh264',audio:'libopus'},{video:'libvpx-vp9',audio:'aac'},{video:'libvpx-vp9',audio:'libopus'}]);
  assert.deepEqual(encoderAttempts({videos:['libvpx-vp9'],audios:[]},0),[{video:'libvpx-vp9',audio:null}]);
  assert.deepEqual(encoderAttempts({videos:['libx264'],audios:[]},2),[]);
});
test('trim arguments seek precisely, keep one video and one audio track and write a faststart MP4',()=>{
  const args=trimArguments({source:'/in.mov',output:'/out/trimmed.mp4',startMs:1250,endMs:4000,encoders:{video:'libx264',audio:'aac'},details:{audioTracks:1}});
  assert.deepEqual(args.slice(args.indexOf('-ss'),args.indexOf('-ss')+6),['-ss','1.250','-i','/in.mov','-t','2.750']);
  for(const expected of [['-c:v','libx264'],['-c:a','aac'],['-map','0:a:0'],['-pix_fmt','yuv420p'],['-movflags','+faststart']])assert.ok(args.join(' ').includes(expected.join(' ')),expected.join(' '));
  assert.equal(args.at(-1),'/out/trimmed.mp4');
  const silent=trimArguments({source:'/in.mp4',output:'/o.mp4',startMs:0,endMs:100,encoders:{video:'libopenh264',audio:'aac'},details:{audioTracks:0,bitRate:500}});
  assert.ok(silent.includes('-an'),'a video-only recording stays video-only');assert.equal(silent[silent.indexOf('-b:v')+1],'1000000');
  const vp9=trimArguments({source:'/in.mp4',output:'/o.mp4',startMs:0,endMs:100,encoders:{video:'libvpx-vp9',audio:'libopus'},details:{audioTracks:1}});
  assert.ok(vp9.join(' ').includes('-c:v libvpx-vp9'));assert.equal(vp9[vp9.indexOf('-ar')+1],'48000');
});
function fakeTools(handler){
  const calls=[];
  const spawner=(file,args)=>{const child=new EventEmitter();child.stdout=new EventEmitter();child.stderr=new EventEmitter();child.kill=()=>{child.killed=true;};calls.push({file,args});
    setImmediate(()=>{try{const output=handler(file,args);if(output!==undefined)child.stdout.emit('data',Buffer.from(output));child.emit('close',0);}catch(error){child.stderr.emit('data',Buffer.from(error.message));child.emit('close',1);}});return child;};
  return{calls,spawner};
}
test('inspect and trim produce the helper result files and validate the encoded duration',async t=>{
  const directory=fs.mkdtempSync(path.join(os.tmpdir(),'clipboardline-linux-media-'));t.after(()=>fs.rmSync(directory,{recursive:true,force:true}));
  let trimmedDuration='2.75';
  const fake=fakeTools((file,args)=>{
    if(file==='ffprobe')return JSON.stringify({format:{duration:args.at(-1).endsWith('trimmed.mp4')?trimmedDuration:'6'},streams:[stream({}),{codec_type:'audio'}]});
    if(args.includes('-encoders'))return ' V....D libopenh264  H.264\n V....D libvpx-vp9  VP9\n A....D aac  AAC\n';
    if(args.includes('libopenh264'))throw new Error('[libopenh264] Incorrect library version loaded');
    const output=args.at(-1);fs.writeFileSync(output,'synthetic');return '';
  });
  const media=new LinuxMedia({ffmpeg:'ffmpeg',ffprobe:'ffprobe',spawner:fake.spawner});
  const inspected=await media.run('Inspect',{source:'/videos/a.mov',outputDirectory:directory,verifyAudio:true});
  assert.deepEqual(inspected,{durationMs:6000,width:1920,height:1080,videoCodec:'h264',audioTracks:1,audioFile:'audio.wav',posterFile:'poster.png',ok:true,engine:'FFmpeg'});
  const poster=fake.calls.find(call=>call.args.includes('poster.png')||call.args.at(-1).endsWith('poster.png'));assert.ok(poster.args.includes('scale=320:-2'));
  const trimmed=await media.run('Trim',{source:'/videos/a.mov',outputDirectory:directory,startMs:1250,endMs:4000});
  assert.equal(trimmed.trimmedFile,'trimmed.mp4');assert.equal(trimmed.durationMs,2750);
  assert.equal(fake.calls.filter(call=>call.args.includes('-encoders')).length,1);
  assert.deepEqual(fake.calls.filter(call=>call.args.includes('-t')).map(call=>call.args[call.args.indexOf('-c:v')+1]),['libopenh264','libvpx-vp9'],'a stub H.264 encoder falls back to VP9');
  trimmedDuration='5';await assert.rejects(media.run('Trim',{source:'/videos/a.mov',outputDirectory:directory,startMs:1250,endMs:4000}),/did not match/);
  await assert.rejects(media.run('Trim',{source:'/videos/a.mov',outputDirectory:directory,startMs:0,endMs:7000}),/within this recording/);
  await assert.rejects(new LinuxMedia({ffmpeg:null,ffprobe:null}).run('Inspect',{source:'/a.mp4',outputDirectory:directory}),/Install FFmpeg/);
});
test('tool failures, missing binaries, cancellation and deadlines are reported as media errors',async()=>{
  const failing=fakeTools(()=>{throw new Error('Invalid data found when processing input');});
  await assert.rejects(runTool('ffprobe',[],{spawner:failing.spawner}),error=>error.code==='MEDIA_UNSUPPORTED_OR_FAILED'&&/Invalid data/.test(error.message));
  await assert.rejects(runTool('/nonexistent/ffmpeg-for-test',[],{}),error=>error.missing===true&&/Install FFmpeg/.test(error.message));
  const controller=new AbortController();const hanging=(()=>{const child=new EventEmitter();child.stdout=new EventEmitter();child.stderr=new EventEmitter();child.kill=()=>setImmediate(()=>child.emit('close',null));return()=>child;})();
  const canceled=runTool('ffmpeg',[],{spawner:hanging,signal:controller.signal});controller.abort();await assert.rejects(canceled,error=>error.name==='AbortError');
  await assert.rejects(runTool('ffmpeg',[],{spawner:(()=>{const child=new EventEmitter();child.stdout=new EventEmitter();child.stderr=new EventEmitter();child.kill=()=>setImmediate(()=>child.emit('close',null));return()=>child;})(),timeout:5}),/timed out/);
});
