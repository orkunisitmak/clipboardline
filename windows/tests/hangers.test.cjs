'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {HANGERS,hangerFor,ROPE_Y,BOX}=require('../lib/hangers.cjs');
const contract=JSON.parse(fs.readFileSync(path.join(__dirname,'../../contracts/hangers.json'),'utf8'));
test('thirty hangers match the shared macOS catalog',()=>{
 assert.equal(HANGERS.length,30);assert.equal(ROPE_Y,contract.ropeY);assert.equal(BOX,contract.box);
 assert.deepEqual(HANGERS,contract.hangers);
 for(const h of HANGERS)assert.ok(!h.svg.includes('NaN')&&h.svg.startsWith('<svg'),h.name);
});
test('each card keeps the same hanger as on macOS',()=>{
 for(const s of contract.samples)assert.deepEqual(hangerFor(s.id),{index:s.index,size:s.size,lean:s.lean});
});
