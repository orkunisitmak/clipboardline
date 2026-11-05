'use strict';
// A separate X11 client used by linux-runtime-acceptance.cjs when xclip is not
// installed. "write <type> <base64>" owns the selection until stdin closes;
// "read <type>" prints the selection payload as base64.
const {app,clipboard,ClipboardItem}=require('electron');
app.commandLine.appendSwitch('ozone-platform','x11');
const [mode,requested,payload]=process.argv.slice(process.argv.findIndex(value=>value==='write'||value==='read'));
const type=requested.startsWith('text/plain')?'text/plain':requested;
app.whenReady().then(async()=>{
  if(mode==='write'){
    const key=['text/plain','image/png'].includes(type)?type:`electron application/osclipboard;format="${type}"`;
    await clipboard.write([new ClipboardItem({[key]:new Blob([Buffer.from(payload,'base64')],{type})})]);
    process.stdout.write('ready\n');process.stdin.on('end',()=>app.exit(0));process.stdin.resume();
  }else{
    const entry=(await clipboard.read()).find(item=>item.types.includes(type)||item.types.includes(`electron application/osclipboard;format="${type}"`));
    const value=entry?Buffer.from(await(await entry.getType(entry.types.includes(type)?type:`electron application/osclipboard;format="${type}"`)).arrayBuffer()):Buffer.alloc(0);
    process.stdout.write(value.toString('base64')+'\n');app.exit(entry?0:1);
  }
}).catch(error=>{process.stderr.write(String(error.message)+'\n');app.exit(2);});
