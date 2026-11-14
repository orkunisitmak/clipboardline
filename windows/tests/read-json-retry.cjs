'use strict';
const fs=require('node:fs');
// The PowerShell fixtures rewrite their state file in place (File.Copy overwrite), so a direct read can
// hit a sharing violation or catch the file half written. Retry briefly; any other error is real.
// ponytail: blocking sleep, fine for a test harness that already polls synchronously.
function readJsonRetry(file,{attempts=20,delay=25,read=fs.readFileSync,sleep=ms=>Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,ms)}={}){
  for(let attempt=1;;attempt++){
    try{return JSON.parse(read(file,'utf8'));}
    catch(error){if(attempt>=attempts||!(error instanceof SyntaxError||['EBUSY','EPERM','EACCES'].includes(error.code)))throw error;sleep(delay);}
  }
}
module.exports={readJsonRetry};
