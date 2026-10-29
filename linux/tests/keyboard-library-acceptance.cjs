'use strict';
const assert=require('node:assert/strict');
const path=require('node:path');

// Fixture construction uses the isolated model. Every behavior below then
// travels through the real renderer's keyboard and pointer event handlers.
module.exports=async function keyboardLibrary({page,application,textItem,folder,check,until,output}){
  const fixtures=await application.evaluate(({nativeImage})=>{
    const h=global.__clipboardLineTest,ids=[];
    for(let index=0;index<20;index++)ids.push(h.store.insert('text','Navigation fixture '+String(index).padStart(2,'0')).id);
    const text=h.store.insert('text','Shared search fixture result');ids.push(text.id);
    const link=h.store.insert('link','https://example.com/shared-search-fixture');ids.push(link.id);
    const width=240,height=140,bitmap=Buffer.alloc(width*height*4);for(let y=0;y<height;y++)for(let x=0;x<width;x++){const offset=(y*width+x)*4,accent=x>22&&x<218&&y>24&&y<116;bitmap[offset]=accent?130+Math.round(x/4):70;bitmap[offset+1]=accent?100+Math.round(y/2):150;bitmap[offset+2]=accent?90:90;bitmap[offset+3]=255;}
    for(let index=0;index<12;index++){const pixels=Buffer.from(bitmap);pixels[0]=index+1;const value=h.store.insert('image',nativeImage.createFromBitmap(pixels,{width,height}).toPNG());value.name='Navigation image '+index;ids.push(value.id);}
    for(let index=0;index<10;index++)ids.push(h.store.insert('link','https://example.com/navigation-link/'+index).id);
    const image=h.store.insert('image',nativeImage.createFromBitmap(bitmap,{width,height}).toPNG());image.ocrText='Shared search fixture result';image.note='Vertical-only fixture';link.note='Vertical-only fixture';h.store.persist();ids.push(image.id);
    return{ids,image:image.id,text:text.id,link:link.id};
  });
  const focus=()=>page.locator('[data-shelf="text"] .card.focused').getAttribute('data-item-id');
  await page.evaluate(()=>window.clipboardLine.command('show'));
  const shelfSnapshot=()=>page.locator('.shelves').evaluate(node=>({active:node.querySelector('.active-shelf')?.dataset.shelf,focus:node.querySelector('.card.focused')?.dataset.itemId||null,selected:[...node.querySelectorAll('.card.selected')].map(card=>card.dataset.itemId),kinds:[...node.querySelectorAll('[data-shelf]')].map(row=>row.dataset.shelf)}));
  const expectShelf=async(kind,id)=>{const snapshot=await until(shelfSnapshot,value=>value.active===kind&&value.focus===id&&value.selected.length===1&&value.selected[0]===id);assert.deepEqual(snapshot.selected,[id]);return snapshot;};
  const reopen=async()=>{await page.evaluate(()=>window.clipboardLine.command('hide'));await page.evaluate(()=>window.clipboardLine.command('show'));};
  const current=await page.evaluate(()=>window.clipboardLine.state()),orderedByKind=Object.fromEntries(['image','text','link'].map(kind=>[kind,current.items.filter(value=>value.kind===kind&&!value.trashedAt&&!value.hiddenFromShelf).sort((a,b)=>b.createdAt-a.createdAt)]));
  await reopen();await expectShelf('image',orderedByKind.image[0].id);
  check('fresh shelf reveal selects only the first image across all three visible rows');

  await page.keyboard.press('Control+ArrowRight');const imageColumn=orderedByKind.image.length-1;await expectShelf('image',orderedByKind.image[imageColumn].id);
  assert.ok(imageColumn>=9,'The native column check must cross the first numbered page');
  await page.keyboard.press('ArrowDown');const textColumn=Math.min(imageColumn,orderedByKind.text.length-1);await expectShelf('text',orderedByKind.text[textColumn].id);
  await page.keyboard.press('ArrowDown');const linkColumn=Math.min(textColumn,orderedByKind.link.length-1);await expectShelf('link',orderedByKind.link[linkColumn].id);
  await page.keyboard.press('ArrowDown');await expectShelf('link',orderedByKind.link[linkColumn].id);
  await page.keyboard.press('ArrowUp');await expectShelf('text',orderedByKind.text[linkColumn].id);
  await page.keyboard.press('ArrowUp');await expectShelf('image',orderedByKind.image[linkColumn].id);
  await page.keyboard.press('ArrowUp');await expectShelf('image',orderedByKind.image[linkColumn].id);
  await page.keyboard.press('ArrowLeft');await expectShelf('image',orderedByKind.image[linkColumn-1].id);
  await page.keyboard.press('ArrowRight');await expectShelf('image',orderedByKind.image[linkColumn].id);
  check('closed-preview Up/Down cross visible rows by full filtered column, clamp without wrap and keep Left/Right in the row',{imageColumn,textColumn,linkColumn});

  await page.keyboard.press('Space');await page.locator('#preview-dialog').waitFor({state:'visible'});
  await page.keyboard.press('ArrowDown');await expectShelf('text',orderedByKind.text[linkColumn].id);
  assert.equal(await page.locator('#preview-dialog .preview-text').textContent(),orderedByKind.text[linkColumn].text);
  await page.keyboard.press('Enter');await until(()=>application.evaluate(()=>global.__clipboardLineTest.getWindow().isVisible()),visible=>!visible);
  assert.equal(await application.evaluate(async({clipboard})=>await clipboard.readText()),orderedByKind.text[linkColumn].text);
  await page.evaluate(()=>window.clipboardLine.command('show'));await expectShelf('image',orderedByKind.image[0].id);
  await page.keyboard.press('Enter');await until(()=>application.evaluate(()=>global.__clipboardLineTest.getWindow().isVisible()),visible=>!visible);
  assert.equal(await application.evaluate(async({clipboard})=>(await clipboard.read()).some(entry=>entry.types.includes('image/png'))),true);
  await page.evaluate(()=>window.clipboardLine.command('show'));await expectShelf('image',orderedByKind.image[0].id);
  check('Space preview follows the selected shelf and Enter copies actual text/image then reopening resets to the first image');

  await page.keyboard.press('ArrowDown');await page.keyboard.press('ArrowRight');const kept=orderedByKind.text[1].id;await expectShelf('text',kept);
  for(const key of ['Shift+i','Shift+i','Shift+l','Shift+l']){await page.keyboard.press(key);await expectShelf('text',kept);}
  await page.keyboard.press('Shift+t');await expectShelf('image',orderedByKind.image[0].id);await page.keyboard.press('Shift+t');await expectShelf('image',orderedByKind.image[0].id);
  check('enabling a shelf preserves the active item without adding another row selection; hiding its row chooses the first image');

  await page.keyboard.press('Shift+s');await page.locator('#search-input').fill('vertical-only');await page.keyboard.press('ArrowLeft');assert.equal(await page.locator('#search-input').evaluate(element=>element===document.activeElement),true);
  await page.keyboard.press('ArrowDown');await expectShelf('image',fixtures.image);
  await page.keyboard.press('ArrowDown');await expectShelf('link',fixtures.link);await page.keyboard.press('ArrowUp');await expectShelf('image',fixtures.image);
  await page.keyboard.press('Escape');await page.keyboard.press('Shift+t');await page.keyboard.press('ArrowDown');await expectShelf('link',orderedByKind.link[0].id);
  await page.keyboard.press('Shift+t');await expectShelf('link',orderedByKind.link[0].id);
  check('row arrows skip empty search results and hidden shelves while native search caret keys retain editor focus');

  await reopen();await expectShelf('image',orderedByKind.image[0].id);await page.keyboard.press('Alt+ArrowRight');
  await page.keyboard.press('Shift+s');await page.locator('#search-input').fill('Navigation fixture 00');
  await reopen();await expectShelf('image',orderedByKind.image[0].id);assert.equal(await page.locator('.search-hud,.search-summary').count(),0);
  await page.keyboard.press('1');await expectShelf('image',orderedByKind.image[0].id);
  await page.keyboard.press('Shift+i');await reopen();await expectShelf('text',orderedByKind.text[0].id);
  await page.keyboard.press('Shift+i');await expectShelf('text',orderedByKind.text[0].id);await reopen();await expectShelf('image',orderedByKind.image[0].id);
  await page.locator('[data-action="pinned-kind"][data-kind="image"]').click();await reopen();await expectShelf('text',orderedByKind.text[0].id);
  await page.locator('[data-action="pinned-kind"][data-kind="image"]').click();await reopen();await expectShelf('image',orderedByKind.image[0].id);
  check('fresh reopen clears stale search/pages and uses the first visible nonempty shelf when images are hidden or filtered empty');
  const geometry=await page.evaluate(()=>({height:innerHeight,width:innerWidth,rows:[...document.querySelectorAll('[data-shelf]')].map(row=>{const box=row.getBoundingClientRect(),cards=row.querySelector('.cards').getBoundingClientRect();return{kind:row.dataset.shelf,top:box.top,bottom:box.bottom,numbers:[...row.querySelectorAll('.card-number')].map(number=>{const rect=number.getBoundingClientRect();return{left:rect.left,right:rect.right,top:rect.top,bottom:rect.bottom,within:rect.left>=cards.left-2&&rect.right<=cards.right+2&&rect.top>=cards.top-2&&rect.bottom<=cards.bottom+2};})};})}));
  assert.equal(geometry.rows.length,3);for(const row of geometry.rows){assert.ok(row.top>=-1&&row.bottom<=geometry.height+1,JSON.stringify(geometry));assert.ok(row.numbers.every(number=>number.within),JSON.stringify(row));}
  await page.screenshot({path:path.join(output,'shelves-all-kinds.png')});
  const regularBounds=await application.evaluate(()=>global.__clipboardLineTest.getWindow().getBounds()),regularSize=(await page.evaluate(()=>window.clipboardLine.state())).settings.cardSize;
  await page.evaluate(()=>window.clipboardLine.command('setSettings',{patch:{cardSize:'large'}}));await application.evaluate(()=>global.__clipboardLineTest.getWindow().setBounds({height:600}));await page.waitForFunction(()=>innerHeight===600);
  const shortRows=await page.locator('[data-shelf]').evaluateAll(rows=>rows.map(row=>{const rect=row.getBoundingClientRect();return{kind:row.dataset.shelf,top:rect.top,bottom:rect.bottom};}));assert.ok(shortRows.every(row=>row.top>=-1&&row.bottom<=601),JSON.stringify(shortRows));
  await page.evaluate(size=>window.clipboardLine.command('setSettings',{patch:{cardSize:size}}),regularSize);await application.evaluate((_electron,bounds)=>global.__clipboardLineTest.getWindow().setBounds(bounds),regularBounds);await page.waitForFunction(height=>innerHeight===height,regularBounds.height);
  check('all three shelf rows and every rendered quick number remain inside the window');
  await page.locator('[data-action="activate-shelf"][data-kind="text"]').click();
  await page.keyboard.press('Control+ArrowLeft');await until(focus,id=>id===fixtures.text);
  const pageSize=await page.locator('[data-shelf="text"]').getAttribute('data-page-size');assert.ok(Number(pageSize)>0&&Number(pageSize)<=9,pageSize);
  const ordered=(await page.evaluate(()=>window.clipboardLine.state())).items.filter(item=>item.kind==='text'&&!item.trashedAt&&!item.hiddenFromShelf).sort((a,b)=>b.createdAt-a.createdAt);
  await page.keyboard.press('Alt+ArrowRight');await until(focus,id=>id===ordered[Number(pageSize)].id);
  await page.keyboard.press('Alt+ArrowLeft');await until(focus,id=>id===ordered[0].id);
  await page.keyboard.press('Control+ArrowRight');await until(focus,id=>id===ordered.at(-1).id);
  await page.keyboard.press('Control+ArrowLeft');await until(focus,id=>id===ordered[0].id);
  check('real Ctrl first/last and Alt page jumps follow the visible shelf page size');

  const beforeSearch=await page.locator('[data-shelf]').evaluateAll(rows=>rows.map(row=>{const rect=row.getBoundingClientRect();return{top:rect.top,bottom:rect.bottom};}));
  await page.keyboard.press('Shift+s');await page.locator('#search-input').waitFor({state:'visible'});
  const hud=await page.locator('.search-hud').boundingBox(),screen=await page.evaluate(()=>({width:innerWidth,height:innerHeight}));assert.ok(hud&&Math.abs(hud.x+hud.width/2-screen.width/2)<=5&&Math.abs(hud.y+hud.height/2-screen.height/2)<=15,JSON.stringify({hud,screen}));
  assert.deepEqual(await page.locator('[data-shelf]').evaluateAll(rows=>rows.map(row=>{const rect=row.getBoundingClientRect();return{top:rect.top,bottom:rect.bottom};})),beforeSearch);
  await page.locator('#search-input').fill('shared search fixture');await page.screenshot({path:path.join(output,'search-hud.png')});await page.keyboard.press('ArrowDown');
  await until(()=>page.locator('[data-item-id]').count(),count=>count===3);
  await page.locator(`[data-shelf="image"] [data-item-id="${fixtures.image}"]`).click();await page.keyboard.press('Space');
  await page.locator('#preview-dialog').waitFor({state:'visible'});await page.keyboard.press('ArrowDown');
  await until(()=>page.locator('#preview-dialog').getAttribute('aria-label'),label=>label==='Shared search fixture result');
  await page.keyboard.press('ArrowDown');await until(()=>page.locator('#preview-dialog').getAttribute('aria-label'),label=>label.includes('shared-search-fixture'));
  await page.keyboard.press('Escape');await page.keyboard.press('Shift+l');await until(()=>page.locator('[data-shelf="link"]').count(),count=>count===0);
  assert.equal(await page.locator(`[data-item-id="${fixtures.link}"]`).count(),0);assert.equal(await page.locator('[data-item-id]').count(),2);
  await page.keyboard.press('Shift+l');await until(()=>page.locator('[data-shelf="link"]').count(),count=>count===1);
  await page.keyboard.press('Escape');check('shared shelf search uses OCR/text/links and excludes a toggled-off shelf');

  await page.locator('[data-action="activate-shelf"][data-kind="text"]').click();await page.keyboard.press('Control+ArrowLeft');
  const first=ordered[0].id,second=ordered[1].id;
  await page.locator(`[data-shelf="text"] [data-item-id="${first}"]`).click();await page.locator(`[data-shelf="text"] [data-item-id="${second}"]`).click({modifiers:['Control']});
  await page.keyboard.press('Alt+p');await page.locator('#name-input').fill('Named navigation one');await page.keyboard.press('Enter');await until(()=>page.locator('#overlay-root .dialog p').first().textContent(),value=>/2\s*\/\s*2/.test(value));
  await page.locator('#name-input').fill('Named navigation two');await page.keyboard.press('Enter');await page.locator('#name-input').waitFor({state:'hidden'});
  let state=await page.evaluate(()=>window.clipboardLine.state());assert.ok(state.items.find(item=>item.id===first).pinned&&state.items.find(item=>item.id===second).pinned);
  assert.deepEqual([state.items.find(item=>item.id===first).name,state.items.find(item=>item.id===second).name],['Named navigation one','Named navigation two']);
  await page.locator(`[data-shelf="text"] [data-item-id="${first}"]`).click();await page.keyboard.press('Shift+p');await page.locator('#modal-query').fill(folder.name);await until(()=>page.locator('[data-action="choose-folder"]').count(),count=>count===1);assert.equal(await page.locator('[data-action="choose-folder"]').getAttribute('data-folder'),folder.id);await page.keyboard.press('Enter');
  const pinnedFolderState=await until(()=>page.evaluate(()=>window.clipboardLine.state()),next=>next.items.find(item=>item.id===first).folderIds.includes(folder.id));assert.equal(pinnedFolderState.settings.recentPinFolderIds[0],folder.id);
  await page.keyboard.press('Shift+p');await page.locator('[data-action="choose-folder"]').first().waitFor({state:'visible'});assert.equal(await page.locator('[data-action="choose-folder"]').first().getAttribute('data-folder'),folder.id);assert.equal(await page.locator('[data-action="choose-folder"]').last().getAttribute('data-folder'),'');await page.keyboard.press('Escape');await page.locator('[data-action="choose-folder"]').first().waitFor({state:'hidden'});assert.deepEqual((await page.evaluate(()=>window.clipboardLine.state())).settings.recentPinFolderIds,pinnedFolderState.settings.recentPinFolderIds);
  await page.keyboard.press('f');await until(()=>page.locator('[data-shelf="text"] .card').count(),count=>count===3);await page.keyboard.press('f');
  await page.keyboard.press('s');await until(()=>page.locator(`[data-shelf="text"] [data-item-id="${first}"]`).count(),count=>count===0);await page.keyboard.press('Backspace');await until(()=>page.locator(`[data-shelf="text"] [data-item-id="${first}"]`).count(),count=>count===1);
  check('real sequential AltP naming, successful ShiftP recent-folder defaults, cancel, F pins and S/Backspace undo preserve organization');

  await page.evaluate(()=>window.clipboardLine.command('settings'));
  await page.locator('[data-action="settings-tab"][data-tab="shortcuts"]').click();await page.locator('[data-action="record-local"][data-key-action="pin"]').click();
  await page.keyboard.press('o');await page.locator('[data-action="confirm-modal"]').click();
  await until(()=>page.evaluate(()=>window.clipboardLine.state()),next=>next.settings.localShortcuts.pin==='O');
  await page.locator('[data-action="settings-tab"][data-tab="history"]').click();await page.locator('[data-retention="text"]').selectOption('7');await page.locator('[data-retention="link"]').selectOption('3');
  await until(()=>page.evaluate(()=>window.clipboardLine.state()),next=>next.settings.retentionDays.text===7&&next.settings.retentionDays.link===3);
  await page.evaluate(()=>window.clipboardLine.command('show'));await page.locator(`[data-shelf="text"] [data-item-id="${first}"]`).click();await page.keyboard.press('o');
  await until(()=>page.evaluate(()=>window.clipboardLine.state()),next=>next.items.find(item=>item.id===first).pinned===false);
  await page.keyboard.press('o');await page.evaluate(()=>window.clipboardLine.command('setSettings',{patch:{localShortcuts:{pin:'P'},retentionDays:{text:30,link:30}}}));
  check('actual Settings shortcut recorder and independent text/link retention controls work');

  await page.keyboard.press('l');await until(()=>page.evaluate(()=>window.clipboardLine.state()),next=>next.view==='library');
  await page.locator('[data-action="scope"][data-scope="recent"]').click();await page.keyboard.press('Control+ArrowLeft');
  const grid=await page.locator('.library-grid > .card').evaluateAll(cards=>({columns:cards.filter(card=>card.offsetTop===cards[0].offsetTop).length,ids:cards.map(card=>card.dataset.itemId)}));assert.ok(grid.ids.length>grid.columns);
  await page.keyboard.press('ArrowDown');await until(()=>page.locator('.library-grid .card.focused').getAttribute('data-item-id'),id=>id===grid.ids[grid.columns]);await page.keyboard.press('ArrowUp');await until(()=>page.locator('.library-grid .card.focused').getAttribute('data-item-id'),id=>id===grid.ids[0]);
  await page.screenshot({path:path.join(output,'library-grid.png')});
  check('Library vertical arrows use the actual rendered grid column count');
  await page.locator(`[data-action="folder-scope"][data-folder="${folder.id}"]`).click();
  await page.locator(`[data-item-id="${first}"]`).waitFor({state:'visible'});assert.equal(await page.locator(`[data-item-id="${second}"]`).count(),0);
  await page.keyboard.press('Control+f');await page.locator('#search-input').fill('Named navigation one');await page.keyboard.press('Enter');
  await until(()=>page.locator('.library-card,.library-grid .card').count(),count=>count===1);
  await page.locator(`[data-item-id="${first}"]`).click();await page.keyboard.press('Enter');await until(()=>application.evaluate(async({clipboard})=>await clipboard.readText()),value=>value==='Shared search fixture result');
  assert.equal((await page.evaluate(()=>window.clipboardLine.state())).windowVisible,true);assert.equal((await page.evaluate(()=>window.clipboardLine.state())).view,'library');
  await page.keyboard.press('Space');await page.locator('#preview-dialog').waitFor({state:'visible'});await page.keyboard.press('Enter');
  assert.equal((await page.evaluate(()=>window.clipboardLine.state())).windowVisible,true);assert.equal(await page.locator('#preview-dialog').isVisible(),true);await page.keyboard.press('Escape');
  await page.keyboard.press('Control+2');assert.equal(await page.locator('[data-action="texts"]').getAttribute('aria-pressed'),'true');assert.equal(await page.locator('.library-grid .kind-image,.library-grid .kind-link').count(),0);assert.equal(await page.locator('.library-grid .kind-text').count(),1);await page.keyboard.press('Control+0');assert.equal(await page.locator('[data-action="allTypes"]').getAttribute('aria-pressed'),'true');
  await page.keyboard.press('Control+f');await page.locator('#search-input').fill('');await page.keyboard.press('Enter');
  await page.locator('[data-action="tag-scope"][data-tag="work"]').click();await page.locator(`[data-item-id="${textItem.id}"]`).waitFor({state:'visible'});
  check('Library folder/tag/type/search filters and Enter copy retain the normal Library window');
  await page.locator(`[data-action="folder-menu"][data-folder="${folder.id}"]`).click();await page.keyboard.press('ArrowDown');await page.keyboard.press('Enter');
  await page.locator('#simple-input').fill('Native child fixture');await page.keyboard.press('Enter');
  const childState=await until(()=>page.evaluate(()=>window.clipboardLine.state()),next=>next.folders.some(value=>value.name==='Native child fixture'&&value.parentId===folder.id)),child=childState.folders.find(value=>value.name==='Native child fixture'&&value.parentId===folder.id);
  await page.locator(`[data-action="folder-menu"][data-folder="${child.id}"]`).click();await page.keyboard.press('Enter');await page.locator('#simple-input').fill('Renamed native child fixture');await page.keyboard.press('Enter');
  await until(()=>page.evaluate(()=>window.clipboardLine.state()),next=>next.folders.some(value=>value.id===child.id&&value.name==='Renamed native child fixture'));
  await page.locator(`[data-action="folder-menu"][data-folder="${child.id}"]`).click();await page.keyboard.press('ArrowDown');await page.keyboard.press('ArrowDown');await page.keyboard.press('Enter');
  assert.ok((await page.evaluate(()=>window.clipboardLine.state())).folders.some(value=>value.id===child.id));await page.keyboard.press('Enter');
  const afterFolder=await until(()=>page.evaluate(()=>window.clipboardLine.state()),next=>!next.folders.some(value=>value.id===child.id));assert.ok(afterFolder.folders.some(value=>value.id===folder.id&&value.name===folder.name));
  check('Library folder menu keyboard creates a subfolder, renames it and requires removal confirmation');
  // Remove only this function's fixture records before later native paste tests.
  await page.evaluate(ids=>window.clipboardLine.command('trash',{ids}),fixtures.ids);await page.evaluate(ids=>window.clipboardLine.command('delete',{ids}),fixtures.ids);
  await application.evaluate(async(_electron,text)=>{const h=global.__clipboardLineTest;h.store.insert('text',text);await h.command('show');},textItem.text);
};
