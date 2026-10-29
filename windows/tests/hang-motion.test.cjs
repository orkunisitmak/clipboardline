'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const hang=require('../lib/hang-motion.cjs');
const contract=JSON.parse(fs.readFileSync(path.join(__dirname,'../../contracts/hang-motion.json'),'utf8'));
test('rope and swing constants match the shared macOS contract',()=>{
 assert.deepEqual(hang.ROPE,contract.rope);
 for(const key of Object.keys(contract.swing))assert.equal(hang.SWING[key],contract.swing[key],key);
});
test('rope dip reproduces every shared sample',()=>{
 for(const sample of contract.samples)assert.ok(Math.abs(hang.dip(sample.x,sample.time,sample.plucks)-sample.dip)<0.0005,JSON.stringify(sample));
});
test('only small local changes pluck the rope',()=>{
 assert.deepEqual(hang.diff(['a','b'],['c','a','b']),{added:[{id:'c',index:0}],removed:[]});
 assert.deepEqual(hang.diff(['a','b','c'],['a','c']),{added:[],removed:[{id:'b',index:1}]});
 assert.deepEqual(hang.diff(['a','b','c'],['d','e','f','g']),{added:[],removed:[]});
});
test('the swing settles and the breeze travels left to right',()=>{
 assert.equal(hang.swing(10,0),10);assert.ok(Math.abs(hang.swing(10,1.6))<0.1);assert.ok(Math.abs(hang.drop(1.2))<0.5);
 assert.equal(hang.breezeDelay(-5),0);assert.ok(hang.breezeDelay(200)<hang.breezeDelay(600));assert.equal(hang.breezeDelay(1e6),contract.swing.breezeMaximumDelay);
});
test('reduce motion ignores row changes',()=>{
 const ropes=new hang.HangRopes({reduceMotion:()=>true,now:()=>1,frame:()=>{throw new Error('must not animate');}});
 const element=ids=>({dataset:{shelf:'texts'},getBoundingClientRect:()=>({left:0,width:1000}),querySelectorAll:()=>ids.map((id,i)=>({dataset:{itemId:id},getBoundingClientRect:()=>({left:i*170,width:150})}))});
 ropes.observe(element(['a']));ropes.observe(element(['b','a']));ropes.breeze();
 assert.equal(ropes.shelf('texts').plucks.length,0);
});
