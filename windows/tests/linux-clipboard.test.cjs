'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const crypto=require('node:crypto');
const {LinuxClipboard,detectBackend,parseTypes,fileURIList,uriList,payload,MARKER_TYPE}=require('../lib/linux-clipboard.cjs');
const {readClipboardContent}=require('../lib/clipboard-policy.cjs');
const {plainURL}=require('../lib/model.cjs');

// A synthetic selection served through the same wl-paste/wl-copy argument
// shapes the Linux bridge uses. No real clipboard is touched.
function fakeWayland(offers={}){
 const calls=[];const state={offers:{...offers}};
 const run=async(file,args,options={})=>{
  calls.push({file,args,options});
  if(file==='wl-paste'&&args[0]==='--list-types')return Buffer.from(Object.keys(state.offers).join('\n')+'\n');
  if(file==='wl-paste'&&args[0]==='--no-newline'){const type=args[2];if(!(type in state.offers))throw new Error('wl-paste failed');return Buffer.from(state.offers[type]);}
  if(file==='wl-copy'){const type=args[1];state.offers=type.startsWith('text/plain')?{'text/plain;charset=utf-8':options.input,'text/plain':options.input,UTF8_STRING:options.input}:{[type]:options.input};return Buffer.alloc(0);}
  throw new Error('unexpected '+file);
 };
 const clipboard=new LinuxClipboard({backend:'wl-clipboard',run,find:name=>name});
 return{clipboard,calls,state};
}
const marker=crypto.randomBytes(16);
const content=clipboard=>readClipboardContent({clipboard,sequence:async()=>7,marker,plainURL});

test('Linux text aliases become one text/plain entry and links keep link semantics',async()=>{
 const {clipboard}=fakeWayland({'text/plain;charset=utf-8':'https://example.com/a',UTF8_STRING:'https://example.com/a',TIMESTAMP:'x'});
 const [entry]=await clipboard.read();
 assert.deepEqual(entry.types,['text/plain']);
 assert.equal((await content(clipboard)).kind,'link');
});
test('X11-only UTF8_STRING text is admitted while X11 selection metadata is hidden',async()=>{
 assert.deepEqual(parseTypes('TARGETS\nTIMESTAMP\nUTF8_STRING\nMULTIPLE\n\nUTF8_STRING\n'),['UTF8_STRING']);
 const {clipboard}=fakeWayland({UTF8_STRING:'plain words'});
 const result=await content(clipboard);assert.equal(result.kind,'text');assert.equal(result.value,'plain words');
});
test('KDE and password-manager private markers veto the whole Linux copy',async()=>{
 const {clipboard}=fakeWayland({'text/plain':'hunter2','x-kde-passwordManagerHint':'secret'});
 assert.ok((await clipboard.read())[0].types.includes('x-kde-passwordManagerHint'));
 assert.equal(await content(clipboard),null);
});
test('a clipboard-history replay is not a new copy',async()=>{
 const {clipboard}=fakeWayland({'text/plain':'old entry','application/x-kde-onlyReplaceEmpty':'1'});
 assert.deepEqual(await clipboard.read(),[]);assert.equal(await content(clipboard),null);
});
test('file-manager copies are ignored like a Windows FileDrop',async()=>{
 const gnome=fakeWayland({'text/plain':'/home/user/a.txt','x-special/gnome-copied-files':'copy\nfile:///home/user/a.txt'});
 assert.equal(await content(gnome.clipboard),null);
 const kde=fakeWayland({'text/uri-list':'file:///home/user/a%20b.png\r\n','text/plain':'file:///home/user/a b.png','image/png':'PNG'});
 assert.equal(await content(kde.clipboard),null);
 const web=fakeWayland({'text/uri-list':'https://example.com/\r\n','text/plain':'https://example.com/'});
 assert.equal((await content(web.clipboard)).kind,'link');
 assert.equal(fileURIList('# comment\nfile:///a\n'),true);assert.equal(fileURIList('file:///a\nhttps://b'),false);
});
test('a non-PNG image offer is converted once and admitted as image/png',async()=>{
 let conversions=0;const {clipboard}=fakeWayland({'image/jpeg':'JPEGDATA'});
 clipboard.configure({toPNG:bytes=>{conversions++;assert.equal(bytes.toString(),'JPEGDATA');return Buffer.from('converted-png');}});
 const result=await content(clipboard);assert.equal(result.kind,'image');assert.equal(result.value.toString(),'converted-png');assert.equal(conversions,1);
});
test('wl-copy is detached with an explicit type so text is never content-sniffed',async()=>{
 const {clipboard,calls}=fakeWayland();
 await clipboard.write({text:'<b>not html</b>',marker});
 const copy=calls.find(call=>call.file==='wl-copy');
 assert.deepEqual(copy.args,['--type','text/plain;charset=utf-8']);assert.equal(copy.options.detach,true);assert.equal(copy.options.input.toString(),'<b>not html</b>');
});
test('own writes carry the ownership marker until another application changes the selection',async()=>{
 const {clipboard,state}=fakeWayland();
 await clipboard.write({text:'from library',marker});
 assert.ok((await clipboard.read())[0].types.includes(MARKER_TYPE));
 assert.equal(await content(clipboard),null,'own copy must not be recaptured');
 clipboard.changed();// notification for this write
 assert.equal(await content(clipboard),null);
 clipboard.changed();// another application copied identical bytes
 state.offers={'text/plain':'from library'};
 assert.equal((await content(clipboard)).value,'from library');
});
test('payload priority keeps files as files and a single image over text',()=>{
 assert.equal(payload({files:['/tmp/a b.png'],text:'x',png:Buffer.from('89504e470d0a1a0a','hex')}).type,'text/uri-list');
 assert.equal(payload({files:['/tmp/a b.png']}).bytes.toString(),'file:///tmp/a%20b.png\r\n');
 assert.equal(payload({png:Buffer.from('89504e470d0a1a0a00','hex'),text:'caption'}).type,'image/png');
 assert.throws(()=>payload({png:Buffer.from('not a png')}),/Image unavailable/);
 assert.throws(()=>payload({}),/Select an item first/);
 assert.equal(uriList(['/a','/b']),'file:///a\r\nfile:///b\r\n');
});
test('backend detection prefers data-control on Wayland, then xclip, then Electron',()=>{
 const all=()=> '/usr/bin/tool',none=()=>null;
 assert.equal(detectBackend({environment:{WAYLAND_DISPLAY:'wayland-0',DISPLAY:':0'},find:all}),'wl-clipboard');
 assert.equal(detectBackend({environment:{DISPLAY:':0'},find:all}),'xclip');
 assert.equal(detectBackend({environment:{WAYLAND_DISPLAY:'wayland-0',DISPLAY:':0'},find:name=>name==='xclip'?'/usr/bin/xclip':null}),'xclip');
 assert.equal(detectBackend({environment:{DISPLAY:':0'},find:none}),'electron');
});
test('a failed Wayland watcher falls back to polling and reports the failure once',async()=>{
 const {EventEmitter}=require('node:events');
 const child=new EventEmitter();child.stdout=new EventEmitter();child.stderr=new EventEmitter();child.kill=()=>{};
 const electron={clipboard:{read:async()=>[]}};
 const clipboard=new LinuxClipboard({backend:'wl-clipboard',find:name=>name,electron,spawnWatcher:()=>child,pollInterval:5});
 const failures=[];clipboard.onFailure(error=>failures.push(error.message));
 const sequences=[];clipboard.onChange(value=>sequences.push(value));
 clipboard.start();child.stdout.emit('data',Buffer.from('\n\n'));
 assert.deepEqual(sequences,[2,3]);
 child.stderr.emit('data',Buffer.from('Watch mode requires a compositor that supports the wlroots data-control protocol\n'));child.emit('exit',1);
 assert.equal(clipboard.backend,'electron');assert.equal(failures.length,1);assert.match(failures[0],/data-control/);
 assert.ok(clipboard.poller);clipboard.stop();
});
test('stopping the clipboard ends the Wayland watcher and its exit hook',()=>{
 const {EventEmitter}=require('node:events');let killed=0;
 const child=new EventEmitter();child.stdout=new EventEmitter();child.stderr=new EventEmitter();child.kill=()=>{killed++;};
 const before=process.listenerCount('exit');
 const clipboard=new LinuxClipboard({backend:'wl-clipboard',find:name=>name,spawnWatcher:()=>child});
 clipboard.start();assert.equal(process.listenerCount('exit'),before+1);
 clipboard.stop();assert.equal(killed,1);assert.equal(process.listenerCount('exit'),before);assert.equal(clipboard.watcher,null);
});
