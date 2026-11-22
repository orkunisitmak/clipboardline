'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const {spawnSync}=require('node:child_process');
const fs=require('node:fs'),os=require('node:os'),path=require('node:path');

test('a null JSON reply from the Windows media helper rejects without crashing the main process',{skip:process.platform!=='win32'},t=>{
  const root=fs.mkdtempSync(path.join(os.tmpdir(),'clipboardline-media-bad-reply-'));
  t.after(()=>fs.rmSync(root,{recursive:true,force:true}));
  const script=path.join(root,'unexpected-reply.ps1'),video=path.join(root,'sample.mp4');
  fs.writeFileSync(script,"Write-Output 'null'\n");
  fs.writeFileSync(video,Buffer.alloc(16,42));
  const child=String.raw`
    const {MediaJobs}=require(process.argv[1]);
    const jobs=new MediaJobs({directory:process.argv[2],script:process.argv[3],timeout:5000});
    jobs.inspect(process.argv[4]).then(
      ()=>{console.error('Unexpected helper success');process.exitCode=2;},
      error=>{if(error.code!=='MEDIA_INVALID_RESPONSE'){console.error(error);process.exitCode=3;}}
    ).finally(()=>jobs.dispose());
  `;
  const result=spawnSync(process.execPath,['-e',child,require.resolve('../lib/media.cjs'),path.join(root,'jobs'),script,video],
    {encoding:'utf8',timeout:14000,windowsHide:true});
  assert.equal(result.status,0,`The main process must survive a malformed native reply. stderr: ${result.stderr||result.error||''}`);
});
