'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
function artwork(samples){
 const {paper,clip,background}=samples;
 assert.ok(paper.r>=225&&paper.g>=235&&paper.b>=240,'The shared clipboard paper must remain visible.');
 assert.ok(clip.r<=90&&clip.g>=145&&clip.b>=170&&clip.b>clip.g,'The shared cyan clip must remain visible.');
 assert.ok(background.r>=8&&background.r<=35&&background.g>=22&&background.g<=55&&background.b>=40&&background.b<=80,'The shared navy background must remain visible.');
}
module.exports=async({application,check,output})=>{
 const receipt=await application.evaluate(({app,nativeImage})=>{
  const path=process.getBuiltinModule('node:path'),image=nativeImage.createFromPath(path.join(app.getAppPath(),'assets/clipboardline.png')),size=image.getSize(),resized=image.resize({width:32,height:32}),bitmap=resized.toBitmap();
  const sample=(x,y)=>{const at=(Math.round(y*31)*32+Math.round(x*31))*4;return{r:bitmap[at+2],g:bitmap[at+1],b:bitmap[at],a:bitmap[at+3]};};
  return{packaged:app.isPackaged,exe:app.getPath('exe'),size,samples:{paper:sample(.5,.35),clip:sample(.5,.23),background:sample(.15,.5)}};
 });
 assert.deepEqual(receipt.size,{width:1024,height:1024});artwork(receipt.samples);
 if(receipt.packaged){
  const {execFileSync}=require('node:child_process'),{windowsEnvironment}=require('../lib/windows-environment.cjs');
  const powershell=path.join(process.env.SystemRoot,'System32/WindowsPowerShell/v1.0/powershell.exe');
  const script=String.raw`$ErrorActionPreference='Stop';Add-Type -AssemblyName System.Drawing;$payload=[Console]::In.ReadToEnd()|ConvertFrom-Json;$icon=[System.Drawing.Icon]::ExtractAssociatedIcon([string]$payload.exe);if($null -eq $icon){throw 'Executable icon is missing.'};$bitmap=$icon.ToBitmap();try{function Sample([double]$x,[double]$y){$p=$bitmap.GetPixel([int][Math]::Round($x*($bitmap.Width-1)),[int][Math]::Round($y*($bitmap.Height-1)));return @{r=[int]$p.R;g=[int]$p.G;b=[int]$p.B;a=[int]$p.A}};@{width=$bitmap.Width;height=$bitmap.Height;samples=@{paper=(Sample 0.5 0.35);clip=(Sample 0.5 0.23);background=(Sample 0.15 0.5)}}|ConvertTo-Json -Compress -Depth 4}finally{$bitmap.Dispose();$icon.Dispose()}`;
  const raw=execFileSync(powershell,['-NoProfile','-NonInteractive','-Command',script],{input:JSON.stringify({exe:receipt.exe}),encoding:'utf8',windowsHide:true,timeout:20000,env:windowsEnvironment()});
  receipt.executableIcon=JSON.parse(raw.replace(/^\uFEFF/,''));assert.ok(receipt.executableIcon.width>=16&&receipt.executableIcon.height>=16);artwork(receipt.executableIcon.samples);
 }
 fs.writeFileSync(path.join(output,'shared-app-icon.json'),JSON.stringify(receipt,null,2)+'\n');
 check(receipt.packaged?'actual packaged/installed executable and runtime use the shared macOS clipboard artwork':'actual runtime loads the shared macOS clipboard artwork');
};
