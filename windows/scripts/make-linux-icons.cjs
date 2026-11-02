'use strict';
// Renders the freedesktop hicolor sizes from the shared artwork:
//   npx electron scripts/make-linux-icons.cjs assets/clipboardline.png assets/linux-icons
const {app,nativeImage}=require('electron');
const fs=require('node:fs'),path=require('node:path');
app.commandLine.appendSwitch('ozone-platform','headless');
const [source,destination]=process.argv.slice(-2).map(value=>path.resolve(value));
app.whenReady().then(()=>{
  const image=nativeImage.createFromPath(source);
  if(image.isEmpty()||image.getSize().width<512)throw new Error('The source artwork must be a PNG of at least 512px.');
  fs.mkdirSync(destination,{recursive:true});
  for(const size of [16,24,32,48,64,128,256,512])fs.writeFileSync(path.join(destination,`${size}x${size}.png`),image.resize({width:size,height:size,quality:'best'}).toPNG());
  app.exit(0);
}).catch(error=>{console.error(error.message);app.exit(1);});
