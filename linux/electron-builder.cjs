'use strict';
const path=require('node:path'),fs=require('node:fs');
const base=require('../windows/package.json').build;
// Reuse the shipped renderer, dependencies and notices. Windows signing/update
// identity and installer remain untouched; Linux has its own application ID.
module.exports={
 ...base,
 appId:'com.clipboardline.desktop.linux',
 extraMetadata:{homepage:'https://github.com/orkunisitmak/clipboardline',desktopName:'clipboardline.desktop'},
 afterPack:async context=>{
  const executable=path.join(context.appOutDir,'clipboardline');
  fs.renameSync(executable,executable+'-bin');
  fs.writeFileSync(executable,'#!/bin/sh\nexec "$(dirname "$(readlink -f "$0")")/clipboardline-bin" --ozone-platform=x11 "$@"\n',{mode:0o755});
 },
 extraResources:[
  ...base.extraResources.filter(resource=>resource.from!=='native'),
  {from:path.join(__dirname,'build/clipboardline-x11'),to:'native/clipboardline-x11'}
 ],
 linux:{
  executableName:'clipboardline',syncDesktopName:true,icon:'assets/clipboardline.png',category:'Utility',
  target:['AppImage','deb'],artifactName:'ClipBoardLine-${version}-${arch}.${ext}',
  maintainer:'ClipBoardLine contributors',
  desktop:{entry:{Name:'ClipBoardLine',Comment:'Local clipboard shelves and library',StartupWMClass:'clipboardline',Categories:'Utility;'}}
 },
 deb:{depends:['libgtk-3-0','libnss3','libxss1','libasound2','libx11-6','libxfixes3','libgbm1','libxtst6','xdg-utils','ffmpeg']}
};
