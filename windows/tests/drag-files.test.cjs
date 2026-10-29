'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {DragFiles}=require('../lib/drag-files.cjs');
function fixture(t){const root=fs.mkdtempSync(path.join(os.tmpdir(),'clipboardline-drag-test-'));t.after(()=>fs.rmSync(root,{recursive:true,force:true}));return root;}
const text=(number,value='Synthetic text')=>({id:'00000000-0000-4000-8000-'+String(number).padStart(12,'0'),kind:'text',text:value,name:'Sensitive title never used as a file name'});
test('native drag supplies one ordered private text/link file per item and preserves original images',t=>{
  const root=fixture(t),original=path.join(root,'original.png');fs.writeFileSync(original,'unchanged image bytes');const drag=new DragFiles(root);
  const first=text(2,'Line one\nLine two'),image={...text(1),kind:'image'},link={...text(3),kind:'link',url:'https://example.com/private?code=synthetic'};
  const batch=drag.prepare([first,image,link],id=>{assert.equal(id,image.id);return original;});
  assert.equal(batch.files.length,3);assert.equal(batch.files[1],original);assert.equal(fs.readFileSync(batch.files[0],'utf8'),first.text);assert.equal(fs.readFileSync(batch.files[2],'utf8'),'[InternetShortcut]\r\nURL='+link.url+'\r\n');
  assert.equal(path.basename(batch.files[0]),'0001-'+first.id+'.txt');assert.equal(path.basename(batch.files[2]),'0003-'+link.id+'.url');assert.ok(batch.files.every(file=>!file.includes('Sensitive')));
  const second=drag.prepare([first],()=>{throw new Error('No image');});assert.notEqual(batch.files[0],second.files[0]);drag.dispose();
  assert.equal(fs.existsSync(batch.batch),false);assert.equal(fs.existsSync(second.batch),false);assert.equal(fs.readFileSync(original,'utf8'),'unchanged image bytes');
});
test('closed, malformed and unsafe link records cannot create drag exports',t=>{
  const root=fixture(t),drag=new DragFiles(root);
  for(const value of [{...text(1),trashedAt:100},{...text(1),id:'../unexpected'},{...text(1),kind:'link',url:'https://example.com/\r\nOther=value'},{...text(1),kind:'link',url:'file:///private/local'}])assert.throws(()=>drag.prepare([value],()=>''));
  assert.deepEqual(fs.readdirSync(drag.directory),[]);
});
test('stale owned batches including interrupted partial writes are removed on the next drag session',t=>{
  const root=fixture(t),old=new DragFiles(root),batch=old.prepare([text(1),text(2)],()=>'' );fs.unlinkSync(batch.files[0]);
  const current=new DragFiles(root);assert.equal(fs.existsSync(batch.batch),false);assert.deepEqual(fs.readdirSync(current.directory),[]);
});
test('tampered manifests or unknown files cannot broaden cleanup to originals or unrelated data',t=>{
  const root=fixture(t),drag=new DragFiles(root),outside=path.join(root,'keep.txt');fs.writeFileSync(outside,'keep');const batch=drag.prepare([text(1)],()=>'' );
  const marker=path.join(batch.batch,'.clipboardline-drag.json');fs.writeFileSync(marker,JSON.stringify({owner:'clipboardline-native-drag-v1',files:['../keep.txt']}));
  assert.equal(drag.remove(batch.batch),false);assert.equal(fs.readFileSync(outside,'utf8'),'keep');assert.equal(fs.readFileSync(batch.files[0],'utf8'),'Synthetic text');
});
test('drag staging cannot redirect writes through a directory symlink',t=>{
  const root=fixture(t),outside=fs.mkdtempSync(path.join(os.tmpdir(),'clipboardline-drag-outside-'));t.after(()=>fs.rmSync(outside,{recursive:true,force:true}));
  try{fs.symlinkSync(outside,path.join(root,'native-drag'),'junction');}catch(error){if(error.code==='EPERM'){t.skip('This host cannot create directory links');return;}throw error;}
  assert.throws(()=>new DragFiles(root),/Unsafe drag staging/);assert.deepEqual(fs.readdirSync(outside),[]);
});
