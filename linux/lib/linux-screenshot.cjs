'use strict';
const crypto=require('node:crypto'),fs=require('node:fs');
const {spawn,execFile}=require('node:child_process');
const {fileURLToPath}=require('node:url');

// Wayland compositors do not let clients read the screen directly. The
// xdg-desktop-portal Screenshot interface asks the compositor instead; the
// desktop may ask once for permission. Only the request's own Response is used.
const RESPONSE=/^(\/org\/freedesktop\/portal\/desktop\/request\/[A-Za-z0-9_]+\/([A-Za-z0-9_]+)): org\.freedesktop\.portal\.Request\.Response \(uint32 (\d+), (.*)\)$/;
function parseResponse(line,token){
 const match=RESPONSE.exec(String(line).trim());if(!match||match[2]!==token)return null;
 const uri=/'uri': <'((?:[^'\\]|\\.)*)'>/.exec(match[4])?.[1]?.replace(/\\(.)/g,'$1')??null;
 return{code:Number(match[3]),uri};
}
function screenshotPath(response){
 if(!response)throw new Error('The screenshot portal did not respond.');
 if(response.code===1)throw new Error('Screen capture was canceled.');
 if(response.code!==0||!response.uri)throw new Error('The desktop screenshot portal could not capture the screen.');
 let file;try{file=fileURLToPath(response.uri);}catch{throw new Error('The screenshot portal returned an unsupported location.');}
 const stat=fs.lstatSync(file);if(!stat.isFile()||stat.isSymbolicLink()||stat.size>64*1024*1024)throw new Error('The captured screenshot is unavailable.');
 return file;
}
function portalScreenshot({gdbus,spawner=spawn,caller=execFile,timeout=120000}={}){
 if(!gdbus)return Promise.reject(new Error('Screen capture on Wayland requires gdbus and xdg-desktop-portal.'));
 const token='clipboardline_'+crypto.randomBytes(8).toString('hex');
 return new Promise((resolve,reject)=>{
  let monitor,settled=false,buffer='',called=false;
  const finish=(error,value)=>{if(settled)return;settled=true;clearTimeout(timer);monitor?.kill();if(error)reject(error);else resolve(value);};
  const timer=setTimeout(()=>finish(new Error('The screenshot portal did not respond.')),timeout);
  try{monitor=spawner(gdbus,['monitor','--session','--dest','org.freedesktop.portal.Desktop'],{stdio:['ignore','pipe','ignore']});}catch(error){finish(error);return;}
  monitor.on('error',error=>finish(error));
  monitor.on('exit',()=>finish(new Error('The screenshot portal monitor stopped.')));
  const request=()=>{
   if(called)return;called=true;
   caller(gdbus,['call','--session','--dest','org.freedesktop.portal.Desktop','--object-path','/org/freedesktop/portal/desktop','--method','org.freedesktop.portal.Screenshot.Screenshot','',`{'handle_token': <'${token}'>, 'interactive': <false>}`],{timeout:10000},error=>{if(error)finish(new Error('The desktop screenshot portal is unavailable.'));});
  };
  monitor.stdout.on('data',chunk=>{
   buffer+=chunk.toString('utf8');if(buffer.length>65536)buffer=buffer.slice(-65536);let index;
   while((index=buffer.indexOf('\n'))>=0){
    const line=buffer.slice(0,index);buffer=buffer.slice(index+1);
    // The first line confirms the signal subscription; call only after it.
    if(!called&&/^Monitoring signals/.test(line)){request();continue;}
    const response=parseResponse(line,token);if(!response)continue;
    try{finish(null,screenshotPath(response));}catch(error){finish(error);}
   }
  });
 });
}
module.exports={portalScreenshot,parseResponse,screenshotPath};
