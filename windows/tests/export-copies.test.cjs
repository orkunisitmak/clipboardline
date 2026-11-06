'use strict';

const assert=require('node:assert/strict');
const fs=require('node:fs');
const os=require('node:os');
const path=require('node:path');
const {test}=require('node:test');
const {exportCopies}=require('../lib/export-copies.cjs');

const exported=async items=>{
  const directory=fs.mkdtempSync(path.join(os.tmpdir(),'clipboardline-export-'));
  try{
    await exportCopies(items,directory,{mediaPath:()=>{throw new Error('No media in this test');}});
    return fs.readdirSync(directory).sort();
  }finally{fs.rmSync(directory,{recursive:true,force:true});}
};

test('does not export a copy under a Windows device name',async()=>{
  const names=await exported(['con','NUL','Com1','lpt9','aux.notes','COM¹','lpt³'].map(name=>({kind:'text',name,text:'body'})));
  assert.deepEqual(names,['_COM¹.txt','_Com1.txt','_NUL.txt','_aux.notes.txt','_con.txt','_lpt9.txt','_lpt³.txt']);
});

test('keeps names that only start like a device name',async()=>{
  const names=await exported(['console','com0','com10','nullable'].map(name=>({kind:'text',name,text:'body'})));
  assert.deepEqual(names,['com0.txt','com10.txt','console.txt','nullable.txt']);
});


test('truncating exported names preserves complete Unicode characters',async()=>{
  const emoji=String.fromCodePoint(0x1f9e0);
  const names=await exported([
    {kind:'text',name:'a'.repeat(99)+emoji+' extra',text:'first'},
    {kind:'text',name:'b'.repeat(98)+emoji+' extra',text:'second'}
  ]);
  assert.deepEqual(names,['a'.repeat(99)+'.txt','b'.repeat(98)+emoji+'.txt']);
});

test('exports a link as the platform link file and keeps going after an invalid one',async()=>{
  const directory=fs.mkdtempSync(path.join(os.tmpdir(),'clipboardline-export-'));
  try{
    const result=await exportCopies([{kind:'link',name:'Example',url:'https://example.com/a?b=1'},{kind:'link',name:'Broken',url:'https://example.com/\nExec=x'}],directory,{mediaPath:()=>{throw new Error('No media in this test');}});
    const extension=process.platform==='linux'?'.desktop':'.url';
    assert.deepEqual([result.count,result.failed,fs.readdirSync(directory)],[1,1,['Example'+extension]]);
    assert.match(fs.readFileSync(path.join(directory,'Example'+extension),'utf8'),/URL=https:\/\/example\.com\/a\?b=1\r?\n/);
  }finally{fs.rmSync(directory,{recursive:true,force:true});}
});
