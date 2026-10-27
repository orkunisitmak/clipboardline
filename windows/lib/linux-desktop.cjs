'use strict';
const fs=require('node:fs'),path=require('node:path');
const {spawn}=require('node:child_process');

// Linux has no single clipboard/focus/input API. The desktop edition talks to
// the session through small, widely packaged tools and never through a shell.
const found=new Map();
function which(name,environment=process.env){
 if(found.has(name))return found.get(name);
 let result=null;
 for(const directory of String(environment.PATH||'').split(':').filter(Boolean)){
  const candidate=path.join(directory,name);
  try{fs.accessSync(candidate,fs.constants.X_OK);if(fs.statSync(candidate).isFile()){result=candidate;break;}}catch{}
 }
 found.set(name,result);return result;
}
function session(environment=process.env){
 const type=String(environment.XDG_SESSION_TYPE||'').toLowerCase();
 const wayland=!!environment.WAYLAND_DISPLAY||type==='wayland';
 return Object.freeze({wayland,x11:!wayland&&(!!environment.DISPLAY||type==='x11'),display:!!environment.DISPLAY,desktop:String(environment.XDG_CURRENT_DESKTOP||'').split(':').filter(Boolean)});
}
// Resolves with stdout bytes. A tool that forks a selection server (wl-copy,
// xclip -i) keeps inherited pipes open, so writers use detach:true and settle
// on the foreground process exit instead of on pipe closure.
function runTool(file,args,{input,timeout=4000,maximum=70*1024*1024,signal,detach=false,environment=process.env}={}){
 return new Promise((resolve,reject)=>{
  if(signal?.aborted)return reject(abortError());
  let child;
  try{child=spawn(file,args,{stdio:[input===undefined?'ignore':'pipe',detach?'ignore':'pipe',detach?'ignore':'pipe'],env:environment});}catch(error){return reject(error);}
  const out=[],err=[];let size=0,settled=false;
  const finish=(error,value)=>{if(settled)return;settled=true;clearTimeout(timer);signal?.removeEventListener('abort',cancel);error?reject(error):resolve(value);};
  const cancel=()=>{child.kill('SIGKILL');finish(abortError());};
  const timer=setTimeout(()=>{child.kill('SIGKILL');finish(Object.assign(new Error(path.basename(file)+' timed out.'),{code:'ETIMEDOUT'}));},timeout);
  signal?.addEventListener('abort',cancel,{once:true});
  child.stdout?.on('data',chunk=>{size+=chunk.length;if(size>maximum){child.kill('SIGKILL');finish(new Error(path.basename(file)+' output is too large.'));}else out.push(chunk);});
  child.stderr?.on('data',chunk=>{if(err.reduce((total,value)=>total+value.length,0)<8192)err.push(chunk);});
  child.on('error',error=>finish(error));
  child.on(detach?'exit':'close',code=>{
   if(code===0)return finish(null,Buffer.concat(out));
   const detail=Buffer.concat(err).toString('utf8').trim().split('\n')[0].slice(0,300);
   finish(Object.assign(new Error(path.basename(file)+' failed'+(detail?': '+detail:'.')),{code:'ETOOL',exitCode:code,stderr:detail}));
  });
  if(input!==undefined){child.stdin.on('error',()=>{});child.stdin.end(input);}
 });
}
function abortError(){const error=new Error('Operation canceled.');error.name='AbortError';return error;}
const delay=(ms,signal)=>new Promise((resolve,reject)=>{const timer=setTimeout(resolve,ms);signal?.addEventListener('abort',()=>{clearTimeout(timer);reject(abortError());},{once:true});});
module.exports={which,session,runTool,abortError,delay};
