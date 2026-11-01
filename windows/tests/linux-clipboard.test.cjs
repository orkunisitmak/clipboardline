'use strict';
// Linux desktop integration; the Linux CI runs it, and Windows hosts skip it.
const linuxOnly={skip:process.platform==='win32'&&'Linux desktop integration'};
const test=(name,options,body)=>typeof options==='function'?require('node:test').test(name,linuxOnly,options):require('node:test').test(name,{...options,...linuxOnly},body);
const assert=require('node:assert/strict'),crypto=require('node:crypto');
const {EventEmitter}=require('node:events');
const {WaylandClipboard,X11Clipboard,WaylandWatchers,PollingSequence,clipboardSignature,pixelFingerprint,keptCopy,writeClipboard,fileClipboard,readProcess,copyProcess,FORMAT_MAP,MARKER_TYPE}=require('../lib/linux-clipboard.cjs');
const {readClipboardContent}=require('../lib/clipboard-policy.cjs');
const {plainURL}=require('../lib/model.cjs');

function fakeChild(){
  const child=new EventEmitter();child.stdout=new EventEmitter();child.stderr=new EventEmitter();child.killed=false;
  child.stdin={written:[],on(){},end(value){child.stdin.written.push(value);}};child.kill=()=>{child.killed=true;};return child;
}
// A synthetic wl-paste: the clipboard is a map of MIME type to bytes.
function wlPaste(offer){
  const calls=[];
  const run=async(file,args,options)=>{
    calls.push({file,args,limit:options.limit});
    if(args[0]==='--list-types'){if(!offer)throw Object.assign(new Error('Nothing is copied'),{empty:true});return Buffer.from(Object.keys(offer).join('\n')+'\n');}
    const type=args[args.indexOf('--type')+1];if(!offer||!Object.hasOwn(offer,type))throw new Error('No suitable type');
    const bytes=Buffer.from(offer[type]);return bytes.length>options.limit?bytes.subarray(0,options.limit+1):bytes;
  };
  return{run,calls};
}
const marker=crypto.randomBytes(16),sequence=async()=>7;
const admit=clipboard=>readClipboardContent({clipboard,sequence,marker,plainURL});

test('readProcess keeps at most limit+1 bytes, reports empty clipboards and enforces its deadline',async()=>{
  let child;const spawner=()=>(child=fakeChild());
  const small=readProcess('wl-paste',[],{spawner,limit:10});child.stdout.emit('data',Buffer.from('hello'));child.emit('close',0);assert.equal((await small).toString(),'hello');
  const large=readProcess('wl-paste',[],{spawner,limit:4});child.stdout.emit('data',Buffer.from('0123456789'));assert.equal((await large).toString(),'01234');assert.equal(child.killed,true);
  const empty=readProcess('wl-paste',[],{spawner});child.stderr.emit('data',Buffer.from('Nothing is copied\n'));child.emit('close',1);await assert.rejects(empty,error=>error.empty===true);
  for(const message of ['xclip: Error: There is no owner for the CLIPBOARD selection','Error: target TARGETS not available',"xclip: Error: 'Chromium clipboard' (0x200000) cannot convert CLIPBOARD selection to target 'image/png'"]){const missing=readProcess('xclip',[],{spawner});child.stderr.emit('data',Buffer.from(message+'\n'));child.emit('close',1);await assert.rejects(missing,error=>error.empty===true,message);}
  const slow=readProcess('wl-paste',[],{spawner,timeout:5});await assert.rejects(slow,/timed out/);assert.equal(child.killed,true);
  const written=readProcess('wl-copy',[],{spawner,input:Buffer.from('in')});child.emit('close',0);await written;assert.deepEqual(child.stdin.written.map(String),['in']);
});
test('wl-copy runs without inherited output pipes and resolves when the foreground process exits',async()=>{
  let child,options;const spawner=(_file,_args,value)=>{options=value;return child=fakeChild();};
  const copied=copyProcess('wl-copy',['--type','text/plain'],{spawner,input:Buffer.from('x')});assert.deepEqual(options.stdio,['pipe','ignore','ignore']);
  child.emit('exit',0);await copied;assert.equal(child.stdin.written[0].toString(),'x');
  const failed=copyProcess('wl-copy',[],{spawner,input:Buffer.alloc(0)});child.emit('exit',1);await assert.rejects(failed,/could not set/);
});
test('wl-paste text is admitted through the shared policy without a trailing newline',async()=>{
  const fake=wlPaste({'text/plain;charset=utf-8':'synthetic note','UTF8_STRING':'synthetic note','TEXT':'synthetic note'});
  const content=await admit(new WaylandClipboard({wlPaste:'/usr/bin/wl-paste',run:fake.run}));
  assert.equal(content.kind,'text');assert.equal(content.value,'synthetic note');
  const read=fake.calls.find(call=>call.args.includes('--type'));assert.deepEqual(read.args,['--no-newline','--type','text/plain;charset=utf-8']);assert.equal(read.limit,1024*1024);
  const link=await admit(new WaylandClipboard({wlPaste:'wl-paste',run:wlPaste({'text/plain':'https://example.com/a'}).run}));assert.equal(link.kind,'link');
});
test('password-manager and concealed markers reach the shared private-clipboard policy',async()=>{
  for(const type of ['x-kde-passwordManagerHint','application/x-kde-passwordManagerHint','org.nspasteboard.ConcealedType']){
    const fake=wlPaste({'text/plain;charset=utf-8':'synthetic secret',[type]:'secret'});
    assert.equal(await admit(new WaylandClipboard({wlPaste:'wl-paste',run:fake.run})),null,type);
    assert.equal(fake.calls.some(call=>call.args.includes('text/plain;charset=utf-8')),false,'private text is never read');
  }
});
test('the ClipBoardLine marker is recovered from Chromium custom formats so own copies are skipped',async()=>{
  const format='application/web;type="custom/format1"',map=JSON.stringify({'application/x.clipboardline':'custom/format1'});
  const own=wlPaste({'text/plain':'copied by ClipBoardLine',[FORMAT_MAP]:map,[format]:marker});
  const clipboard=new WaylandClipboard({wlPaste:'wl-paste',run:own.run}),[entry]=await clipboard.read();
  assert.ok(entry.types.includes(MARKER_TYPE));assert.equal(await admit(clipboard),null);
  const foreign=wlPaste({'text/plain':'copied by another Chromium app',[FORMAT_MAP]:map,[format]:crypto.randomBytes(16)});
  assert.equal((await admit(new WaylandClipboard({wlPaste:'wl-paste',run:foreign.run}))).value,'copied by another Chromium app');
  const malformed=wlPaste({'text/plain':'unrelated map',[FORMAT_MAP]:'{"application/x.clipboardline":"custom/format9"}'});
  assert.equal((await new WaylandClipboard({wlPaste:'wl-paste',run:malformed.run}).read())[0].types.includes(MARKER_TYPE),false);
});
test('images are read with the image bound and empty clipboards produce no entry',async()=>{
  const png=Buffer.from('89504e470d0a1a0a0000','hex'),fake=wlPaste({'image/png':png,'text/html':'<img>'});
  const content=await admit(new WaylandClipboard({wlPaste:'wl-paste',run:fake.run}));assert.equal(content.kind,'image');assert.deepEqual(content.value,png);
  assert.equal(fake.calls.find(call=>call.args.includes('image/png')).limit,64*1024*1024);
  assert.deepEqual(await new WaylandClipboard({wlPaste:'wl-paste',run:wlPaste(null).run}).read(),[]);
  assert.equal(await admit(new WaylandClipboard({wlPaste:'wl-paste',run:wlPaste(null).run})),null);
});
test('watchers run only for wanted kinds and report changes, removal and unsupported compositors',()=>{
  const children=[],changes=[],failures=[];
  const watchers=new WaylandWatchers({wlPaste:'wl-paste',spawner:(file,args)=>{const child=fakeChild();child.args=args;children.push(child);return child;},changed:kind=>changes.push(kind),failed:error=>failures.push(error)});
  watchers.update({text:true,images:false});assert.deepEqual(children.map(child=>child.args),[['--watch','echo','clipboardline-change']]);
  watchers.update({text:true,images:true});assert.deepEqual(children[1].args,['--type','image/png','--watch','echo','clipboardline-change']);
  children[0].stdout.emit('data',Buffer.from('clipboardline-change\nclipboardline-'));children[0].stdout.emit('data',Buffer.from('change\nunrelated\n'));children[1].stdout.emit('data',Buffer.from('clipboardline-change\n'));
  assert.deepEqual(changes,['text','text','image']);
  watchers.update({text:true,images:false});assert.equal(children[1].killed,true);children[1].emit('exit',null);assert.equal(failures.length,0);
  children[0].stderr.emit('data',Buffer.from('Watch mode requires a compositor that supports the wlroots data-control protocol\n'));children[0].emit('exit',1);
  assert.equal(failures.length,1);assert.equal(failures[0].unsupported,true);
  watchers.kill();
});
test('X11 polling counts selection ownership changes and hashes images only when wanted',async()=>{
  const clipboard=(types,payload)=>({read:async()=>[{types,getType:async type=>new Blob([payload[type]])}]});
  const stamp='electron application/osclipboard;format="TIMESTAMP"';
  const a=await clipboardSignature(clipboard(['text/plain',stamp],{'text/plain':'same',[stamp]:Buffer.from([1,0,0,0])}));
  const b=await clipboardSignature(clipboard(['text/plain',stamp],{'text/plain':'same',[stamp]:Buffer.from([2,0,0,0])}));
  assert.notEqual(a,b,'a re-copy acquires a new selection timestamp');
  const png=value=>clipboard(['image/png'],{'image/png':value});
  assert.equal(await clipboardSignature(png('one')),await clipboardSignature(png('two')),'image payloads are not read when images are off');
  assert.notEqual(await clipboardSignature(png('one'),{images:true}),await clipboardSignature(png('two'),{images:true}));
  const values=['x','x','y','y','z'];let enabled=true;const observed=[];
  const poller=new PollingSequence({signature:async()=>values.shift(),enabled:()=>enabled,changed:value=>observed.push(value)});
  for(let index=0;index<4;index++)await poller.poll();
  enabled=false;await poller.poll();assert.equal(values.length,1,'disabled capture does not read the clipboard');
  assert.deepEqual(observed,[2,3],'the first observation is reported like a starting watcher');assert.equal(poller.value,3);
  enabled=true;assert.equal(await poller.poll(),4);
  // A stalled or failing read is bounded and the next readable state counts.
  const stalled=['never','a','a'];const slow=new PollingSequence({deadline:5,signature:()=>{const value=stalled.shift();return value==='never'?new Promise(()=>{}):Promise.resolve(value);}});
  assert.equal(await slow.poll(),1);assert.equal(slow.busy,false);assert.equal(await slow.poll(),2);assert.equal(await slow.poll(),2);
});
function pngBytes(width,height,payload=''){
  const header=Buffer.alloc(24);Buffer.from('89504e470d0a1a0a','hex').copy(header);header.writeUInt32BE(13,8);header.write('IHDR',12,'latin1');header.writeUInt32BE(width,16);header.writeUInt32BE(height,20);
  return Buffer.concat([header,Buffer.from(payload)]);
}
test('a screenshot re-served with different PNG bytes keeps its identity; other pixels do not',()=>{
  const decoded={'spectacle.png':{width:2,height:1,bitmap:Buffer.from([1,2,3,255,4,5,6,255])},'klipper.png':{width:2,height:1,bitmap:Buffer.from([1,2,3,255,4,5,6,255])},'other.png':{width:2,height:1,bitmap:Buffer.from([1,2,3,255,4,5,7,255])},'tall.png':{width:1,height:2,bitmap:Buffer.from([1,2,3,255,4,5,6,255])}};
  const decode=bytes=>decoded[bytes.subarray(24).toString()]??null,fingerprint=name=>pixelFingerprint(pngBytes(2,1,name),decode);
  assert.equal(fingerprint('spectacle.png'),fingerprint('klipper.png'));
  assert.notEqual(fingerprint('spectacle.png'),fingerprint('other.png'));
  assert.notEqual(fingerprint('spectacle.png'),fingerprint('tall.png'),'dimensions are part of the identity');
  assert.match(fingerprint('spectacle.png'),/^image:pixels:2x1:[0-9a-f]{64}$/);
  assert.equal(fingerprint('broken.png'),null,'undecodable bytes keep the byte fingerprint');
  assert.equal(pixelFingerprint(pngBytes(1,1),()=>{throw new Error('decoder failed');}),null);
});
test('a PNG declaring more pixels than a stored image may have is never decoded',()=>{
  let decoded=0;const decode=()=>{decoded++;return{width:1,height:1,bitmap:Buffer.from([1,2,3,255])};};
  assert.equal(pixelFingerprint(pngBytes(8945,8945),decode),null,'just above the limit');
  assert.equal(pixelFingerprint(pngBytes(100000,100000),decode),null);
  assert.equal(pixelFingerprint(pngBytes(0,10),decode),null,'an empty image');
  assert.equal(pixelFingerprint(Buffer.from('not a png'),decode),null,'a short offer');
  assert.equal(pixelFingerprint(Buffer.concat([Buffer.alloc(8),pngBytes(1,1).subarray(8)]),decode),null,'another format under the PNG type');
  assert.equal(decoded,0,'rejected offers never reach the decoder');
  assert.match(pixelFingerprint(pngBytes(8000,10000),decode),/^image:pixels:/,'the limit itself still decodes');
  assert.equal(decoded,1);
});
function electronClipboard(){const writes=[];return{writes,clipboard:{write:async items=>{writes.push(items);}},ClipboardItem:class{constructor(data){this.data=data;}}};}
test('X11 writes are atomic Electron writes with file-list formats for several items',async()=>{
  const fake=electronClipboard(),png=Buffer.from('png-bytes');
  const result=await writeClipboard({...fake,marker,text:'note',png,files:['/tmp/a b.png','/tmp/c.mp4']});
  assert.deepEqual(result,{method:'electron'});const data=fake.writes[0][0].data;
  assert.deepEqual(Object.keys(data).sort(),['electron application/osclipboard;format="text/uri-list"','electron application/osclipboard;format="x-special/gnome-copied-files"','image/png','text/plain',MARKER_TYPE].sort());
  assert.equal(await data['electron application/osclipboard;format="text/uri-list"'].text(),'file:///tmp/a%20b.png\r\nfile:///tmp/c.mp4\r\n');
  assert.equal(await data['electron application/osclipboard;format="x-special/gnome-copied-files"'].text(),'copy\nfile:///tmp/a%20b.png\nfile:///tmp/c.mp4');
  assert.deepEqual(fileClipboard(['/tmp/x#1.png']).uriList,'file:///tmp/x%231.png\r\n');
});
test('Wayland writes are verified and replaced by wl-copy when the compositor ignored them',async()=>{
  const delay=async()=>{};
  const format='application/web;type="custom/format0"',map=JSON.stringify({'application/x.clipboardline':'custom/format0'});
  const verified=electronClipboard(),copies=[];
  const ok=await writeClipboard({...verified,marker,text:'note',wayland:true,focused:true,wlCopy:'wl-copy',wlPaste:'wl-paste',delay,run:wlPaste({'text/plain':'note',[FORMAT_MAP]:map,[format]:marker}).run,copy:async(...value)=>copies.push(value)});
  assert.deepEqual(ok,{method:'electron'});assert.equal(verified.writes.length,1);assert.equal(copies.length,0);
  // Chromium re-encodes a copied image; the marker still proves the write landed.
  const reencoded=electronClipboard();
  assert.deepEqual(await writeClipboard({...reencoded,marker,png:Buffer.from('stored png'),wayland:true,focused:true,wlCopy:'wl-copy',wlPaste:'wl-paste',delay,run:wlPaste({'image/png':'chromium png',[FORMAT_MAP]:map,[format]:marker}).run,copy:async(...value)=>copies.push(value)}),{method:'electron'});
  assert.equal(copies.length,0,'no marker-less wl-copy replaces a landed image write');
  const ignored=electronClipboard();
  const fallback=await writeClipboard({...ignored,marker,text:'note',wayland:true,focused:true,wlCopy:'wl-copy',wlPaste:'wl-paste',delay,run:wlPaste({'text/plain':'note',[FORMAT_MAP]:map,[format]:crypto.randomBytes(16)}).run,copy:async(...value)=>copies.push(value)});
  assert.deepEqual(fallback,{method:'wl-copy',type:'text/plain;charset=utf-8'});assert.deepEqual(copies[0][1],['--type','text/plain;charset=utf-8']);assert.equal(copies[0][2].input.toString(),'note');
  const hidden=electronClipboard(),png=Buffer.from('png');copies.length=0;
  assert.deepEqual(await writeClipboard({...hidden,marker,png,wayland:true,focused:false,wlCopy:'wl-copy',wlPaste:'wl-paste',delay,copy:async(...value)=>copies.push(value)}),{method:'wl-copy',type:'image/png'});
  assert.equal(hidden.writes.length,0,'a hidden native Wayland client cannot own the selection');assert.deepEqual(copies[0][2].input,png);
  copies.length=0;await writeClipboard({...hidden,marker,png,files:['/tmp/a.png','/tmp/b.png'],wayland:true,focused:false,wlCopy:'wl-copy',wlPaste:'wl-paste',delay,copy:async(...value)=>copies.push(value)});
  assert.deepEqual(copies[0][1],['--type','text/uri-list']);
  await assert.rejects(writeClipboard({...hidden,marker,text:'x',wayland:true,focused:false,wlCopy:null,wlPaste:null,delay}),/Install wl-clipboard/);
  const unavailable=electronClipboard();
  assert.deepEqual(await writeClipboard({...unavailable,marker,text:'x',wayland:true,focused:true,wlCopy:'wl-copy',wlPaste:'wl-paste',delay,run:async()=>{throw new Error('no data-control');},copy:async()=>{throw new Error('no data-control');}}),{method:'electron'},'a focused Electron write is kept when wl-copy cannot help');
});
test('a TIMESTAMP the selection owner cannot serve falls back to the copied content',async()=>{
  let offer={UTF8_STRING:'first copy'};
  const run=async(_file,args)=>{
    const type=args[4];
    if(type==='TARGETS')return Buffer.from(['TARGETS','TIMESTAMP',...Object.keys(offer)].join('\n'));
    if(type==='TIMESTAMP')throw Object.assign(new Error('target TIMESTAMP not available'),{empty:true});
    return Buffer.from(offer[type]);
  };
  const clipboard=new X11Clipboard({xclip:'xclip',run});
  const first=await clipboardSignature(clipboard);
  assert.equal(await clipboardSignature(clipboard),first,'an unchanged Wayland copy is not a new copy');
  offer={UTF8_STRING:'second copy'};
  assert.notEqual(await clipboardSignature(clipboard),first,'a new Wayland copy is noticed');
  offer={'image/png':'png bytes'};
  assert.notEqual(await clipboardSignature(clipboard,{images:true}),first,'a new Wayland image is noticed');
});
test('the X11 change signature never reads a private copy and skips payloads a timestamp already identifies',async()=>{
  const reads=[];const clipboard=(types,payload)=>({read:async()=>[{types,getType:async type=>{reads.push(type);return new Blob([payload[type]||'']);}}]});
  const concealed=['text/plain','electron application/osclipboard;format="org.nspasteboard.ConcealedType"'];
  const one=await clipboardSignature(clipboard(concealed,{'text/plain':'hunter2'})),two=await clipboardSignature(clipboard(concealed,{'text/plain':'another secret'}));
  assert.deepEqual(reads,[],'a password manager copy is identified by its formats only');assert.equal(one,two);
  const stamp='electron application/osclipboard;format="TIMESTAMP"';
  await clipboardSignature(clipboard(['text/plain',stamp],{'text/plain':'note',[stamp]:Buffer.from([7,0,0,0])}));assert.deepEqual(reads,[stamp],'a timestamped copy is not read');
});
test('xclip reads the X11 selection in its own process with raw target names and the copy timestamp',async()=>{
  // A synthetic xclip: the selection is a map of target to bytes.
  let offer={TIMESTAMP:'42149757\n',TARGETS:'',UTF8_STRING:'X11 note','x-kde-passwordManagerHint':'secret'};const calls=[];
  const run=async(file,args,options)=>{calls.push({file,args,limit:options.limit});assert.deepEqual(args.slice(0,4),['-selection','clipboard','-o','-t']);const target=args[4];
    if(!offer)throw Object.assign(new Error('There is no owner for the CLIPBOARD selection'),{empty:true});
    if(target==='TARGETS')return Buffer.from(Object.keys(offer).join('\n')+'\n');if(!Object.hasOwn(offer,target))throw Object.assign(new Error('cannot convert'),{empty:true});return Buffer.from(offer[target]);};
  const clipboard=new X11Clipboard({xclip:'/usr/bin/xclip',run});
  assert.equal(await admit(clipboard),null,'a password manager hint keeps the copy private');
  delete offer['x-kde-passwordManagerHint'];
  const note=await admit(clipboard);assert.equal(note.kind,'text');assert.equal(note.value,'X11 note');
  assert.ok(calls.some(call=>call.file==='/usr/bin/xclip'&&call.args[4]==='UTF8_STRING'),'text is read from the UTF8_STRING target');
  calls.length=0;const first=await clipboardSignature(clipboard);assert.deepEqual(calls.map(call=>call.args[4]),['TARGETS','TIMESTAMP'],'a timestamped copy is identified without reading it');
  offer={...offer,TIMESTAMP:'42150000\n'};assert.notEqual(await clipboardSignature(clipboard),first,'a new copy has a new timestamp');
  offer=null;assert.deepEqual(await clipboard.read(),[]);assert.deepEqual(await clipboard.types(),[]);
});
test('only a captured image still on the shelf is served again after its app quits',()=>{
 const image={id:'a',kind:'image',value:Buffer.from('png'),fingerprint:'image:pixels:1'},shelf=[{id:'a',trashedAt:null,hiddenFromShelf:false}];
 assert.equal(keptCopy(image,{fingerprint:'image:pixels:1',items:shelf}),image);
 assert.equal(keptCopy(image,{fingerprint:'image:pixels:2',items:shelf}),null,'something else was copied since');
 assert.equal(keptCopy(image,{fingerprint:'image:pixels:1',items:[]}),null,'a deleted item is not served again');
 assert.equal(keptCopy(image,{fingerprint:'image:pixels:1',items:[{...shelf[0],trashedAt:1}]}),null,'a trashed item is not served again');
 assert.equal(keptCopy(image,{fingerprint:'image:pixels:1',items:[{...shelf[0],hiddenFromShelf:true}]}),null,'an item taken down from the shelf is not served again');
 for(const kind of ['text','link'])assert.equal(keptCopy({...image,kind},{fingerprint:'image:pixels:1',items:shelf}),null,kind+' is never served again, so a cleared password stays cleared');
 assert.equal(keptCopy(null,{fingerprint:'',items:shelf}),null);assert.equal(keptCopy({...image,fingerprint:''},{fingerprint:'',items:shelf}),null);
});
