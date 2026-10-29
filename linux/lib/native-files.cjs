'use strict';
const fs=require('node:fs'),path=require('node:path');
const {execFile}=require('node:child_process');
const {windowsEnvironment}=require('./windows-environment.cjs');
const pending=new Set();
function copyFiles({files,text='',marker=''}){
 if(process.platform!=='win32')return Promise.reject(new Error('Native file copy requires Windows.'));
 if(!Array.isArray(files)||!files.length||files.length>1000||files.some(file=>typeof file!=='string'||!path.isAbsolute(file)||!fs.lstatSync(file).isFile()||fs.lstatSync(file).isSymbolicLink()))return Promise.reject(new Error('A copied file is unavailable.'));
 if(typeof text!=='string'||text.length>1024*1024||typeof marker!=='string'||marker.length>100) return Promise.reject(new Error('Invalid file clipboard payload.'));
 const script=__dirname.includes('app.asar')?path.join(process.resourcesPath,'native','windows-files.ps1'):path.join(__dirname,'..','native','windows-files.ps1');
 const executable=path.join(process.env.SystemRoot||'C:\\Windows','System32','WindowsPowerShell','v1.0','powershell.exe');
 return new Promise((resolve,reject)=>{
  const child=execFile(executable,['-NoLogo','-NoProfile','-STA','-NonInteractive','-ExecutionPolicy','Bypass','-File',script],{windowsHide:true,timeout:12000,maxBuffer:64000,env:windowsEnvironment()},(error,stdout)=>{
   pending.delete(child);
   let result;try{result=JSON.parse(stdout.trim());}catch{return reject(new Error('Windows file clipboard helper did not respond.'));}
   if(error||result.ok!==true)return reject(new Error(result.error||'Windows could not copy these files.'));resolve(result);
  });pending.add(child);child.stdin.on('error',()=>{});child.stdin.end(JSON.stringify({files,text,marker}));
 });
}
function cancelFileCopies(){for(const child of pending)child.kill();pending.clear();}
module.exports={copyFiles,cancelFileCopies};
