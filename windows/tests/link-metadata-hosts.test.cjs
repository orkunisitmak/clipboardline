const test=require('node:test');const assert=require('node:assert/strict');
const {metadataGuard}=require('../lib/network.cjs');
test('link preview refuses IP-literal and trailing-dot hosts like macOS',()=>{
 for(const u of ['https://8.8.8.8/a','https://[2606:4700::1111]/a','https://example.com./a','https://0x08080808/a'])assert.throws(()=>metadataGuard(new URL(u)),/named host/);
 assert.doesNotThrow(()=>metadataGuard(new URL('https://example.com/a')));
});
