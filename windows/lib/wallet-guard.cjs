'use strict';
// Wallet Guard: local, network-free classification of copied text.
// Shared behavior and vectors: contracts/wallet-guard.json. The macOS
// counterpart is Sources/Tendedero/WalletGuard.swift.
const crypto=require('node:crypto');
const WORDS=require('./bip39-english.cjs');

const LIMITS=Object.freeze({maximumInspectedCharacters:16384,maximumMnemonicRunWords:48,hijackWindowMs:3000,
  lookalikePrefix:4,lookalikeSuffix:4,historyAddresses:200,sessionAddresses:32});
const WORD_INDEX=new Map(WORDS.map((word,index)=>[word,index]));
const MNEMONIC_LENGTHS=[24,21,18,15,12];
const BASE58='123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
const BASE58_VALUES=new Map([...BASE58].map((character,index)=>[character,BigInt(index)]));
const CURVE_ORDER=0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141n;
// BIP32 private serializations: xprv, tprv, yprv, zprv, uprv, vprv, Yprv, Zprv.
const EXTENDED_PRIVATE=new Set(['0488ade4','04358394','049d7878','04b2430c','044a4e28','045f18bc','0295b005','02aa7a99']);
const ED25519_PKCS8=Buffer.from('302e020100300506032b657004220420','hex');
const NONE=Object.freeze({kind:'none'});

const sha256=bytes=>crypto.createHash('sha256').update(bytes).digest();
function trimmed(text){return typeof text==='string'?text.replace(/^[\s\uFEFF]+|[\s\uFEFF]+$/gu,''):'';}

function base58(text){
  if(!text||text.length>160)return null;
  let value=0n;for(const character of text){const digit=BASE58_VALUES.get(character);if(digit===undefined)return null;value=value*58n+digit;}
  const body=[];while(value>0n){body.unshift(Number(value&0xffn));value>>=8n;}
  let zeros=0;while(text[zeros]==='1')zeros++;
  return Buffer.from([...new Array(zeros).fill(0),...body]);
}
function base58Check(text){
  const bytes=base58(text);if(!bytes||bytes.length<5)return null;
  const payload=bytes.subarray(0,-4);return sha256(sha256(payload)).subarray(0,4).equals(bytes.subarray(-4))?payload:null;
}
function validScalar(bytes){if(bytes.length!==32)return false;const value=BigInt('0x'+bytes.toString('hex'));return value>0n&&value<CURVE_ORDER;}

// BIP39: every 12-24 word window inside a bounded run of wordlist words, so a
// labelled backup note is caught while the checksum rejects arbitrary words.
function mnemonicTokens(text){
  const runs=[];let run=[];
  for(const raw of text.split(/[\s,;]+/u)){
    if(!raw)continue;
    const token=raw.toLowerCase().replace(/^#?\d{1,2}[.):-]*/u,'').replace(/^[("'[]+|[)"'\].:!?]+$/gu,'');
    if(!token)continue;// Backup layouts number the words; numbers are not words.
    if(WORD_INDEX.has(token))run.push(WORD_INDEX.get(token));else{if(run.length)runs.push(run);run=[];}
  }
  if(run.length)runs.push(run);return runs;
}
function validMnemonic(indices){
  const bits=indices.length*11,checksumBits=bits/33,entropyBits=bits-checksumBits;let value=0n;
  for(const index of indices)value=(value<<11n)|BigInt(index);
  const checksum=Number(value&((1n<<BigInt(checksumBits))-1n));
  const entropy=Buffer.from((value>>BigInt(checksumBits)).toString(16).padStart(entropyBits/4,'0'),'hex');
  return sha256(entropy)[0]>>(8-checksumBits)===checksum;
}
function containsMnemonic(text){
  for(const run of mnemonicTokens(text)){
    if(run.length<12||run.length>LIMITS.maximumMnemonicRunWords)continue;
    for(const length of MNEMONIC_LENGTHS)for(let start=0;start+length<=run.length;start++)if(validMnemonic(run.slice(start,start+length)))return true;
  }
  return false;
}

function solanaKeypair(bytes){
  if(bytes?.length!==64)return false;
  try{
    const key=crypto.createPrivateKey({key:Buffer.concat([ED25519_PKCS8,bytes.subarray(0,32)]),format:'der',type:'pkcs8'});
    return crypto.createPublicKey(key).export({format:'der',type:'spki'}).subarray(-32).equals(bytes.subarray(32));
  }catch{return false;}
}
function privateKeyFormat(value){
  const hex=/^(?:0x)?([0-9a-fA-F]{64})$/u.exec(value);
  if(hex)return validScalar(Buffer.from(hex[1],'hex'))?'hex':null;
  if(/^\[[\d\s,]+\]$/u.test(value)){
    const numbers=value.slice(1,-1).split(',').map(part=>part.trim());
    if(numbers.length!==64||!numbers.every(part=>/^\d{1,3}$/u.test(part)&&Number(part)<=255))return null;
    return solanaKeypair(Buffer.from(numbers.map(Number)))?'solanaKeypair':null;
  }
  if(!/^[1-9A-HJ-NP-Za-km-z]{50,115}$/u.test(value))return null;
  const payload=base58Check(value);
  if(payload){
    if((payload[0]===0x80||payload[0]===0xef)&&(payload.length===33||(payload.length===34&&payload[33]===1))&&validScalar(payload.subarray(1,33)))return 'wif';
    if(payload.length===78&&EXTENDED_PRIVATE.has(payload.subarray(0,4).toString('hex'))&&payload[45]===0&&validScalar(payload.subarray(46)))return 'extendedKey';
  }
  return value.length>=85&&value.length<=88&&solanaKeypair(base58(value))?'solanaKeypair':null;
}

// BIP173 / BIP350 segwit addresses for bc and tb.
const BECH32='qpzry9x8gf2tvdw0s3jn54khce6mua7l';
function polymod(values){
  const generator=[0x3b6a57b2,0x26508e6d,0x1ea119fa,0x3d4233dd,0x2a1462b3];let check=1;
  for(const value of values){const top=check>>>25;check=((check&0x1ffffff)<<5)^value;for(let bit=0;bit<5;bit++)if((top>>bit)&1)check^=generator[bit];}
  return check>>>0;
}
function segwit(value){
  if(value.length>90||(value!==value.toLowerCase()&&value!==value.toUpperCase()))return null;
  const text=value.toLowerCase(),separator=text.lastIndexOf('1'),hrp=text.slice(0,separator);
  if(hrp!=='bc'&&hrp!=='tb'||text.length-separator-1<7)return null;
  const data=[...text.slice(separator+1)].map(character=>BECH32.indexOf(character));if(data.includes(-1))return null;
  const expanded=[...[...hrp].map(c=>c.charCodeAt(0)>>5),0,...[...hrp].map(c=>c.charCodeAt(0)&31),...data];
  const constant=polymod(expanded),version=data[0];
  if(constant!==(version===0?1:0x2bc830a3)||version>16)return null;
  let accumulator=0,bits=0;const program=[];
  for(const digit of data.slice(1,-6)){accumulator=((accumulator<<5)|digit)&0xfff;bits+=5;if(bits>=8){bits-=8;program.push((accumulator>>bits)&255);}}
  if(bits>=5||((accumulator<<(8-bits))&255))return null;
  if(program.length<2||program.length>40||(version===0&&program.length!==20&&program.length!==32))return null;
  return hrp==='bc'?'bitcoin':'bitcoin-testnet';
}

// EIP-55 needs Keccak-256 (not NIST SHA3-256, which node:crypto exposes).
const KECCAK_ROUNDS=[1n,0x8082n,0x800000000000808an,0x8000000080008000n,0x808bn,0x80000001n,0x8000000080008081n,0x8000000000008009n,0x8an,0x88n,0x80008009n,0x8000000an,0x8000808bn,0x800000000000008bn,0x8000000000008089n,0x8000000000008003n,0x8000000000008002n,0x8000000000000080n,0x800an,0x800000008000000an,0x8000000080008081n,0x8000000000008080n,0x80000001n,0x8000000080008008n];
const KECCAK_ROTATION=[0,1,62,28,27,36,44,6,55,20,3,10,43,25,39,41,45,15,21,8,18,2,61,56,14];
const MASK=(1n<<64n)-1n;
const rotate=(value,count)=>count?((value<<BigInt(count))|(value>>BigInt(64-count)))&MASK:value;
function keccak256(input){
  const rate=136,padded=Buffer.alloc((Math.floor(input.length/rate)+1)*rate);input.copy(padded);padded[input.length]^=1;padded[padded.length-1]^=0x80;
  const state=new Array(25).fill(0n);
  for(let offset=0;offset<padded.length;offset+=rate){
    for(let lane=0;lane<rate/8;lane++)state[lane]^=padded.readBigUInt64LE(offset+lane*8);
    for(const round of KECCAK_ROUNDS){
      const column=[0,1,2,3,4].map(x=>state[x]^state[x+5]^state[x+10]^state[x+15]^state[x+20]);
      for(let x=0;x<5;x++){const delta=column[(x+4)%5]^rotate(column[(x+1)%5],1);for(let y=0;y<25;y+=5)state[x+y]^=delta;}
      const moved=new Array(25);
      for(let x=0;x<5;x++)for(let y=0;y<5;y++)moved[y+5*((2*x+3*y)%5)]=rotate(state[x+5*y],KECCAK_ROTATION[x+5*y]);
      for(let y=0;y<25;y+=5)for(let x=0;x<5;x++)state[x+y]=moved[x+y]^((~moved[(x+1)%5+y])&MASK&moved[(x+2)%5+y]);
      state[0]^=round;
    }
  }
  const output=Buffer.alloc(32);for(let lane=0;lane<4;lane++)output.writeBigUInt64LE(state[lane],lane*8);return output;
}
function evm(value){
  if(!/^0x[0-9a-fA-F]{40}$/u.test(value))return false;
  const body=value.slice(2);if(body===body.toLowerCase()||body===body.toUpperCase())return true;
  const hash=keccak256(Buffer.from(body.toLowerCase(),'ascii')).toString('hex');
  return [...body].every((character,index)=>!/[a-f]/iu.test(character)||(parseInt(hash[index],16)>=8)===(character===character.toUpperCase()));
}

function addressChain(value){
  if(evm(value))return 'evm';
  if(/^(?:bc|tb)1/iu.test(value))return segwit(value);
  if(!/^[1-9A-HJ-NP-Za-km-z]{25,44}$/u.test(value))return null;
  const payload=base58Check(value);
  if(payload?.length===21){
    if(payload[0]===0x00||payload[0]===0x05)return 'bitcoin';
    if(payload[0]===0x6f||payload[0]===0xc4)return 'bitcoin-testnet';
    if(payload[0]===0x41)return 'tron';
  }
  return value.length>=32&&base58(value)?.length===32?'solana':null;
}
// Case-insensitive encodings compare in lower case; base58 is case-sensitive.
function comparable(address){return address.chain==='evm'||/^(?:bc|tb)1/iu.test(address.value)?address.value.toLowerCase():address.value;}
function distinctive(address){
  const value=comparable(address);
  if(address.chain==='evm')return value.slice(2);
  if(/^(?:bc|tb)1/u.test(value))return value.slice(4);// hrp, separator, witness version
  return address.chain==='solana'?value:value.slice(1);// base58 version character
}

function classify(text){
  if(typeof text!=='string'||text.length>LIMITS.maximumInspectedCharacters)return NONE;
  const value=trimmed(text);if(!value)return NONE;
  if(containsMnemonic(value))return{kind:'secret',secret:'recoveryPhrase',format:'bip39'};
  const format=privateKeyFormat(value);if(format)return{kind:'secret',secret:'privateKey',format};
  const chain=addressChain(value);return chain?{kind:'address',chain,value}:NONE;
}

class WalletGuard {
  constructor({clock=()=>Date.now()}={}){this.clock=clock;this.last=null;this.session=[];}
  reset(){this.last=null;this.session=[];}
  // history: recent saved texts, newest first. context: identity of the
  // foreground application, or null when the platform cannot tell.
  inspect(text,{enabled=true,context=null,history=[]}={}){
    if(!enabled){this.reset();return{save:true,notice:null,alert:null};}
    const result=classify(text),now=this.clock();
    if(result.kind==='secret'){this.last=null;return{save:false,notice:result.secret,alert:null};}
    if(result.kind!=='address'){this.last=null;return{save:true,notice:null,alert:null};}
    const address={chain:result.chain,value:result.value},key=comparable(address),previous=this.last;
    let alert=null;
    if(previous&&previous.chain===address.chain&&previous.key!==key&&now-previous.at>=0&&now-previous.at<=LIMITS.hijackWindowMs&&
      (previous.context===null||context===null||previous.context===context))alert={type:'hijack',original:previous.value,replacement:address.value};
    if(!alert){const similar=this.lookalike(address,key,history);if(similar)alert={type:'poisoning',address:address.value,similar};}
    this.last={...address,key,at:now,context};
    this.session=[address,...this.session.filter(item=>comparable(item)!==key)].slice(0,LIMITS.sessionAddresses);
    return{save:true,notice:null,alert};
  }
  lookalike(address,key,history){
    const body=distinctive(address),{lookalikePrefix:prefix,lookalikeSuffix:suffix}=LIMITS;
    const candidates=[...this.session,...(Array.isArray(history)?history:[]).slice(0,LIMITS.historyAddresses).map(text=>{
      if(typeof text!=='string'||text.length>256)return null;const value=trimmed(text),chain=addressChain(value);return chain?{chain,value}:null;})];
    for(const candidate of candidates){
      if(!candidate||candidate.chain!==address.chain||comparable(candidate)===key)continue;
      const other=distinctive(candidate);
      if(other.length===body.length&&other.slice(0,prefix)===body.slice(0,prefix)&&other.slice(-suffix)===body.slice(-suffix))return candidate.value;
    }
    return null;
  }
}
// User-facing text, keyed by the shared English catalog strings. Notices are
// short; replacement and lookalike alerts keep both addresses for comparison.
function walletGuardMessage(verdict,translate=key=>key){
  const alert=verdict?.alert;
  if(alert?.type==='hijack')return{title:translate('Copied address was replaced'),body:translate('Your copied address was replaced by another address. This is how clipboard malware steals crypto.'),
    rows:[{label:translate('You copied'),value:alert.original},{label:translate('Clipboard now'),value:alert.replacement}],persistent:true};
  if(alert?.type==='poisoning')return{title:translate('Possible lookalike address'),body:translate('This address starts and ends like one you copied before, but the middle is different. It may be a poisoned lookalike. Compare every character before sending.'),
    rows:[{label:translate('Copied now'),value:alert.address},{label:translate('Copied before'),value:alert.similar}],persistent:true};
  if(verdict?.notice==='recoveryPhrase')return{title:translate('Wallet Guard'),body:translate('Recovery phrase not saved. Never paste it into websites or chats.'),rows:[],persistent:false};
  if(verdict?.notice==='privateKey')return{title:translate('Wallet Guard'),body:translate('Private key not saved. Never paste it into websites or chats.'),rows:[],persistent:false};
  return null;
}
function messageSummary(message){return[message.title,message.body,...message.rows.map(row=>row.label+': '+row.value)].join('\n');}
module.exports={WalletGuard,classify,walletGuardMessage,messageSummary,LIMITS,keccak256};
