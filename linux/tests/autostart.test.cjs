'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {setLaunchAtLogin,quote}=require('../../windows/lib/linux-autostart.cjs');
function directory(t){const root=fs.mkdtempSync(path.join(os.tmpdir(),'clipboardline-autostart-'));t.after(()=>fs.rmSync(root,{recursive:true,force:true}));return root;}
test('XDG autostart supports paths with spaces, literal field codes, and reversible opt-out',t=>{
 const configHome=directory(t),options={configHome,executable:'/opt/Clipboard Line/App%Image',args:['/opt/Library $test/clip`board".cjs']};
 setLaunchAtLogin(true,options);const file=path.join(configHome,'autostart/clipboardline.desktop'),value=fs.readFileSync(file,'utf8');
 assert.equal(value.split('\n').find(line=>line.startsWith('Exec=')),String.raw`Exec="/opt/Clipboard Line/App%%Image" "/opt/Library \\$test/clip\\`+'`'+String.raw`board\\".cjs"`);
 assert.ok(value.includes('X-ClipBoardLine-Autostart=true'));assert.equal(fs.statSync(file).mode&0o777,0o600);
 setLaunchAtLogin(true,options);setLaunchAtLogin(false,options);assert.equal(fs.existsSync(file),false);
 setLaunchAtLogin(false,options);
 for(const value of ['bad\npath','bad\rpath','bad\0path'])assert.throws(()=>quote(value));
});
test('autostart preserves foreign entries and never follows an existing symlink',t=>{
 const configHome=directory(t),options={configHome,executable:'/opt/clipboardline'},dir=path.join(configHome,'autostart');fs.mkdirSync(dir);
 const file=path.join(dir,'clipboardline.desktop'),original='[Desktop Entry]\nName=User entry\n';fs.writeFileSync(file,original);
 for(const enabled of [true,false])assert.throws(()=>setLaunchAtLogin(enabled,options),/not owned/);
 assert.equal(fs.readFileSync(file,'utf8'),original);fs.unlinkSync(file);
 const target=path.join(configHome,'original');fs.writeFileSync(target,original);fs.symlinkSync(target,file);
 assert.throws(()=>setLaunchAtLogin(true,options),/not owned/);assert.equal(fs.readFileSync(target,'utf8'),original);
});
test('Linux Store secures existing application and media directories',t=>{
 const {Store}=require('../../windows/lib/model.cjs'),root=directory(t);fs.chmodSync(root,0o755);fs.mkdirSync(path.join(root,'media'),{mode:0o755});
 const store=new Store(root);store.insert('text','Synthetic permission test');
 assert.equal(fs.statSync(root).mode&0o777,0o700);assert.equal(fs.statSync(store.mediaDirectory).mode&0o777,0o700);
});
