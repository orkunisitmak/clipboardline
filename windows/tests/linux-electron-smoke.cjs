'use strict';
// Real Linux Electron acceptance through the system selection tools. Run it in
// an isolated display: `xvfb-run -a npm run test:linux` (X11 with xclip) or a
// nested `kwin_wayland --virtual` session with wl-clipboard.
const assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),os=require('node:os');
const {_electron:electron}=require('playwright');
const {LinuxClipboard}=require('../lib/linux-clipboard.cjs');
if(process.platform!=='linux')throw new Error('Linux Electron acceptance must run on Linux.');
const data=fs.mkdtempSync(path.join(os.tmpdir(),'clipboardline-linux-'));
const system=new LinuxClipboard();
const results=[];
function check(name){results.push(name);console.log('✔ '+name);}
async function until(read,accept,timeout=10000){const deadline=Date.now()+timeout;let value;while(Date.now()<deadline){value=await read();if(accept(value))return value;await new Promise(resolve=>setTimeout(resolve,100));}throw new Error('Timed out: '+JSON.stringify(value).slice(0,400));}
async function systemText(){const[entry]=await system.read();return entry?Buffer.from(await(await entry.getType('text/plain')).arrayBuffer()).toString('utf8'):'';}
async function main(){
  assert.ok(system.available,'wl-clipboard or xclip is required in the test display');
  const application=await electron.launch({args:[path.resolve(__dirname,'..'),'--test-mode','--test-data='+data],timeout:60000});
  try{
    const page=await application.firstWindow();await page.waitForFunction(()=>!!window.clipboardLine);
    await until(()=>application.evaluate(()=>!!global.__clipboardLineTest),Boolean);
    const initial=await page.evaluate(()=>window.clipboardLine.state());assert.equal(initial.platform,'linux');check('application starts and reports the Linux platform');
    await application.evaluate(()=>global.__clipboardLineTest.store.modify('setSettings',{patch:{captureText:true,captureImages:true,captureLinks:true}}));

    await system.writeText('Linux clipboard text acceptance');
    await until(()=>systemText(),value=>value==='Linux clipboard text acceptance');
    const text=await until(async()=>{await application.evaluate(()=>global.__clipboardLineTest.readClipboard());return(await page.evaluate(()=>window.clipboardLine.state())).items;},items=>items.some(item=>item.text==='Linux clipboard text acceptance'));
    check('system text copy is admitted through '+system.kind);

    await system.writeText('https://example.com/linux-acceptance');
    await until(async()=>{await application.evaluate(()=>global.__clipboardLineTest.readClipboard());return(await page.evaluate(()=>window.clipboardLine.state())).items;},items=>items.some(item=>item.kind==='link'&&item.url==='https://example.com/linux-acceptance'));
    check('copied URL becomes a link item');

    const id=text.find(item=>item.text==='Linux clipboard text acceptance').id;
    await application.evaluate(async(_electron,id)=>{const t=global.__clipboardLineTest;await t.writeClipboard(t.store.selected([id]));},id);
    assert.equal(await until(()=>systemText(),value=>value==='Linux clipboard text acceptance'),'Linux clipboard text acceptance');
    const count=(await page.evaluate(()=>window.clipboardLine.state())).items.length;
    await application.evaluate(()=>global.__clipboardLineTest.readClipboard());
    assert.equal((await page.evaluate(()=>window.clipboardLine.state())).items.length,count);
    check('application copy reaches the system clipboard and is not re-admitted');

    const png=await application.evaluate(({nativeImage})=>nativeImage.createFromBitmap(Buffer.alloc(8*8*4,200),{width:8,height:8}).toPNG().toString('base64'));
    await system.writePNG(Buffer.from(png,'base64'));
    await until(async()=>{await application.evaluate(()=>global.__clipboardLineTest.readClipboard());return(await page.evaluate(()=>window.clipboardLine.state())).items;},items=>items.some(item=>item.kind==='image'));
    check('system PNG copy becomes an image item');

    const native=await application.evaluate(()=>global.__clipboardLineTest.native.captureDiagnostics());
    assert.equal(native.platform,'linux');check(`desktop bridge reports ${native.session}/${native.compositor} (window: ${native.windowBackend||'compositor focus return'}, keys: ${native.keyBackend||'manual paste'})`);
  }finally{await application.close().catch(()=>{});fs.rmSync(data,{recursive:true,force:true});}
  // Desktop actions start the first instance in the requested view.
  const library=fs.mkdtempSync(path.join(os.tmpdir(),'clipboardline-linux-'));
  const launched=await electron.launch({args:[path.resolve(__dirname,'..'),'--test-mode','--test-data='+library,'--library'],timeout:60000});
  try{
    const page=await launched.firstWindow();await page.waitForFunction(()=>!!window.clipboardLine);
    await until(()=>page.evaluate(()=>window.clipboardLine.state()),value=>value.view==='library');
    check('a first launch with --library opens the Library');
  }finally{await launched.close().catch(()=>{});fs.rmSync(library,{recursive:true,force:true});}
  console.log(`${results.length} Linux acceptance checks passed.`);
}
main().catch(error=>{console.error(error);process.exit(1);});
