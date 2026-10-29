'use strict';
const fs=require('node:fs'),path=require('node:path'),{spawn}=require('node:child_process');
const {windowsEnvironment}=require('../lib/windows-environment.cjs');
const TITLE='ClipBoardLine synthetic browser paste fixture';
const positiveHandle=value=>typeof value==='string'&&/^[1-9]\d{0,19}$/.test(value);
function assertOwnedWindow(value,expected,canonicalize=file=>fs.realpathSync.native(file).toLowerCase()){
 if(!value||value.error||!positiveHandle(value.window)||
    !Number.isSafeInteger(value.owner)||value.owner!==expected.pid||
    expected.window&&value.window!==expected.window||typeof value.title!=='string'||!value.title.startsWith(TITLE)||
    typeof value.executable!=='string'||canonicalize(value.executable)!==canonicalize(expected.executable))throw new Error('The actual Win32 foreground/focus is not the owned synthetic browser: '+JSON.stringify(value));
 return value;
}
function assertOwnedForeground(value,expected,canonicalize){
 assertOwnedWindow(value,expected,canonicalize);
 if(!positiveHandle(value.focus)||value.focusOwner!==expected.pid)throw new Error('The actual native keyboard focus is not owned by the synthetic browser');
 return value;
}
function assertDisposableWindows(platform=process.platform,environment=process.env){
 if(platform!=='win32'||environment.GITHUB_ACTIONS!=='true')throw new Error('Owned consumer pointer acceptance requires the disposable Windows CI desktop');
}
function pointerPoint(metrics){
 const {screenX,screenY,outerHeight,innerHeight,innerWidth,rect}=metrics||{};
 if(!rect||![screenX,screenY,outerHeight,innerHeight,innerWidth,rect.x,rect.y,rect.width,rect.height].every(Number.isFinite)||
    innerHeight<=0||innerWidth<=0||outerHeight<innerHeight||rect.width<=0||rect.height<=0)throw new Error('Invalid native consumer viewport geometry');
 const center={x:rect.x+rect.width/2,y:rect.y+rect.height/2};
 if(center.x<0||center.x>=innerWidth||center.y<0||center.y>=innerHeight)throw new Error('Owned synthetic editor is outside the native viewport');
 const point={x:Math.round(screenX+center.x),y:Math.round(screenY+outerHeight-innerHeight+center.y)};
 if(Math.abs(point.x)>100000||Math.abs(point.y)>100000)throw new Error('Consumer pointer exceeds bounded desktop coordinates');
 return point;
}
async function createWin32Observer(){
 assertDisposableWindows();
 const executable=path.join(process.env.SystemRoot,'System32/WindowsPowerShell/v1.0/powershell.exe');
 const child=spawn(executable,['-NoProfile','-MTA','-NonInteractive','-ExecutionPolicy','Bypass','-File',path.join(__dirname,'consumer-win32-focus.ps1')],{windowsHide:true,stdio:['pipe','pipe','pipe'],env:windowsEnvironment()});
 let buffer='',stderr='',pending=null,failed=null,disposed=false;
 const fail=error=>{failed=error;if(pending){clearTimeout(pending.timer);pending.reject(error);pending=null;}if(!child.killed)child.kill();};
 const response=()=>new Promise((resolve,reject)=>{if(failed||disposed)return reject(failed||new Error('Foreground observer is closed'));if(pending)return reject(new Error('Concurrent foreground observation is not allowed'));pending={resolve,reject,timer:setTimeout(()=>fail(new Error('Bounded Win32 observer timed out: '+stderr)),10000)};});
 const ready=response();
 child.stdout.on('data',chunk=>{buffer+=chunk.toString();if(buffer.length>65536)return fail(new Error('Unexpected oversized Win32 observer output'));let index;while((index=buffer.indexOf('\n'))>=0){const line=buffer.slice(0,index).trim();buffer=buffer.slice(index+1);if(!line)continue;let value;try{value=JSON.parse(line);}catch{return fail(new Error('Invalid Win32 observer response'));}if(!pending)return fail(new Error('Unrequested Win32 observer response'));const request=pending;pending=null;clearTimeout(request.timer);value.error?request.reject(new Error(value.error)):request.resolve(value);}});
 child.stderr.on('data',chunk=>{stderr=(stderr+chunk.toString()).slice(-8192);});
 child.on('error',fail);child.stdin.on('error',fail);child.on('exit',code=>{if(!disposed)fail(new Error('Win32 observer exited '+code+': '+stderr));});
 async function close(){if(disposed)return;disposed=true;if(pending){clearTimeout(pending.timer);pending.reject(new Error('Foreground observer disposed'));pending=null;}if(child.exitCode!==null)return;await new Promise(resolve=>{const timer=setTimeout(()=>{child.kill();resolve();},1000);child.once('exit',()=>{clearTimeout(timer);resolve();});child.stdin.end();});}
 try{const value=await ready;if(value.ready!==true)throw new Error('Win32 observer did not initialize');}catch(error){await close();throw error;}
 return{async read(expected,point){const next=response();child.stdin.write(JSON.stringify({action:point?'click':'snapshot',pid:expected.pid,executable:expected.executable,window:expected.window,title:TITLE,...point})+'\n');const value=await next;if(point){if(value.pointerSent!==true)throw new Error('The owned OS pointer event was not sent');return assertOwnedWindow(value,expected);}return assertOwnedForeground(value,expected);},close};
}
module.exports={TITLE,assertOwnedWindow,assertOwnedForeground,assertDisposableWindows,pointerPoint,createWin32Observer};
