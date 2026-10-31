'use strict';
const fs=require('node:fs'),path=require('node:path'),os=require('node:os');

// Electron's login items are macOS/Windows only. Linux desktops follow the
// XDG Autostart specification; the entry starts the same executable hidden.
const NAME='clipboardline.desktop';
function directory(environment=process.env){return path.join(environment.XDG_CONFIG_HOME||path.join(os.homedir(),'.config'),'autostart');}
function quote(value){return /^[A-Za-z0-9_./:=+-]+$/.test(value)?value:'"'+value.replace(/(["`$\\])/g,'\\$1')+'"';}
// An AppImage is mounted at a temporary path; its stable location is $APPIMAGE.
function command({environment=process.env,executable=process.execPath,argv=process.argv,packaged=true}={}){
  const program=environment.APPIMAGE||executable;
  return [program,...(packaged?[]:argv.slice(1,2)),'--hidden'].map(quote).join(' ');
}
function entry(options){return['[Desktop Entry]','Type=Application','Name=ClipBoardLine','Comment=Keyboard-first clipboard shelves','Exec='+command(options),'Icon=clipboardline','Terminal=false','X-GNOME-Autostart-enabled=true',''].join('\n');}
function setLaunchAtLogin(enabled,{environment=process.env,...options}={}){
  const folder=directory(environment),file=path.join(folder,NAME);
  if(!enabled){try{if(!fs.lstatSync(file).isSymbolicLink())fs.unlinkSync(file);}catch{}return;}
  fs.mkdirSync(folder,{recursive:true,mode:0o700});
  if(fs.existsSync(file)&&fs.lstatSync(file).isSymbolicLink())throw new Error('Autostart entry must not be a symlink.');
  const temporary=file+'.tmp-'+process.pid;fs.writeFileSync(temporary,entry({environment,...options}),{mode:0o644});fs.renameSync(temporary,file);
}
module.exports={setLaunchAtLogin,entry,command,directory};
