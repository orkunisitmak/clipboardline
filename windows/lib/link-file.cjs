'use strict';
// Native link file types: Windows Internet Shortcut (.url); freedesktop Link
// desktop entries (.desktop) on Linux, which KDE and GNOME file managers open.
function linkFile(url,{platform=process.platform}={}){
 if(typeof url!=='string'||/[\r\n\0]/.test(url))throw new Error('Invalid link.');
 if(platform==='linux'){
  // Desktop entry strings unescape \\, \n, \t, \r and \s, and a URL query may hold
  // a raw backslash, so each one is written escaped.
  let name='Link';try{name=new URL(url).hostname||name;}catch{}
  return{extension:'.desktop',bytes:'[Desktop Entry]\nType=Link\nName='+name+'\nURL='+url.replaceAll('\\','\\\\')+'\nIcon=text-html\n'};
 }
 return{extension:'.url',bytes:'[InternetShortcut]\r\nURL='+url+'\r\n'};
}
module.exports={linkFile};
