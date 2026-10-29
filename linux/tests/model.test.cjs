'use strict';
const {test}=require('node:test');const assert=require('node:assert/strict');const fs=require('node:fs');const os=require('node:os');const path=require('node:path');
const {Store,plainURL}=require('../lib/model.cjs');
const png=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==','base64');
function fixture(fn){const dir=fs.mkdtempSync(path.join(os.tmpdir(),'clipboardline-model-'));let now=1000;try{const store=new Store(dir,{clock:()=>now});return fn(store,value=>{now=value;},dir);}finally{fs.rmSync(dir,{recursive:true,force:true});}}
test('exact recopy moves a text to front and preserves saved organization',()=>fixture((s,time)=>{const first=s.insert('text','API key exact value');s.modify('name',{id:first.id,name:'Service key'});const folder=s.modify('createFolder',{name:'Work'});s.modify('folder',{ids:[first.id],folderId:folder.id});s.modify('tag',{ids:[first.id],tags:['api']});time(2000);s.insert('text','something else');time(3000);const latest=s.insert('text','API key exact value');assert.equal(s.data.items.length,2);assert.equal(latest.id,first.id);assert.equal(latest.name,'Service key');assert.deepEqual(latest.folderIds,[folder.id]);assert.deepEqual(latest.tags,['api']);assert.equal(latest.createdAt,3000);assert.equal(s.data.items[0].id,first.id);}));
test('dedup normalizes selection newlines while preserving spaces and case',()=>fixture(s=>{for(const value of ['foo','foo ','Foo','foo\n'])s.insert('text',value);assert.equal(s.data.items.length,3);assert.equal(s.data.items[0].text,'foo\n');}));
test('URLs must be a sole public-protocol URL, normal prose stays text',()=>{assert.equal(plainURL('hello https://example.com'),null);assert.equal(plainURL('javascript:alert(1)'),null);assert.equal(plainURL('https://secret@example.com'),null);assert.equal(plainURL('https://example.com'), 'https://example.com/');});
test('retention is per-kind; pinned/folder/tag records remain permanent',()=>fixture((s,time)=>{const text=s.insert('text','expiring text'),link=s.insert('link','https://example.com'),saved=s.insert('text','tagged');s.modify('tag',{ids:[saved.id],tags:['keep']});s.modify('setSettings',{patch:{retentionDays:{text:1,link:3,image:0}}});time(2*86400000);s.expire();assert.ok(text.trashedAt);assert.equal(link.trashedAt,null);assert.equal(saved.trashedAt,null);}));
test('remove hides saved items, trashes temporary ones; undo preserves later edits',()=>fixture(s=>{const saved=s.insert('text','saved'),temp=s.insert('text','temporary');s.modify('pin',{ids:[saved.id]});s.modify('remove',{ids:[saved.id,temp.id]});assert.equal(saved.hiddenFromShelf,true);assert.ok(temp.trashedAt);s.modify('name',{id:saved.id,name:'Later name'});s.modify('undo');assert.equal(saved.hiddenFromShelf,false);assert.equal(temp.trashedAt,null);assert.equal(saved.name,'Later name');}));
test('explicit Trash invalidates removal undo and deletion requires Trash',()=>fixture(s=>{const item=s.insert('text','text');assert.throws(()=>s.modify('delete',{ids:[item.id]}));s.modify('remove',{ids:[item.id]});s.modify('restore',{ids:[item.id]});assert.equal(s.undoStack.length,0);s.modify('trash',{ids:[item.id]});s.modify('delete',{ids:[item.id]});assert.equal(s.data.items.length,0);}));
test('batch operations are atomic when one content kind is invalid',()=>fixture(s=>{const text=s.insert('text','before'),image=s.insert('image',png);assert.throws(()=>s.modify('editText',{ids:[text.id,image.id],text:'after'}));assert.equal(s.item(text.id).text,'before');}));
test('safe JSON persistence reloads content and stores rollback copy',()=>fixture((s,_time,dir)=>{const item=s.insert('text','private locally saved');s.modify('pin',{ids:[item.id]});assert.equal(new Store(dir).item(item.id).pinned,true);assert.ok(fs.existsSync(path.join(dir,'library.json.backup')));if(process.platform!=='win32')assert.equal(fs.statSync(path.join(dir,'library.json')).mode&0o777,0o600);else{const powershell=path.join(process.env.SystemRoot,'System32','WindowsPowerShell','v1.0','powershell.exe');const raw=require('node:child_process').execFileSync(powershell,['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',path.join(__dirname,'..','native','protect-directory.ps1'),'-Directory',dir,'-Check'],{windowsHide:true,encoding:'utf8',env:require('../lib/windows-environment.cjs').windowsEnvironment()});const acl=JSON.parse(raw);assert.equal(acl.protected,true);assert.ok(acl.principals.includes(acl.currentUser));assert.deepEqual([...new Set(acl.principals)].sort(),[acl.currentUser,'S-1-5-18','S-1-5-32-544'].sort());}}));
test('corrupt library is preserved rather than replaced',()=>fixture((s,_time,dir)=>{s.insert('text','important');fs.writeFileSync(s.file,'broken JSON');assert.throws(()=>new Store(dir),/Original data was preserved/);assert.equal(fs.readFileSync(s.file,'utf8'),'broken JSON');}));
test('managed PNG storage is hashed, immutable, private and protocol-only in public state',()=>fixture(s=>{const item=s.insert('image',png);assert.equal(fs.readFileSync(s.mediaPath(item.id)).toString('hex'),png.toString('hex'));const before=item.imageFile;s.modify('saveImage',{id:item.id,dataUrl:'data:image/png;base64,'+png.toString('base64'),crop:{x:0,y:0,width:1,height:1},annotations:[{type:'marker',x:0,y:0}]});assert.equal(item.imageFile,before);const state=s.publicState().items[0];assert.equal(state.imageFile,undefined);assert.equal(state.mediaUrl,'appmedia://media/'+item.id+'?v='+state.mediaRevision);assert.throws(()=>s.mediaPath('../library.json'));}));
test('oversize or invalid image and path traversal data are rejected',()=>fixture(s=>{assert.throws(()=>s.insert('image',Buffer.from('not png')));const item=s.insert('image',png);item.imageFile='../../library.json';assert.throws(()=>s.mediaPath(item.id));}));
test('folder rename/removal retains items while removing nested folders and memberships',()=>fixture(s=>{const parent=s.modify('createFolder',{name:'Parent'}),child=s.modify('createFolder',{name:'Child',parentId:parent.id});const item=s.insert('text','kept');s.modify('folder',{ids:[item.id],folderId:parent.id});s.modify('renameFolder',{id:parent.id,name:'New'});assert.equal(parent.name,'New');s.modify('removeFolder',{id:parent.id});assert.ok(!s.data.folders.some(folder=>folder.id===parent.id||folder.id===child.id));assert.equal(item.pinned,true);assert.deepEqual(item.folderIds,[]);}));
test('additive Library folder assignment preserves each pin and old memberships while the pin-to-folder command still pins',()=>fixture(s=>{const a=s.modify('createFolder',{name:'Existing'}),b=s.modify('createFolder',{name:'Additional'}),first=s.insert('text','first unpinned'),second=s.insert('text','second pinned');s.modify('folder',{id:first.id,folderId:a.id,pinning:false});s.modify('pin',{id:second.id,value:true});s.modify('folder',{ids:[first.id,second.id],folderId:b.id,pinning:false});assert.deepEqual(first.folderIds,[a.id,b.id]);assert.deepEqual(second.folderIds,[b.id]);assert.equal(first.pinned,false);assert.equal(second.pinned,true);assert.ok(first.retainedAt);s.modify('folder',{id:first.id,folderId:b.id});assert.equal(first.pinned,true);assert.deepEqual(first.folderIds,[a.id,b.id]);}));
test('pin-picker recents are bounded, success-only, atomic and pruned after removal without resetting old preferences',()=>fixture((s,_clock,directory)=>{const item=s.insert('text','MRU fixture'),folders=Array.from({length:10},(_,index)=>s.modify('createFolder',{name:'Folder '+index}));s.modify('setSettings',{patch:{language:'tr',autoCheckUpdates:false}});for(const folder of folders)s.modify('folder',{id:item.id,folderId:folder.id,rememberRecent:true});const expected=folders.slice(2).reverse().map(folder=>folder.id);assert.deepEqual(s.data.settings.recentPinFolderIds,expected);s.modify('folder',{id:item.id,folderId:folders[5].id,rememberRecent:true});assert.deepEqual(s.data.settings.recentPinFolderIds,[folders[5].id,...expected.filter(id=>id!==folders[5].id)]);const before=structuredClone(s.data);assert.throws(()=>s.modify('folder',{id:item.id,folderId:'00000000-0000-4000-8000-000000000099',rememberRecent:true}),/Folder unavailable/);assert.deepEqual(s.data,before);assert.throws(()=>s.modify('folder',{id:item.id,folderId:folders[0].id,rememberRecent:1}),/recent folder/);assert.deepEqual(s.data,before);const persist=s.persist;s.persist=()=>{throw new Error('Synthetic MRU persistence failure');};assert.throws(()=>s.modify('folder',{id:item.id,folderId:folders[0].id,rememberRecent:true}),/MRU persistence/);assert.deepEqual(s.data,before);s.persist=persist;s.modify('folder',{id:item.id,folderId:folders[0].id,pinning:false});assert.deepEqual(s.data.settings.recentPinFolderIds,before.settings.recentPinFolderIds);s.modify('removeFolder',{id:folders[5].id});assert.ok(!s.data.settings.recentPinFolderIds.includes(folders[5].id));const reopened=new Store(directory);assert.deepEqual(reopened.data.settings.recentPinFolderIds,s.data.settings.recentPinFolderIds);assert.equal(reopened.data.settings.language,'tr');assert.equal(reopened.data.settings.autoCheckUpdates,false);}));
test('recent folder preference validation rejects invalid or oversized IDs and sanitizes stale IDs on restore and load',()=>fixture((s,_clock,directory)=>{const existing=s.modify('createFolder',{name:'Kept'}),missing='00000000-0000-4000-8000-000000000099';s.modify('setSettings',{patch:{recentPinFolderIds:[missing,existing.id,existing.id]}});assert.deepEqual(s.data.settings.recentPinFolderIds,[existing.id]);for(const value of [[existing.id,...Array(8).fill(missing)],['../private'],null])assert.throws(()=>s.modify('setSettings',{patch:{recentPinFolderIds:value}}));s.data.settings.recentPinFolderIds=[missing,existing.id];s.persist();assert.deepEqual(new Store(directory).data.settings.recentPinFolderIds,[existing.id]);}));
test('settings merge nested retention and shortcut maps, rejecting prototype and filesystem injection',()=>fixture(s=>{s.modify('setSettings',{patch:{retentionDays:{text:7},localShortcuts:{pin:'O'}}});assert.equal(s.data.settings.retentionDays.image,30);assert.equal(s.data.settings.localShortcuts.pin,'O');assert.throws(()=>s.modify('setSettings',{patch:JSON.parse('{"localShortcuts":{"__proto__":"oops"}}')}));assert.throws(()=>s.modify('setSettings',{patch:{watchFolders:['../private']}}));}));

test('permanent deletion purges orphan managed rasters and refreshes both JSON snapshots',()=>fixture((s,_time,dir)=>{
  const item=s.insert('image',png),original=item.imageFile;
  const edited=Buffer.from(png);edited[edited.length-1]^=1;
  s.modify('saveImage',{id:item.id,dataUrl:'data:image/png;base64,'+edited.toString('base64')});const derivative=item.renderedFile;
  const superseded=Buffer.from(png);superseded[superseded.length-2]^=1;const orphan=s.putPNG(superseded);
  const external=path.join(dir,'original-image.png'),unmanaged=path.join(s.mediaDirectory,'original-image.png');fs.writeFileSync(external,png);fs.writeFileSync(unmanaged,png);
  const secret=s.insert('text','synthetic deleted private note');s.modify('trash',{ids:[item.id,secret.id]});s.modify('delete',{ids:[item.id,secret.id]});
  for(const filename of [original,derivative,orphan])assert.equal(fs.existsSync(path.join(s.mediaDirectory,filename)),false);
  assert.ok(fs.existsSync(external));assert.ok(fs.existsSync(unmanaged));
  for(const file of [s.file,s.file+'.backup']){const snapshot=JSON.parse(fs.readFileSync(file,'utf8'));assert.equal(snapshot.items.length,0);assert.ok(!fs.readFileSync(file,'utf8').includes(secret.text));}
  assert.equal(s.publicState().needsDeletionCleanup,false);
}));
test('permanent deletion keeps rasters referenced by live items or recoverable Trash',()=>fixture(s=>{
  const first=s.insert('image',png),file=path.join(s.mediaDirectory,first.imageFile);s.modify('trash',{ids:[first.id]});
  const second=s.insert('image',png);s.modify('delete',{ids:[first.id]});assert.ok(fs.existsSync(file));
  s.modify('trash',{ids:[second.id]});const third=s.insert('image',png);s.modify('trash',{ids:[third.id]});
  s.modify('delete',{ids:[second.id]});assert.ok(fs.existsSync(file));s.modify('restore',{ids:[third.id]});assert.deepEqual(fs.readFileSync(s.mediaPath(third.id)),png);
}));
test('ordinary removal and retention preserve managed images for undo and Trash recovery',()=>fixture((s,time)=>{
  const item=s.insert('image',png),file=s.mediaPath(item.id);s.modify('remove',{ids:[item.id]});assert.ok(fs.existsSync(file));s.modify('undo');assert.equal(item.trashedAt,null);
  time(32*86400000);s.expire();assert.ok(item.trashedAt);assert.ok(fs.existsSync(file));s.modify('restore',{ids:[item.id]});assert.ok(fs.existsSync(s.mediaPath(item.id)));
}));
test('a failed deletion commit preserves records and managed images',()=>fixture(s=>{
  const item=s.insert('image',png),file=s.mediaPath(item.id);s.modify('trash',{ids:[item.id]});const rename=fs.renameSync;
  try{fs.renameSync=(source,destination)=>{if(destination===s.file)throw Object.assign(new Error('synthetic unavailable volume'),{code:'EIO'});return rename(source,destination);};assert.throws(()=>s.modify('delete',{ids:[item.id]}),/synthetic unavailable volume/);}finally{fs.renameSync=rename;}
  assert.ok(s.item(item.id).trashedAt);assert.ok(fs.existsSync(file));assert.ok(JSON.parse(fs.readFileSync(s.file,'utf8')).items.some(record=>record.id===item.id));assert.equal(s.publicState().needsDeletionCleanup,false);
}));
test('backup cleanup failure is explicit and recoverable after the deletion commits',()=>fixture(s=>{
  const item=s.insert('image',png),file=s.mediaPath(item.id);s.modify('trash',{ids:[item.id]});const rename=fs.renameSync;
  try{fs.renameSync=(source,destination)=>{if(destination===s.file+'.backup'&&source.includes('.backup.tmp-'))throw Object.assign(new Error('synthetic backup denial'),{code:'EACCES'});return rename(source,destination);};assert.throws(()=>s.modify('delete',{ids:[item.id]}),error=>error.committed&&/incomplete/.test(error.message));}finally{fs.renameSync=rename;}
  assert.equal(s.data.items.length,0);assert.ok(fs.existsSync(file));assert.equal(s.publicState().needsDeletionCleanup,true);assert.match(s.privacyWarning,/Retry cleanup/);
  assert.equal(JSON.parse(fs.readFileSync(s.file,'utf8')).pendingBackupRefresh,true);
  s.modify('cleanup');assert.equal(s.publicState().needsDeletionCleanup,false);assert.equal(s.privacyWarning,'');assert.equal(fs.existsSync(file),false);assert.equal(JSON.parse(fs.readFileSync(s.file+'.backup','utf8')).items.length,0);
}));
test('image unlink failure remains pending and retries safely on next startup',()=>fixture((s,_time,dir)=>{
  const item=s.insert('image',png),file=s.mediaPath(item.id);s.modify('trash',{ids:[item.id]});const unlink=fs.unlinkSync;
  try{fs.unlinkSync=destination=>{if(destination===file)throw Object.assign(new Error('synthetic file in use'),{code:'EACCES'});return unlink(destination);};assert.throws(()=>s.modify('delete',{ids:[item.id]}),error=>error.committed&&/incomplete/.test(error.message));}finally{fs.unlinkSync=unlink;}
  assert.equal(s.data.items.length,0);assert.equal(s.publicState().needsDeletionCleanup,true);assert.ok(fs.existsSync(file));assert.equal(JSON.parse(fs.readFileSync(s.file+'.backup','utf8')).items.length,0);
  const reloaded=new Store(dir);assert.equal(reloaded.data.items.length,0);assert.equal(reloaded.publicState().needsDeletionCleanup,false);assert.equal(fs.existsSync(file),false);
}));
test('final cleanup-state write failure cannot resurrect records or removed rasters',()=>fixture(s=>{
  const item=s.insert('image',png),file=s.mediaPath(item.id);s.modify('trash',{ids:[item.id]});const rename=fs.renameSync;let commits=0;
  try{fs.renameSync=(source,destination)=>{if(destination===s.file&&++commits===2)throw Object.assign(new Error('synthetic final commit failure'),{code:'EIO'});return rename(source,destination);};assert.throws(()=>s.modify('delete',{ids:[item.id]}),error=>error.committed&&/incomplete/.test(error.message));}finally{fs.renameSync=rename;}
  assert.equal(s.data.items.length,0);assert.equal(fs.existsSync(file),false);assert.equal(s.publicState().needsDeletionCleanup,true);assert.equal(JSON.parse(fs.readFileSync(s.file,'utf8')).items.length,0);
  s.modify('cleanup');assert.equal(s.publicState().needsDeletionCleanup,false);assert.equal(JSON.parse(fs.readFileSync(s.file+'.backup','utf8')).items.length,0);
}));
test('unpinning or removing organization never expires a previously saved item',()=>fixture((s,time,dir)=>{
 const item=s.insert('text','Saved once');time(2000);s.modify('pin',{id:item.id,value:true});const retained=item.retainedAt;
 s.modify('pin',{id:item.id,value:false});s.modify('tag',{id:item.id,tags:['keep']});s.modify('removeTag',{id:item.id,tag:'keep'});
 const folder=s.modify('createFolder',{name:'Temporary folder'});s.modify('folder',{id:item.id,folderId:folder.id});s.modify('unassign',{id:item.id,folderId:folder.id});s.modify('pin',{id:item.id,value:false});
 time(4000*86400000);s.expire();assert.equal(item.trashedAt,null);assert.equal(item.retainedAt,retained);
 const restored=new Store(dir);assert.equal(restored.item(item.id).retainedAt,retained);assert.equal(restored.item(item.id).pinned,false);
 s.modify('remove',{id:item.id});assert.equal(item.hiddenFromShelf,true);assert.equal(item.trashedAt,null);
}));
test('retaining and inspector details save without pinning and preserve content and organization on recopy',()=>fixture((s,time)=>{
 const item=s.insert('text','Exact value');s.modify('retain',{id:item.id});time(2000);s.modify('details',{id:item.id,name:'Friendly name',note:'Searchable note',text:'Exact value'});
 assert.equal(item.pinned,false);assert.equal(item.retainedAt,1000);assert.equal(item.name,'Friendly name');assert.equal(item.note,'Searchable note');
 time(3000);assert.equal(s.insert('text','Exact value').id,item.id);assert.equal(item.note,'Searchable note');assert.equal(item.name,'Friendly name');assert.equal(item.retainedAt,1000);
 const image=s.insert('image',png);assert.throws(()=>s.modify('details',{ids:[item.id,image.id],name:'Must roll back',text:'Invalid mixed edit'}));assert.equal(s.item(item.id).name,'Friendly name');
}));
test('old pinned and organized records migrate to sticky Saved without changing original dates',()=>fixture((s,time,dir)=>{
 const item=s.insert('text','Legacy saved');s.modify('pin',{id:item.id});delete item.retainedAt;s.persist();time(9000);
 const restored=new Store(dir,{clock:()=>9000}),value=restored.item(item.id);assert.equal(value.retainedAt,1000);assert.equal(value.createdAt,1000);assert.equal(value.updatedAt,1000);
 restored.modify('pin',{id:item.id,value:false});assert.equal(restored.item(item.id).retainedAt,1000);
}));
test('successful copy timestamps do not alter edited or captured dates and failed persistence rolls back',()=>fixture((s,time)=>{
 const item=s.insert('text','Copy metadata');time(5000);s.markCopied([item.id]);assert.equal(item.lastCopiedAt,5000);assert.equal(item.createdAt,1000);assert.equal(item.updatedAt,1000);
 time(6000);const persist=s.persist;s.persist=()=>{throw new Error('Synthetic disk failure');};try{assert.throws(()=>s.markCopied([item.id]),/Synthetic disk failure/);}finally{s.persist=persist;}
 assert.equal(s.item(item.id).lastCopiedAt,5000);
}));
test('shortcut reset removes override while Off remains an explicit disabled binding',()=>fixture(s=>{
 s.modify('setSettings',{patch:{localShortcuts:{down:'X'}}});s.modify('setSettings',{patch:{localShortcuts:{down:''}}});assert.equal(s.data.settings.localShortcuts.down,'');
 s.modify('setSettings',{patch:{localShortcuts:{down:null}}});assert.equal(Object.hasOwn(s.data.settings.localShortcuts,'down'),false);
}));
test('fresh defaults match Mac link capture and system language while existing opt-outs remain respected',()=>fixture((s,_time,dir)=>{
 assert.equal(s.data.settings.captureLinks,true);assert.equal(s.data.settings.fetchLinkMetadata,true);assert.equal(s.data.settings.language,'system');
 s.modify('setSettings',{patch:{captureLinks:false,fetchLinkMetadata:false,language:'ja',libraryListMode:true,librarySidebarVisible:false,libraryInspectorVisible:false,librarySidebarWidth:310,libraryInspectorWidth:390}});
 const restored=new Store(dir);for(const key of ['captureLinks','fetchLinkMetadata','librarySidebarVisible','libraryInspectorVisible'])assert.equal(restored.data.settings[key],false);assert.equal(restored.data.settings.language,'ja');assert.equal(restored.data.settings.librarySidebarWidth,310);
 assert.throws(()=>s.modify('setSettings',{patch:{librarySidebarWidth:2000}}));assert.throws(()=>s.modify('setSettings',{patch:{language:'unsupported'}}));
}));
test('Library column preferences persist partial updates and reject unknown or unsafe sizes atomically',()=>fixture((s,_time,dir)=>{
 s.modify('setSettings',{patch:{libraryListColumns:{title:500}}});assert.equal(s.data.settings.libraryListColumns.title,500);assert.equal(s.data.settings.libraryListColumns.tags,150);
 assert.throws(()=>s.modify('setSettings',{patch:{libraryListColumns:{title:600,tags:1}}}));assert.equal(s.data.settings.libraryListColumns.title,500);
 assert.throws(()=>s.modify('setSettings',{patch:{libraryListColumns:{unknown:150}}}));assert.throws(()=>s.modify('setSettings',{patch:{libraryListColumns:[]}}));assert.equal(new Store(dir).data.settings.libraryListColumns.title,500);
}));

test('fresh global defaults match Mac while old toggle choices and optional-off preferences survive reload',()=>fixture((s,_time,dir)=>{
 assert.equal(s.data.settings.shortcuts.toggle,'Control+Alt+T');assert.equal(s.data.settings.shortcuts.search,'Control+Alt+S');assert.equal(s.data.settings.shortcuts.library,'');assert.equal(s.data.settings.shortcuts.copyLatest,'');
 s.modify('setSettings',{patch:{shortcuts:{toggle:'Control+Alt+Space',library:'Control+Alt+L',copyLatest:'Control+Alt+C'}}});
 const old=JSON.parse(fs.readFileSync(s.file,'utf8'));delete old.settings.shortcuts.library;delete old.settings.shortcuts.copyLatest;fs.writeFileSync(s.file,JSON.stringify(old));
 const restored=new Store(dir);assert.equal(restored.data.settings.shortcuts.toggle,'Control+Alt+Space');assert.equal(restored.data.settings.shortcuts.library,'');assert.equal(restored.data.settings.shortcuts.copyLatest,'');
 restored.modify('setSettings',{patch:{shortcuts:{library:'Control+Alt+L',copyLatest:'Control+Alt+C'}}});assert.equal(new Store(dir).data.settings.shortcuts.library,'Control+Alt+L');restored.modify('setSettings',{patch:{shortcuts:{library:'',copyLatest:''}}});assert.equal(new Store(dir).data.settings.shortcuts.copyLatest,'');assert.throws(()=>restored.modify('setSettings',{patch:{shortcuts:{unknown:'Control+Alt+U'}}}),/Invalid shortcut/);
}));
