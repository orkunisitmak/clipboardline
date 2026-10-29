'use strict';
const assert=require('node:assert/strict');
// Inspect the actual application/native startDrag handoff and generated files.
// This does not claim an external Explorer/editor drop has occurred.
module.exports=async({page,application,check})=>{
  const receipt=await application.evaluate(async()=>{
    const fs=process.getBuiltinModule('node:fs'),path=process.getBuiltinModule('node:path'),h=global.__clipboardLineTest,created=[];
    const first=h.store.insert('text','Native drag first synthetic text'),second=h.store.insert('text','Native drag second synthetic text'),link=h.store.insert('link','https://example.com/drag-reference');created.push(first.id,second.id,link.id);
    const image=h.store.data.items.find(value=>value.kind==='image'&&!value.trashedAt);if(!image)throw new Error('Native drag fixture image is unavailable');
    const contents=h.getWindow().webContents,original=contents.startDrag;let actual;
    contents.startDrag=payload=>{actual={files:payload.files.map(file=>({name:path.basename(file),managed:path.dirname(file)===h.store.mediaDirectory,bytes:fs.statSync(file).size,text:/\.(txt|url|desktop)$/.test(file)?fs.readFileSync(file,'utf8'):null})),iconReady:!payload.icon.isEmpty()};};
    try{
      const reply=await h.command('startDrag',{ids:[second.id,image.id,link.id,first.id]});if(reply.result?.error)throw new Error(reply.result.error);
      return{actual,expected:{first:first.text,second:second.text,link:link.url,ids:[second.id,image.id,link.id,first.id]}};
    }finally{contents.startDrag=original;for(const id of created){h.store.modify('trash',{ids:[id]});h.store.modify('delete',{ids:[id]});}}
  });
  assert.ok(receipt.actual?.iconReady);assert.equal(receipt.actual.files.length,4);
  const files=receipt.actual.files;assert.equal(files[0].text,receipt.expected.second);assert.equal(files[0].name,'0001-'+receipt.expected.ids[0]+'.txt');
  assert.equal(files[1].managed,true);assert.ok(files[1].bytes>0);
  // Each system's native link file: an Internet Shortcut, or a freedesktop Link entry.
  const link=process.platform==='linux'?{text:'[Desktop Entry]\nType=Link\nName=example.com\nURL='+receipt.expected.link+'\nIcon=text-html\n',extension:'.desktop'}:{text:'[InternetShortcut]\r\nURL='+receipt.expected.link+'\r\n',extension:'.url'};
  assert.equal(files[2].text,link.text);assert.equal(files[2].name,'0003-'+receipt.expected.ids[2]+link.extension);assert.equal(files[3].text,receipt.expected.first);
  check('native drag handoff supplies captured ordered text/image/link files with private generated labels (external drop not asserted)');
};
