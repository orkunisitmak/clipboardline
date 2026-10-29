'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),path=require('node:path'),{spawnSync}=require('node:child_process');
const {windowsEnvironment}=require('../lib/windows-environment.cjs');
test('actual PowerShell UIA observation policy retries only transient ranges and preserves ownership failures',{skip:process.platform!=='win32'},()=>{
 const executable=path.win32.join(process.env.SystemRoot||process.env.SYSTEMROOT||'C:\\Windows','System32','WindowsPowerShell','v1.0','powershell.exe'),result=spawnSync(executable,['-NoProfile','-NonInteractive','-MTA','-ExecutionPolicy','Bypass','-File',path.join(__dirname,'notepad-range-read-tests.ps1')],{encoding:'utf8',timeout:15000,windowsHide:true,env:windowsEnvironment()});
 assert.equal(result.status,0,JSON.stringify({error:result.error?.message,stdout:result.stdout,stderr:result.stderr}));assert.match(result.stdout,/PASS fresh Notepad UIA snapshot retry policy/);
});
