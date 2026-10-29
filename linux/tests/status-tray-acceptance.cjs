'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
// The source/packaged/installed suite explicitly opts into a real native Tray
// with --test-tray plus its existing isolated test-mode data directory. No
// renderer IPC can create it or inject counts, images or presentation state.
module.exports=async({page,application,check,until,output})=>{
 const read=()=>application.evaluate(()=>{
  const h=global.__clipboardLineTest,{tray,presentation}=h.getTray(),crypto=process.getBuiltinModule('node:crypto');
  if(!tray||!presentation)throw new Error('The isolated actual native Tray was not enabled.');
  const image=presentation.image;
  return{nativeDestroyed:tray.isDestroyed(),bounds:tray.getBounds(),status:presentation.snapshot(),image:{size:image.getSize(),scales:image.getScaleFactors().sort((a,b)=>a-b),bitmapSHA256:crypto.createHash('sha256').update(image.toBitmap({scaleFactor:2})).digest('hex'),sampleAlpha:image.toBitmap({scaleFactor:2})[(16*32+10)*4+3]},menu:presentation.menu.items.filter(item=>item.id).map(item=>({id:item.id,label:item.label})),windowFocused:h.getWindow().isFocused()};
 });
 const original=await application.evaluate(()=>{const s=global.__clipboardLineTest.store.data.settings;return{visibleKinds:s.visibleKinds,language:s.language};});let ids=[],updateFixture=false;
 const command=(action,payload={})=>page.evaluate(({action,payload})=>window.clipboardLine.command(action,payload),{action,payload});
 const phases=[];
 try{
  await command('setSettings',{patch:{visibleKinds:['image','text','link'],language:'en'}});
  const empty=await until(read,value=>!value.nativeDestroyed&&value.bounds.width>0&&value.bounds.height>0);
  assert.deepEqual([empty.status.images,empty.status.texts,empty.status.links,empty.status.count,empty.status.badge,empty.status.dim],[0,0,0,0,'0',true]);assert.match(empty.status.tooltip,/The line is empty/);assert.deepEqual(empty.image.size,{width:16,height:16});assert.deepEqual(empty.image.scales,[1,2,3]);phases.push({phase:'empty',...empty});
  ids=await application.evaluate(async({nativeImage})=>{
   const h=global.__clipboardLineTest,crypto=process.getBuiltinModule('node:crypto'),prefix='Tray '+crypto.randomUUID(),ids=[];
   for(let index=0;index<10;index++){const reply=await h.command('newNote',{text:prefix+' '+index});ids.push(reply.result.id);}
   const png=nativeImage.createFromBitmap(Buffer.from([20,100,220,255,220,100,20,255,20,100,220,255,220,100,20,255]),{width:2,height:2}).toPNG();
   ids.push(h.store.insert('image',png).id);const other=nativeImage.createFromBitmap(Buffer.from([230,10,60,255,60,10,230,255,230,10,60,255,60,10,230,255]),{width:2,height:2}).toPNG();ids.push(h.store.insert('image',other).id);ids.push(h.store.insert('link','https://example.com/tray-synthetic').id);
   await h.command('setSettings',{patch:{visibleKinds:['image','text','link']}});return ids;
  });
  const live=await page.evaluate(()=>window.clipboardLine.state());ids=[...new Set(ids)];const imageIDs=live.items.filter(item=>ids.includes(item.id)&&item.kind==='image').map(item=>item.id),link=live.items.find(item=>ids.includes(item.id)&&item.kind==='link');assert.equal(imageIDs.length,2);assert.ok(link);
  const populated=await read();assert.deepEqual([populated.status.images,populated.status.texts,populated.status.links,populated.status.count,populated.status.badge,populated.status.dim],[imageIDs.length,10,1,imageIDs.length+11,'9+',false]);assert.notEqual(populated.image.bitmapSHA256,empty.image.bitmapSHA256);assert.ok(populated.image.sampleAlpha>empty.image.sampleAlpha);phases.push({phase:'all-visible',...populated});
  await command('setSettings',{patch:{visibleKinds:['image','link']}});let scoped=await read();assert.deepEqual([scoped.status.images,scoped.status.texts,scoped.status.links,scoped.status.count],[imageIDs.length,0,1,imageIDs.length+1]);
  await command('pin',{ids:[imageIDs[0]],value:true});await command('remove',{ids:imageIDs});await command('trash',{ids:[link.id]});const removed=await page.evaluate(()=>window.clipboardLine.state()),hiddenImage=removed.items.find(value=>value.id===imageIDs[0]),trashedImage=removed.items.find(value=>value.id===imageIDs[1]);assert.equal(hiddenImage.hiddenFromShelf,true);assert.ok(!hiddenImage.trashedAt);assert.ok(trashedImage.trashedAt);assert.ok(removed.items.find(value=>value.id===link.id).trashedAt);scoped=await read();assert.equal(scoped.status.count,0);assert.equal(scoped.status.dim,true);phases.push({phase:'hidden-and-trashed',hiddenImageExcluded:true,trashedImageExcluded:true,trashedLinkExcluded:true,...scoped});
  await command('setSettings',{patch:{visibleKinds:['text']}});const before=await read();assert.equal(before.status.count,10);await command('details',{id:ids[0],name:'Synthetic irrelevant status detail'});const unchanged=await read();assert.deepEqual(unchanged.status,before.status);assert.equal(unchanged.image.bitmapSHA256,before.image.bitmapSHA256);
  await command('setSettings',{patch:{language:'tr'}});const localized=await read();assert.equal(localized.status.description,'Askılarda 0 görsel · 10 metin · 0 link');assert.equal(localized.menu.find(value=>value.id==='tray-library').label,'Kütüphane');assert.equal(localized.menu.find(value=>value.id==='tray-settings').label,'Ayarlar');assert.equal(localized.status.imageRevision,before.status.imageRevision);assert.ok(localized.status.menuRevision>before.status.menuRevision);phases.push({phase:'localized',...localized});
  await command('setSettings',{patch:{visibleKinds:['link']}});const hidden=await read();assert.match(hidden.status.tooltip,/Askılar boş/);assert.equal(hidden.status.count,0);assert.equal(hidden.status.badge,'0');assert.equal(hidden.status.dim,true);assert.equal(hidden.image.bitmapSHA256,empty.image.bitmapSHA256);assert.ok(hidden.status.cachedIcons<=22);assert.equal(hidden.windowFocused,empty.windowFocused,'Tray refresh must not steal application focus');phases.push({phase:'only-trashed-visible',...hidden});
  await application.evaluate(()=>{const h=global.__clipboardLineTest,u=h.getUpdates();global.__nativeTrayUpdateFixture={manifest:u.manifest,state:{...u.state}};u.manifest={version:'99.0.0',build:9999};u.set({status:'available',error:null,message:'Synthetic native Tray update fixture'});});updateFixture=true;
  const updating=await read();assert.equal(updating.status.count,0);assert.equal(updating.status.badge,'0');assert.equal(updating.status.dim,false);assert.equal(updating.status.highlight,true);assert.match(updating.status.tooltip,/Askılar boş/);assert.match(updating.status.tooltip,/Güncelleme var/);assert.match(updating.status.tooltip,/99\.0\.0/);assert.equal(updating.menu.find(value=>value.id==='tray-update').label,'Güncelleme var: 99.0.0…');assert.notEqual(updating.image.bitmapSHA256,hidden.image.bitmapSHA256);assert.ok(updating.image.sampleAlpha>hidden.image.sampleAlpha);phases.push({phase:'empty-with-synthetic-update-availability',...updating});
  fs.writeFileSync(path.join(output,'native-status-tray.json'),JSON.stringify({sourceRevision:process.env.GITHUB_SHA||'',actualNativeTray:true,isolatedOptIn:true,readOnlyPresentation:true,syntheticUpdateFixture:true,phases},null,2)+'\n');
  check('actual native Tray displays shared scaled0/9+ badges, filters hidden/trashed and toggled shelves, dims empty unless an update is available, localizes counts/menu and skips unchanged packet rebuilds');
 }finally{
  await application.evaluate(async(_electron,{ids,original,updateFixture})=>{const h=global.__clipboardLineTest;if(updateFixture){const u=h.getUpdates(),saved=global.__nativeTrayUpdateFixture;u.manifest=saved.manifest;u.state=saved.state;u.derive();delete global.__nativeTrayUpdateFixture;}if(ids.length){h.store.modify('trash',{ids});h.store.modify('delete',{ids});}await h.command('setSettings',{patch:original});}, {ids,original,updateFixture});
 }
};
