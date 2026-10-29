'use strict';
const fs=require('node:fs');

// Byte-pair encoding and the same first 48,894 merges used by the Mac Clip.swift.
// Queries never leave the worker or become part of the persisted image index.
class ClipTokenizer{
 constructor(vocab,merges){
  if(!vocab||typeof vocab!=='object'||Array.isArray(vocab)||typeof merges!=='string')throw new Error('Invalid CLIP tokenizer assets.');
  this.vocab=vocab;this.ranks=new Map(merges.split(/\r?\n/).slice(1,49152-256-2+1).map((line,index)=>[line,index]));this.cache=new Map();
  const bytes=[...Array.from({length:94},(_,i)=>33+i),...Array.from({length:12},(_,i)=>161+i),...Array.from({length:82},(_,i)=>174+i)],characters=[...bytes];
  for(let byte=0,next=256;byte<256;byte++)if(!bytes.includes(byte)){bytes.push(byte);characters.push(next++);}
  this.byteToUnicode=new Map(bytes.map((byte,index)=>[byte,String.fromCodePoint(characters[index])]));
 }
 static fromFiles(vocab,merges){return new ClipTokenizer(JSON.parse(fs.readFileSync(vocab,'utf8')),fs.readFileSync(merges,'utf8'));}
 encode(text){
  const clean=String(text).slice(0,2048).toLowerCase().trim().split(/\s+/u).join(' '),ids=[49406];
  const words=clean.match(/<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d|[\p{L}]+|[\p{N}]|[^\s\p{L}\p{N}]+/giu)||[];
  for(const token of words){const word=[...Buffer.from(token,'utf8')].map(byte=>this.byteToUnicode.get(byte)).join('');for(const piece of this.bpe(word)){const value=this.vocab[piece];if(Number.isInteger(value)&&value>=0&&value<=49407)ids.push(value);}}
  ids.length=Math.min(ids.length,76);ids.push(49407);return ids;
 }
 tensor(text){const output=new BigInt64Array(77);this.encode(text).forEach((id,index)=>{output[index]=BigInt(id);});return output;}
 bpe(word){
  if(this.cache.has(word))return this.cache.get(word);let parts=[...word];if(!parts.length)return[];parts[parts.length-1]+='</w>';
  while(parts.length>1){let best=Infinity,selected=-1;for(let index=0;index<parts.length-1;index++){const rank=this.ranks.get(parts[index]+' '+parts[index+1]);if(rank!==undefined&&rank<best){best=rank;selected=index;}}if(selected<0)break;
   const first=parts[selected],second=parts[selected+1],merged=[];for(let index=0;index<parts.length;index++){if(parts[index]===first&&parts[index+1]===second){merged.push(first+second);index++;}else merged.push(parts[index]);}parts=merged;
  }
  if(this.cache.size>=2048)this.cache.clear();this.cache.set(word,parts);return parts;
 }
}
module.exports={ClipTokenizer};
