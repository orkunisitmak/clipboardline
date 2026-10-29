'use strict';
const fs=require('node:fs'),path=require('node:path');
const {exerciseEditor}=require('./image-editor-compositor-acceptance.cjs');
module.exports=async function({page,application,until,check,output}){
 const report={scope:'Actual Windows renderer, native persisted image media, isolated source/packaged/installed fixture',passed:false,runs:[]};
 try{for(const [width,height]of[[3840,2160],[7680,4320]]){
  const png=await page.evaluate(({width,height})=>{const canvas=document.createElement('canvas');canvas.width=width;canvas.height=height;const c=canvas.getContext('2d');c.fillStyle='#e2b46d';c.fillRect(0,0,width,height);c.fillStyle='#327fa1';c.fillRect(width*.4,height*.4,width*.2,height*.2);return canvas.toDataURL('image/png');},{width,height});
  const id=await application.evaluate(async({nativeImage},png)=>{const t=global.__clipboardLineTest,record=t.store.insert('image',nativeImage.createFromDataURL(png).toPNG(),{name:'Synthetic compositor acceptance image'});await t.command('show');return record.id;},png);
  try{const result=await exerciseEditor({page,id,width,height,until});report.runs.push(result);check('retained '+width+'×'+height+' markup keeps its decoded original and canvas, coalesces all97 pointer samples, and saves pixel-exact original/cropped PNGs',result);}
  finally{if(await page.locator('#markup-canvas').count())await page.keyboard.press('Control+Enter');if(await page.locator('#preview-dialog').count())await page.keyboard.press('Escape');await page.evaluate(async id=>{await window.clipboardLine.command('trash',{ids:[id]});await window.clipboardLine.command('delete',{ids:[id]});},id);}
 }
 report.passed=true;
 }finally{fs.writeFileSync(path.join(output,'image-editor-compositor.json'),JSON.stringify(report,null,2)+'\n');}
};
