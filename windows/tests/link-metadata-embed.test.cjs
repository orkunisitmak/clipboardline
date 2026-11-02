'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {linkMetadata}=require('../lib/network.cjs');

test('YouTube link previews retain a usable host title on missing or malformed oEmbed data',async()=>{
 for(const payload of [null,{},[],true,{title:'   ',author_name:'',thumbnail_url:''}]){
  const metadata=await linkMetadata('https://youtu.be/synthetic',async()=>({bytes:Buffer.from(JSON.stringify(payload)),type:'application/json'}));
  assert.equal(metadata.title,'youtu.be');
  assert.equal(metadata.author,'');
  assert.equal(metadata.thumbnail,'');
 }
});

test('a valid YouTube oEmbed title and author still render normally',async()=>{
 const response=await linkMetadata('https://music.youtube.com/watch?v=synthetic',async()=>({bytes:Buffer.from(JSON.stringify({title:'Example video',author_name:'Example author',thumbnail_url:'https://i.ytimg.com/vi/synthetic/default.jpg'}))}));
 assert.deepEqual(response,{title:'Example video',author:'Example author',thumbnail:'https://i.ytimg.com/vi/synthetic/default.jpg'});
});

test('meta tags with unquoted attribute values are read like macOS',async()=>{
 const html='<title>Site Home | Brand</title><meta property=og:title content=Real-Article-Title><meta property=og:image content=https://cdn.example.com/a.png>';
 const metadata=await linkMetadata('https://example.com/post',async()=>({bytes:Buffer.from(html),url:'https://example.com/post',type:'text/html; charset=utf-8'}));
 assert.equal(metadata.title,'Real-Article-Title');assert.equal(metadata.thumbnail,'https://cdn.example.com/a.png');
});

test('unclosed tags at the 512 KiB fetch ceiling parse in linear time',async()=>{
 const page=html=>async()=>({bytes:Buffer.from(html),url:'https://example.com/',type:'text/html'}),size=512*1024;
 for(const html of ['<title'.repeat(size/6),'<meta'.repeat(size/5),('<meta '+'a'.repeat(4000)+'>').repeat(size/4007|0),('<title>'+'a'.repeat(2001)).repeat(size/2008|0)]){
  const started=Date.now();assert.equal((await linkMetadata('https://example.com/',page(html))).title,'example.com');
  assert.ok(Date.now()-started<2000,`parse took ${Date.now()-started} ms`);
 }
});

test('titles and meta tags after unclosed or oversized tags are still found',async()=>{
 const read=async html=>linkMetadata('https://example.com/',async()=>({bytes:Buffer.from(html),url:'https://example.com/',type:'text/html'}));
 assert.equal((await read('<title>'+'a'.repeat(2001)+'<title>Real</title>')).title,'Real');
 assert.equal((await read('<TITLE lang="tr">Büyük</TITLE>')).title,'Büyük');
 assert.equal((await read('<meta '+'x'.repeat(5000)+'<meta property="og:title" content="Inner">')).title,'Inner');
 assert.equal((await read('<meta 1property=og:title content=Digits>')).title,'Digits');
 assert.equal((await read('<meta property content=Lost><title>Fallback</title>')).title,'Fallback');
});
