'use strict';
const fs=require('node:fs'),path=require('node:path');
const {pathToFileURL}=require('node:url');
async function copyFiles({files,text='',marker=''}){
 if(!Array.isArray(files)||!files.length||files.length>1000)throw new Error('Select up to 1000 files.');
 for(const file of files){if(typeof file!=='string'||!path.isAbsolute(file))throw new Error('Invalid file path.');const stat=fs.lstatSync(file);if(!stat.isFile()||stat.isSymbolicLink())throw new Error('A copied file is unavailable.');}
 if(typeof text!=='string'||Buffer.byteLength(text)>1024*1024||typeof marker!=='string'||!/^[A-Za-z0-9+/]{22}==$/.test(marker))throw new Error('Invalid file clipboard payload.');
 const {clipboard,ClipboardItem,nativeImage}=require('electron');
 const uris=files.map(file=>pathToFileURL(file).href);
 const data={
  'electron application/osclipboard;format="text/uri-list"':new Blob([uris.join('\r\n')+'\r\n']),
  'electron application/osclipboard;format="x-special/gnome-copied-files"':new Blob(['copy\n'+uris.join('\n')]),
  'web application/x.clipboardline':new Blob([Buffer.from(marker,'base64')])
 };
 if(text)data['text/plain']=new Blob([text],{type:'text/plain'});
 if(files.every(file=>path.extname(file).toLowerCase()==='.png')){const image=nativeImage.createFromPath(files[0]);if(image.isEmpty())throw new Error('Image unavailable.');data['image/png']=new Blob([image.toPNG()],{type:'image/png'});}
 await clipboard.write([new ClipboardItem(data)]);return{ok:true};
}
module.exports={copyFiles,cancelFileCopies:()=>{}};
