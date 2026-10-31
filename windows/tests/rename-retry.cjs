'use strict';
const fs=require('node:fs');
const {setTimeout:sleep}=require('node:timers/promises');

// A PowerShell reader can briefly hold the destination without delete sharing.
// Retry only the atomic rename, never rewrite the command or generate a new serial.
async function renameRetry(source,destination,{attempts=20,delay=25,rename=fs.renameSync,pause=sleep}={}){
  for(let attempt=1;;attempt++){
    try{rename(source,destination);return;}
    catch(error){
      if(attempt>=attempts||!['EPERM','EACCES','EBUSY'].includes(error.code))throw error;
      await pause(delay);
    }
  }
}
module.exports={renameRetry};
