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

test('meta tags inside comments, scripts and styles do not supply the preview title or image',async()=>{
 const page=html=>linkMetadata('https://example.com/a',async()=>({bytes:Buffer.from(html),url:'https://example.com/a',type:'text/html'}));
 const fake='<meta property="og:title" content="Fake"><meta property="og:image" content="https://example.com/fake.png">';
 for(const wrapper of ['<!--'+fake+'-->','<script>var s=\''+fake+'\';</script>','<style>/* '+fake+' */</style>']){
  assert.deepEqual(await page(wrapper+'<title>Real</title>'),{title:'Real',thumbnail:''});
 }
 assert.deepEqual(await page('<!--'+fake+'--><meta property="og:title" content="Real og"><meta property="og:image" content="/real.png">'),{title:'Real og',thumbnail:'https://example.com/real.png'});
});

test('unclosed comments, scripts and styles hide their fake tags and bad input stays bounded',async()=>{
 const page=html=>linkMetadata('https://example.com/a',async()=>({bytes:Buffer.from(html),url:'https://example.com/a',type:'text/html'}));
 const fake='<meta property="og:title" content="Fake"><meta property="og:image" content="https://example.com/fake.png">';
 for(const opener of ['<!--','<script>','<style>','<SCRIPT type="x">'])assert.deepEqual(await page('<title>Real</title>'+opener+fake),{title:'Real',thumbnail:''},opener);
 for(const html of ['','   \n ','<','<!--','<script','<style>','-->','</script>'])assert.deepEqual(await page(html),{title:'example.com',thumbnail:''},html);
 const started=Date.now();
 for(const [piece,count] of [['<!--',131072],['<script>',65536],['<style ',74898],['<script ',65536],['<title ',74898],['<meta ',87381]])await page(piece.repeat(count));
 assert.ok(Date.now()-started<5000);
});

test('a custom element that starts with script or style does not hide the real preview tags',async()=>{
 const page=html=>linkMetadata('https://example.com/a',async()=>({bytes:Buffer.from(html),url:'https://example.com/a',type:'text/html'}));
 for(const tag of ['script-widget','style-widget'])assert.deepEqual(await page('<'+tag+'>x</'+tag+'><meta property="og:title" content="Real"><meta property="og:image" content="/real.png">'),{title:'Real',thumbnail:'https://example.com/real.png'},tag);
});

test('a script or comment marker inside a meta attribute does not hide the real preview tags',async()=>{
 const page=html=>linkMetadata('https://example.com/a',async()=>({bytes:Buffer.from(html),url:'https://example.com/a',type:'text/html'}));
 const real='<meta property="og:title" content="Real"><meta property="og:image" content="/real.png">';
 for(const marker of ['<script>','<style>','<!--']){
  assert.deepEqual(await page('<meta name="keywords" content="a '+marker+' b">'+real+'<script>x</script>'),{title:'Real',thumbnail:'https://example.com/real.png'},marker);
 }
});
