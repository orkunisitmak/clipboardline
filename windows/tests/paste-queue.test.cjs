'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {PasteQueue}=require('../lib/paste-queue.cjs');
test('paste queue replays in the given oldest-first order and replacing discards the previous queue',()=>{
 const queue=new PasteQueue();assert.equal(queue.next(()=>true),null);
 assert.equal(queue.replace(['old','middle','new']),3);assert.equal(queue.next(()=>true),'old');
 queue.complete('old');assert.equal(queue.next(()=>true),'middle');
 queue.replace(['other']);assert.equal(queue.next(()=>true),'other');queue.complete('other');assert.equal(queue.next(()=>true),null);
});
test('missing or trashed items are dropped before the next paste',()=>{
 const queue=new PasteQueue(),available=new Set(['b']);queue.replace(['a','b','c']);
 assert.equal(queue.next(id=>available.has(id)),'b');assert.deepEqual(queue.ids,['b','c']);
 queue.complete('b');assert.equal(queue.next(id=>available.has(id)),null);assert.deepEqual(queue.ids,[]);
});
test('completion removes only the current head so a queue replaced mid-paste is not shortened',()=>{
 const queue=new PasteQueue();queue.replace(['a','b']);queue.replace(['x','y']);queue.complete('a');assert.deepEqual(queue.ids,['x','y']);
 queue.complete('y');assert.deepEqual(queue.ids,['x','y']);queue.complete('x');assert.deepEqual(queue.ids,['y']);
});
