'use strict';
const fs=require('node:fs'),path=require('node:path'),os=require('node:os'),crypto=require('node:crypto');

// Electron's login-item API covers macOS and Windows only. Linux desktops
// start entries from $XDG_CONFIG_HOME/autostart (XDG Autostart specification).
const NAME='clipboardline.desktop',OWNER='X-ClipBoardLine-Autostart=true';
function autostartFile(env=process.env){
 const base=env.XDG_CONFIG_HOME&&path.isAbsolute(env.XDG_CONFIG_HOME)?env.XDG_CONFIG_HOME:path.join(env.HOME||os.homedir(),'.config');
 return path.join(base,'autostart',NAME);
}
// Desktop Entry Exec quoting: arguments with reserved characters are double
// quoted. Characters that need two escaping layers are rejected instead.
function execArgument(value){
 if(typeof value!=='string'||!value||/[\0-\x1f"`$\\]/.test(value))throw new Error('This application path cannot be used in an autostart entry.');
 const escaped=value.replace(/%/g,'%%');
 return /^[A-Za-z0-9_@%+=:,./-]+$/.test(escaped)?escaped:'"'+escaped+'"';
}
function autostartEntry({command,name='ClipBoardLine'}){
 if(!Array.isArray(command)||!command.length)throw new Error('Invalid autostart command.');
 return['[Desktop Entry]','Type=Application','Name='+name.replace(/[\r\n]/g,' '),'Comment=Keyboard-first clipboard shelves','Exec='+command.map(execArgument).join(' '),'Icon=clipboardline','Terminal=false','X-GNOME-Autostart-enabled=true',OWNER,''].join('\n');
}
function setAutostart(enabled,{command,env=process.env,name}={}){
 const file=autostartFile(env),directory=path.dirname(file);
 const existing=(()=>{try{return fs.lstatSync(file);}catch{return null;}})();
 if(existing&&(!existing.isFile()||existing.isSymbolicLink()))throw new Error('The autostart entry is not a regular file.');
 // Never replace or delete an entry another tool or the user wrote.
 if(existing&&!fs.readFileSync(file,'utf8').includes(OWNER))throw new Error('Another autostart entry named '+NAME+' already exists.');
 if(!enabled){if(existing)fs.unlinkSync(file);return false;}
 fs.mkdirSync(directory,{recursive:true,mode:0o700});
 const temporary=path.join(directory,'.'+NAME+'.'+crypto.randomUUID());
 try{fs.writeFileSync(temporary,autostartEntry({command,name}),{flag:'wx',mode:0o644});fs.renameSync(temporary,file);}
 finally{try{fs.unlinkSync(temporary);}catch{}}
 return true;
}
function autostartEnabled(env=process.env){try{const file=autostartFile(env);return fs.lstatSync(file).isFile()&&fs.readFileSync(file,'utf8').includes(OWNER);}catch{return false;}}
module.exports={setAutostart,autostartEnabled,autostartEntry,autostartFile,execArgument};
