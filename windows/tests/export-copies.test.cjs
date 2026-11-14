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
