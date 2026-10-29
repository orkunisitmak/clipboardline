'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),crypto=require('node:crypto');
const {MediaJobs}=require('../../windows/lib/media.cjs');
const {pngCenter,pcmTone}=require('../../windows/tests/native-video-acceptance.cjs');
const fixtures=path.resolve(__dirname,'../../windows/tests/fixtures/recordings');
const hash=file=>crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
test('native FFmpeg probe/trim keeps originals, audio, durations and cleans private jobs',async t=>{
 const root=fs.mkdtempSync(path.join(os.tmpdir(),'clipboardline-media-'));
 const jobs=new MediaJobs({directory:path.join(root,'jobs')});t.after(()=>{jobs.dispose();fs.rmSync(root,{recursive:true,force:true});});
 for(const name of ['synthetic-rgb-tone.mp4','synthetic-rgb-tone.mov','synthetic-rgb-silent.mp4']){
  const source=path.join(fixtures,name),before=hash(source),audio=name.includes('silent')?0:1;
  const probe=await jobs.probe(source);assert.ok(Math.abs(probe.durationMs-6000)<300);assert.equal(probe.width,160);assert.equal(probe.height,120);assert.equal(probe.audioTracks,audio);assert.ok(fs.statSync(probe.posterFile).size>0);assert.ok(pngCenter(probe.posterFile).rgb[0]>150);assert.equal(jobs.release(probe),true);
  const trim=await jobs.trim(source,{startMs:2000,endMs:4000,verifyAudio:true});assert.ok(Math.abs(trim.durationMs-2000)<200);assert.equal(trim.audioTracks,audio);assert.equal(hash(source),before);assert.notEqual(trim.file,source);assert.equal(!!trim.audioFile,!!audio);assert.ok(pngCenter(trim.posterFile).rgb[1]>100);if(audio)assert.ok(Math.abs(pcmTone(trim.audioFile).hz-440)<20);assert.equal(jobs.release(trim),true);
 }
 await assert.rejects(jobs.trim(path.join(fixtures,'synthetic-rgb-tone.mp4'),{startMs:2000,endMs:9000}),/duration/);
 await assert.rejects(jobs.probe(path.join(fixtures,'synthetic-rgb-tone.mp4'),{signal:AbortSignal.abort()}),{name:'AbortError'});
 assert.deepEqual(fs.readdirSync(jobs.directory),[]);
});
