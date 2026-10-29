'use strict';
const fs=require('node:fs'),path=require('node:path'),os=require('node:os');
const OWNER='X-ClipBoardLine-Autostart=true';
function quote(value){
 if(typeof value!=='string'||/[\r\n\0]/.test(value))throw new Error('Invalid launch path.');
 // Desktop Entry Exec escaping (not shell escaping); %% is a literal percent.
 return ('"'+value.replace(/[%\\"`$]/g,value=>value==='%'?'%%':'\\'+value)+'"').replace(/\\/g,'\\\\');
}
function setLaunchAtLogin(enabled,{executable,args=[],configHome=process.env.XDG_CONFIG_HOME||path.join(os.homedir(),'.config')}={}){
 if(typeof enabled!=='boolean'||!path.isAbsolute(configHome))throw new Error('Invalid autostart configuration.');
 const directory=path.join(configHome,'autostart'),file=path.join(directory,'clipboardline.desktop');
 fs.mkdirSync(directory,{recursive:true});
 let stat;try{stat=fs.lstatSync(file);}catch(error){if(error.code!=='ENOENT')throw error;}
 if(stat){
  if(!stat.isFile()||stat.isSymbolicLink()||stat.size>16384||!fs.readFileSync(file,'utf8').split('\n').includes(OWNER))throw new Error('An existing clipboardline.desktop entry is not owned by ClipBoardLine.');
 }
 if(!enabled){if(stat)fs.unlinkSync(file);return;}
 if(!path.isAbsolute(executable))throw new Error('Invalid launch executable.');
 const text='[Desktop Entry]\nType=Application\nVersion=1.0\nName=ClipBoardLine\nComment=Local clipboard shelves and library\nExec='+[executable,...args].map(quote).join(' ')+'\nTerminal=false\n'+OWNER+'\n';
 const temporary=path.join(directory,'.clipboardline-'+require('node:crypto').randomUUID()+'.tmp');
 try{fs.writeFileSync(temporary,text,{flag:'wx',mode:0o600});fs.renameSync(temporary,file);}finally{fs.rmSync(temporary,{force:true});}
}
module.exports={setLaunchAtLogin,quote};
