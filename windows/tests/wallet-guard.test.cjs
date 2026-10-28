'use strict';
// Wallet Guard: the shared contract executed against the shipped Windows
// module, Store settings and renderer. Every value is a public test vector or
// synthetic data that holds no funds.
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),crypto=require('node:crypto');
const {WalletGuard,classify,walletGuardMessage,messageSummary,LIMITS,keccak256}=require('../lib/wallet-guard.cjs');
const WORDS=require('../lib/bip39-english.cjs');
const {Store}=require('../lib/model.cjs');
const {translated}=require('../lib/status-summary.cjs');
const {readClipboardContent}=require('../lib/clipboard-policy.cjs');
const {plainURL}=require('../lib/model.cjs');
const contract=require('../../contracts/wallet-guard.json');

function matches(result,expect){
  if(result.kind!==expect.kind)return false;
  if(expect.kind==='secret')return result.secret===expect.secret&&result.format===expect.format;
  if(expect.kind==='address')return result.chain===expect.chain;
  return true;
}

test('bundled BIP39 English wordlist is the unmodified 2048-word list',()=>{
  assert.equal(WORDS.length,contract.wordlist.count);
  assert.equal(new Set(WORDS).size,2048);
  assert.equal(crypto.createHash('sha256').update(WORDS.join('\n')+'\n').digest('hex'),contract.wordlist.sha256OfNewlineTerminatedList);
});
test('module limits are the shared contract limits',()=>{
  assert.deepEqual({...LIMITS},contract.limits);
  assert.deepEqual(new Store(fs.mkdtempSync(path.join(os.tmpdir(),'clipboardline-wallet-defaults-'))).data.settings.walletGuard,contract.setting.default);
});
test('Keccak-256 matches published digests used by EIP-55',()=>{
  assert.equal(keccak256(Buffer.alloc(0)).toString('hex'),'c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470');
  assert.equal(keccak256(Buffer.from('abc')).toString('hex'),'4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45');
  assert.equal(keccak256(Buffer.alloc(136,0x61)).length,32);
});
for(const group of ['secret','address','none']){
  const rows=contract.classify.filter(row=>row.expect.kind===group);
  test(`shared classification vectors: ${group} (${rows.length})`,()=>{
    for(const row of rows)assert.ok(matches(classify(row.value),row.expect),row.name+' -> '+JSON.stringify(classify(row.value)));
  });
}
for(const scenario of contract.scenarios){
  test('shared scenario: '+scenario.name,()=>{
    let now=0;const guard=new WalletGuard({clock:()=>now});
    for(const [index,step] of scenario.steps.entries()){
      now=step.atMs;
      const verdict=guard.inspect(step.text,{enabled:scenario.enabled,context:step.context,history:scenario.history});
      assert.deepEqual(verdict,step.expect,scenario.name+' step '+index);
    }
  });
}
test('classification is bounded: oversized copies are not inspected and a dense wordlist note stays fast',()=>{
  const mnemonic=contract.classify[0].value;
  assert.equal(classify(mnemonic+' '.repeat(LIMITS.maximumInspectedCharacters)).kind,'none');
  const dense=Array.from({length:400},(_,index)=>WORDS.slice(index%2000,index%2000+40).join(' ')).join(' x ').slice(0,LIMITS.maximumInspectedCharacters);
  const started=process.hrtime.bigint();classify(dense);
  assert.ok(Number(process.hrtime.bigint()-started)/1e6<500,'dense note classification stays under 500 ms');
  for(const value of [null,undefined,42,{},[]])assert.equal(classify(value).kind,'none');
});
test('only public addresses are retained, and only in a bounded session list',()=>{
  let now=0;const guard=new WalletGuard({clock:()=>now});
  for(const row of contract.classify.filter(value=>value.expect.kind==='secret')){now+=10000;guard.inspect(row.value,{history:[]});}
  assert.equal(guard.last,null);assert.deepEqual(guard.session,[]);
  for(let index=0;index<LIMITS.sessionAddresses+8;index++){now+=10000;guard.inspect('0x'+index.toString(16).padStart(40,'0'),{history:[]});}
  assert.equal(guard.session.length,LIMITS.sessionAddresses);
  assert.ok(guard.session.every(item=>Object.keys(item).sort().join()==='chain,value'));
  guard.inspect(contract.classify[0].value,{enabled:false});assert.equal(guard.session.length,0,'disabling forgets compared addresses');
});
test('history comparison uses only recent text and ignores malformed rows',()=>{
  const lookalike=contract.scenarios.find(value=>value.name.startsWith('a lookalike of a history address'));
  const [address]=lookalike.steps,similar=lookalike.history[1];
  const old=[...Array(LIMITS.historyAddresses).fill('synthetic note'),similar];
  assert.equal(new WalletGuard().inspect(address.text,{history:old}).alert,null,'entries beyond the history limit are not compared');
  assert.equal(new WalletGuard().inspect(address.text,{history:[null,42,'x'.repeat(10000),similar]}).alert.similar,similar);
});
test('secrets are withheld before the Store while text capture is on, and the setting persists',async()=>{
  const directory=fs.mkdtempSync(path.join(os.tmpdir(),'clipboardline-wallet-guard-'));
  try{
    const store=new Store(directory);store.modify('setSettings',{patch:{captureText:true}});
    const guard=new WalletGuard();let saved=0;
    for(const row of contract.classify){
      const board={types:['text/plain'],getType:async()=>new Blob([row.value])};
      const content=await readClipboardContent({clipboard:{read:async()=>[board]},sequence:async()=>1,marker:Buffer.from('synthetic-marker'),plainURL});
      if(!content)continue;
      const verdict=guard.inspect(content.value,{enabled:store.data.settings.walletGuard,history:[]});
      if(verdict.save){store.insert(content.kind,content.value);saved++;}
    }
    const persisted=fs.readdirSync(directory).filter(name=>name.endsWith('.json')).map(name=>fs.readFileSync(path.join(directory,name),'utf8')).join('\n');
    for(const row of contract.classify.filter(value=>value.expect.kind==='secret'))
      assert.equal(persisted.includes(JSON.stringify(row.value.trim()).slice(1,-1)),false,row.name);
    assert.ok(saved>0&&store.data.items.length>0);
    store.modify('setSettings',{patch:{walletGuard:false}});assert.equal(new Store(directory).data.settings.walletGuard,false);
    assert.throws(()=>store.modify('setSettings',{patch:{walletGuard:'yes'}}),/Invalid preference/);
  }finally{fs.rmSync(directory,{recursive:true,force:true});}
});
test('messages use the shared catalogs in English and Turkish and keep both addresses',()=>{
  const hijack={save:true,notice:null,alert:{type:'hijack',original:'0xORIGINAL',replacement:'0xREPLACEMENT'}};
  const english=walletGuardMessage(hijack,key=>translated('en',key));
  assert.equal(english.body,'Your copied address was replaced by another address. This is how clipboard malware steals crypto.');
  assert.deepEqual(english.rows.map(row=>row.value),['0xORIGINAL','0xREPLACEMENT']);assert.equal(english.persistent,true);
  const turkish=walletGuardMessage(hijack,key=>translated('tr',key));
  assert.equal(turkish.title,'Kopyalanan adres değiştirildi');assert.match(messageSummary(turkish),/Kopyaladığınız: 0xORIGINAL\nPanodaki şu an: 0xREPLACEMENT/);
  for(const [notice,english] of Object.entries(contract.notices)){
    const message=walletGuardMessage({save:false,notice,alert:null},key=>translated('en',key));
    assert.equal(message.body,english);assert.equal(message.persistent,false);
    assert.notEqual(walletGuardMessage({save:false,notice,alert:null},key=>translated('tr',key)).body,english,'Turkish notice is translated');
  }
  const poisoning=walletGuardMessage({save:true,notice:null,alert:{type:'poisoning',address:'NEW',similar:'OLD'}},key=>translated('tr',key));
  assert.deepEqual(poisoning.rows.map(row=>row.value),['NEW','OLD']);
  assert.equal(walletGuardMessage({save:true,notice:null,alert:null}),null);
});
test('classification completes with network globals disabled',()=>{
  const saved={fetch:globalThis.fetch,WebSocket:globalThis.WebSocket};
  globalThis.fetch=()=>{throw new Error('network is not allowed');};globalThis.WebSocket=function(){throw new Error('network is not allowed');};
  try{for(const row of contract.classify)assert.ok(matches(classify(row.value),row.expect),row.name);}
  finally{Object.assign(globalThis,saved);}
});
