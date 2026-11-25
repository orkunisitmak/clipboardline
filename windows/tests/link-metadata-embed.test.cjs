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

test('a blank or padded YouTube oEmbed author is trimmed',async()=>{
 const author=async value=>(await linkMetadata('https://youtu.be/synthetic',async()=>({bytes:Buffer.from(JSON.stringify({title:'Example video',author_name:value})),type:'application/json'}))).author;
 assert.equal(await author('  \t '),'');
 assert.equal(await author('  Example author  '),'Example author');
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

test('textarea start tags are read whole whatever their length, and only ASCII spacing ends the name',async()=>{
 const page=html=>linkMetadata('https://example.com/a',async()=>({bytes:Buffer.from(html),url:'https://example.com/a',type:'text/html'}));
 assert.equal((await page('<textarea data='+'x'.repeat(3000)+'><meta property="og:title" content="injected"></textarea><title>real</title>')).title,'real');
 assert.equal((await page('<textarea\u00a0x><meta property="og:title" content="real">')).title,'real');
 const started=Date.now();
 await page('<script>'.repeat(60000)+'<!--'.repeat(60000)+'<title>real</title>');
 assert.ok(Date.now()-started<2000);
});

test('unclosed tags at the 512 KiB fetch ceiling parse in linear time',async()=>{
 const page=html=>async()=>({bytes:Buffer.from(html),url:'https://example.com/',type:'text/html'}),size=512*1024;
 for(const html of ['<title'.repeat(size/6),'<meta'.repeat(size/5),('<meta '+'a'.repeat(4000)+'>').repeat(size/4007|0),('<title>'+'a'.repeat(2001)).repeat(size/2008|0),'<title>'.repeat((size-8)/7|0)+'</title>']){
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

test('long YouTube oEmbed title and author are cut on whole characters',async()=>{
 const emoji='\u{1F600}',title='a'.repeat(499)+emoji+' tail',author='b'.repeat(199)+emoji+' tail';
 const metadata=await linkMetadata('https://youtu.be/synthetic',async()=>({bytes:Buffer.from(JSON.stringify({title,author_name:author})),type:'application/json'}));
 assert.equal(metadata.title,'a'.repeat(499)+emoji);assert.equal(metadata.author,'b'.repeat(199)+emoji);
});
