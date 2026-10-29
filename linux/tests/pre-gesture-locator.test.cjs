'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {preparePreGestureLocator}=require('./pre-gesture-locator.cjs');
const detached=()=>new Error('locator.scrollIntoViewIfNeeded: Element is not attached to the DOM\nCall log:\n - waiting for element to be stable');

test('pre-gesture scroll and hover resolve replacement nodes after a controlled detach during stability',async()=>{
 for(const method of ['scrollIntoViewIfNeeded','hover']){
  let generation=0,resolutions=0;const actions=[];
  const resolve=()=>{const identity=++resolutions;return{async waitFor(options){assert.equal(options.state,'visible');assert.ok(options.timeout>0&&options.timeout<=3000);},async[method](options){actions.push(identity);assert.ok(options.timeout>0&&options.timeout<=3000);if(!generation++){throw detached();}}};};
  await preparePreGestureLocator(resolve,method);assert.equal(resolutions,2);assert.deepEqual(actions,[1,2]);
 }
});

test('pre-gesture retries stop at the attempt cap and at the original deadline without sleeping',async()=>{
 const error=detached();let attempts=0;const resolve=()=>{attempts++;return{async waitFor(){},async hover(){throw error;}};};
 await assert.rejects(preparePreGestureLocator(resolve,'hover',{maxAttempts:3}),value=>value===error);assert.equal(attempts,3);
 attempts=0;let clock=0;await assert.rejects(preparePreGestureLocator(resolve,'hover',{timeout:10,now:()=>clock+=3}),value=>value===error);assert.equal(attempts,1);
});

test('missing, hidden, timeout and other action errors propagate without retry or synthetic success',async()=>{
 for(const error of [new Error('Target page, context or browser has been closed'),new Error('Element is hidden'),Object.assign(new Error('locator.hover: Timeout 3000ms exceeded\nElement is not attached to the DOM'),{name:'TimeoutError'}),new Error('Unexpected action failure')]){
  let attempts=0;await assert.rejects(preparePreGestureLocator(()=>{attempts++;return{async waitFor(){},async hover(){throw error;}};},'hover'),value=>value===error);assert.equal(attempts,1);
 }
 let attempts=0;const missing=Object.assign(new Error('Waiting for locator to be visible exceeded'),{name:'TimeoutError'});await assert.rejects(preparePreGestureLocator(()=>{attempts++;return{async waitFor(){throw missing;},async hover(){assert.fail('Missing source must not receive input');}};},'hover'),value=>value===missing);assert.equal(attempts,1);
 await assert.rejects(preparePreGestureLocator(()=>assert.fail('Not a pre-gesture action'),'click'),/Unsupported/);
});
