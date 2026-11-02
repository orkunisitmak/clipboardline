const test=require('node:test');const assert=require('node:assert/strict');
const {linkMetadata}=require('../lib/network.cjs');
const page=html=>linkMetadata('https://example.com/a',async()=>({bytes:Buffer.from(html),url:'https://example.com/a',type:'text/html'}));
test('twitter cards, secure_url and mixed-case meta names supply the preview',async()=>{
 assert.deepEqual(await page('<meta name="twitter:title" content="TW"><meta name="twitter:image" content="/t.png"><title>Tag</title>'),{title:'TW',thumbnail:'https://example.com/t.png'});
 assert.deepEqual(await page('<meta property="OG:Title" content="UP"><meta NAME="Twitter:Image" content="/n.png">'),{title:'UP',thumbnail:'https://example.com/n.png'});
 assert.deepEqual(await page('<meta property="og:image" content="http://example.com/a.png"><meta property="og:image:secure_url" content="https://example.com/a.png">'),{title:'example.com',thumbnail:'https://example.com/a.png'});
});
