'use strict';
// A disposable native Wayland editor for the Linux paste acceptance check. It
// reports only its own field value; it never reads the system clipboard.
const {app,BrowserWindow}=require('electron');
app.commandLine.appendSwitch('ozone-platform','wayland');
app.whenReady().then(async()=>{
 const window=new BrowserWindow({width:520,height:220,title:'ClipBoardLine paste target',webPreferences:{sandbox:true,contextIsolation:true}});
 await window.loadURL('data:text/html,'+encodeURIComponent('<title>ClipBoardLine paste target</title><textarea id=t autofocus style="width:96%;height:150px"></textarea><script>t.focus();t.addEventListener("input",()=>document.title="value:"+t.value)</script>'));
 window.focus();
 window.on('page-title-updated',(_event,title)=>{if(title.startsWith('value:'))process.stdout.write(JSON.stringify({value:title.slice(6)})+'\n');});
 const report=()=>process.stdout.write(JSON.stringify({focused:window.isFocused()})+'\n');
 window.on('focus',report);window.on('blur',report);setTimeout(report,400);
 setTimeout(()=>app.quit(),Number(process.env.CLIPBOARDLINE_TARGET_LIFETIME||30000));
});
