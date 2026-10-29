'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
test('the app icon and every hicolor size the Linux packages install are square PNGs',()=>{
 const root=path.resolve(__dirname,'..'),pkg=require('../package.json'),signature=Buffer.from('89504e470d0a1a0a','hex');
 const square=(file,size)=>{const png=fs.readFileSync(path.join(root,file));assert.ok(png.subarray(0,8).equals(signature),file);assert.equal(png.readUInt32BE(16),size,file);assert.equal(png.readUInt32BE(20),size,file);};
 square('assets/clipboardline.png',1024);
 assert.equal(pkg.build.linux.icon,'assets/linux-icons');
 const sizes=[16,24,32,48,64,128,256,512];
 assert.deepEqual(fs.readdirSync(path.join(root,'assets/linux-icons')).sort(),sizes.map(size=>size+'x'+size+'.png').sort());
 for(const size of sizes)square('assets/linux-icons/'+size+'x'+size+'.png',size);
});
