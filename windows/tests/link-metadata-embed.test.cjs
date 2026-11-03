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

test('markup inside a textarea is not the preview title',async()=>{
 const page=html=>linkMetadata('https://example.com/a',async()=>({bytes:Buffer.from(html),url:'https://example.com/a',type:'text/html'}));
 assert.equal((await page('<textarea><meta property="og:title" content="injected"></textarea><title>real</title>')).title,'real');
 assert.equal((await page('<title>real</title><textarea><meta property="og:title" content="injected">')).title,'real');
});

test('a textarea tag inside a script or an attribute is not read as a textarea',async()=>{
 const page=html=>linkMetadata('https://example.com/a',async()=>({bytes:Buffer.from(html),url:'https://example.com/a',type:'text/html'}));
 assert.equal((await page(`<script>const t = '<textarea>';</script><title>real</title>`)).title,'real');
 assert.equal((await page(`<textarea data-x="> </textarea>"><meta property="og:title" content="injected"></textarea><title>real</title>`)).title,'real');
});

test('a custom element named like a textarea is not a textarea and a pile of broken tags stays fast',async()=>{
 const page=html=>linkMetadata('https://example.com/a',async()=>({bytes:Buffer.from(html),url:'https://example.com/a',type:'text/html'}));
 assert.equal((await page('<textarea-x></textarea-x><title>real</title>')).title,'real');
 const started=Date.now();
 await page('<textarea "'.repeat(40000)+'<title>real</title>');
 assert.ok(Date.now()-started<2000);
});
