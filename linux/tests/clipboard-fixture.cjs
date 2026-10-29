'use strict';
const {app,BrowserWindow}=require('electron');
const directory=process.argv.find(value=>value.startsWith('--test-data='))?.slice(12);
if(!directory||process.env.CLIPBOARDLINE_ISOLATED_DISPLAY!=='1')app.exit(1);
app.setPath('userData',directory);app.setName('ClipBoardLine synthetic receiver');
app.whenReady().then(async()=>{
 const window=new BrowserWindow({width:500,height:300,webPreferences:{sandbox:true,contextIsolation:true,nodeIntegration:false}});
 await window.loadURL('data:text/html,<title>Synthetic clipboard receiver</title><textarea aria-label="Synthetic paste target" autofocus></textarea>');
});
app.on('window-all-closed',()=>app.quit());
