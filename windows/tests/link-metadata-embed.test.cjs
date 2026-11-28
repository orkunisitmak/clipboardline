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

test('meta tags inside comments, scripts and styles do not supply the preview title or image',async()=>{
 const page=html=>linkMetadata('https://example.com/a',async()=>({bytes:Buffer.from(html),url:'https://example.com/a',type:'text/html'}));
 const fake='<meta property="og:title" content="Fake"><meta property="og:image" content="https://example.com/fake.png">';
 for(const wrapper of ['<!--'+fake+'-->','<script>var s=\''+fake+'\';</script>','<style>/* '+fake+' */</style>']){
  assert.deepEqual(await page(wrapper+'<title>Real</title>'),{title:'Real',thumbnail:''});
 }
 assert.deepEqual(await page('<!--'+fake+'--><meta property="og:title" content="Real og"><meta property="og:image" content="/real.png">'),{title:'Real og',thumbnail:'https://example.com/real.png'});
});

test('unclosed comments, scripts, styles and textareas hide their fake tags and bad input stays bounded',async()=>{
 const page=html=>linkMetadata('https://example.com/a',async()=>({bytes:Buffer.from(html),url:'https://example.com/a',type:'text/html'}));
 const fake='<meta property="og:title" content="Fake"><meta property="og:image" content="https://example.com/fake.png">';
 for(const opener of ['<!--','<script>','<style>','<textarea>','<SCRIPT type="x">','<TextArea\nrows=2>'])assert.deepEqual(await page('<title>Real</title>'+opener+fake),{title:'Real',thumbnail:''},opener);
 for(const html of ['','   \n ','<','<!--','<script','<style>','<textarea','-->','</script>'])assert.deepEqual(await page(html),{title:'example.com',thumbnail:''},html);
 const started=Date.now();
 for(const [piece,count] of [['<!--',131072],['<script>',65536],['<style ',74898],['<script ',65536],['<title ',74898],['<meta ',87381]])await page(piece.repeat(count));
 assert.ok(Date.now()-started<5000);
});

test('unclosed blocks hide the rest of the page',async()=>{
 const page=html=>linkMetadata('https://example.com/a',async()=>({bytes:Buffer.from(html),url:'https://example.com/a',type:'text/html'}));
 const fakeImage="<meta property='og:image' content='https://example.com/fake.png'>",realImage="<meta property='og:image' content='https://example.com/real.png'>";
 assert.deepEqual(await page(`<script>const m="<title>";<meta property='og:title' content='script'>`),{title:'example.com',thumbnail:''});
 assert.deepEqual(await page(`<style>p{}<meta property='og:title' content='style'>`),{title:'example.com',thumbnail:''});
 assert.deepEqual(await page('<!-- '+fakeImage),{title:'example.com',thumbnail:''});
 assert.deepEqual(await page('<!-- a > b '+fakeImage),{title:'example.com',thumbnail:''});
 // <!--> and <!---> are empty comments; a comment also ends at --!>.
 for(const comment of ['<!-->','<!--->','<!-- x --!>','<!-- x -->','<!---->'])assert.deepEqual(await page(comment+realImage),{title:'example.com',thumbnail:'https://example.com/real.png'},comment);
 assert.deepEqual(await page(`<textarea><meta property='og:title' content='fake'></textarea><title>Real</title>`),{title:'Real',thumbnail:''});
 assert.deepEqual(await page(`<textarea><meta property='og:title' content='fake'></TEXTAREA \n><title>Real</title>`),{title:'Real',thumbnail:''});
 assert.deepEqual(await page(`<textarea><meta property='og:title' content='textarea'>`),{title:'example.com',thumbnail:''});
 // A closer must be </name, optional ASCII whitespace and '>'.
 assert.deepEqual(await page(`<script></scriptx><meta property='og:title' content='script'>`),{title:'example.com',thumbnail:''});
});

test('a custom element named like script, style or textarea starts nothing',async()=>{
 const page=html=>linkMetadata('https://example.com/a',async()=>({bytes:Buffer.from(html),url:'https://example.com/a',type:'text/html'}));
 for(const tag of ['script-widget','style-x','textarea-x','stylex','SCRIPT-widget'])assert.deepEqual(await page('<'+tag+'>x</'+tag+"><meta property='og:title' content='Real'><meta property=\"og:image\" content=\"/real.png\">"),{title:'Real',thumbnail:'https://example.com/real.png'},tag);
});

test('a marker inside a meta attribute value starts nothing',async()=>{
 const page=html=>linkMetadata('https://example.com/a',async()=>({bytes:Buffer.from(html),url:'https://example.com/a',type:'text/html'}));
 for(const marker of ['<script>','<style>','<!--','<textarea>']){
  assert.deepEqual(await page(`<meta name='k' content='a ${marker} b'><meta property='og:title' content='Real'>`),{title:'Real',thumbnail:''},marker);
  assert.deepEqual(await page(`<meta name="k" content="a ${marker} b"><meta property="og:title" content="Real"><meta property="og:image" content="/real.png"><script>x</script>`),{title:'Real',thumbnail:'https://example.com/real.png'},marker);
 }
});

test('repeated block openers at the 512 KiB fetch ceiling parse in linear time',async()=>{
 const page=html=>async()=>({bytes:Buffer.from(html),url:'https://example.com/',type:'text/html'}),size=512*1024;
 for(const piece of ['<script>','<style>','<!--','<textarea>','<meta "','<script-x>']){
  const started=Date.now();assert.equal((await linkMetadata('https://example.com/',page(piece.repeat(size/piece.length|0)))).title,'example.com',piece);
  assert.ok(Date.now()-started<2000,`${piece} parse took ${Date.now()-started} ms`);
 }
});

test('a custom element that starts with title is not the page title',async()=>{
 const page=html=>linkMetadata('https://example.com/a',async()=>({bytes:Buffer.from(html),url:'https://example.com/a',type:'text/html'}));
 assert.deepEqual(await page('<title-widget>'+'W'.repeat(600)+'</title-widget><title>Real</title>'),{title:'Real',thumbnail:''});
 assert.deepEqual(await page('<title lang="en">Real</title>'),{title:'Real',thumbnail:''});
});

test('a quoted > inside a meta or title attribute does not end the tag',async()=>{
 const page=html=>linkMetadata('https://example.com/a',async()=>({bytes:Buffer.from(html),url:'https://example.com/a',type:'text/html'}));
 assert.deepEqual(await page('<meta content="a > b" property="og:title"><meta content=\'/x.png?a>b\' property=og:image>'),{title:'a > b',thumbnail:'https://example.com/x.png?a%3Eb'});
 assert.deepEqual(await page('<title data-x="a>b">Real</title>'),{title:'Real',thumbnail:''});
});

test('unclosed tags at the 512 KiB fetch ceiling parse in linear time',async()=>{
 const page=html=>async()=>({bytes:Buffer.from(html),url:'https://example.com/',type:'text/html'}),size=512*1024;
 for(const html of ['<title'.repeat(size/6),'<meta'.repeat(size/5),'<meta "'.repeat(size/7|0)+'>',`<meta '"'"`.repeat(size/10|0)+'>',('<meta '+'a'.repeat(4000)+'>').repeat(size/4007|0),('<title>'+'a'.repeat(2001)).repeat(size/2008|0),'<title>'.repeat((size-8)/7|0)+'</title>']){
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

test('a greater-than sign inside a quoted meta value keeps the title',async()=>{
 const page=html=>linkMetadata('https://example.com/a',async()=>({bytes:Buffer.from(html),url:'https://example.com/a',type:'text/html'}));
 assert.equal((await page(`<meta property="og:title" content="Tips > Tricks"><title>Page</title>`)).title,'Tips > Tricks');
 assert.equal((await page(`<meta property='og:title' content='Tips > Tricks'><title>Page</title>`)).title,'Tips > Tricks');
 // A quote that never closes does not swallow the tags after it: the tag ends at its first '>' as before.
 assert.equal((await page(`<meta name='size' content="5" tall"><meta property='og:title' content='Meta'><title>Page</title>`)).title,'Meta');
});
