'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {capturedImageEvent,OPEN_MODES}=require('../lib/captured-image.cjs');
const {settings}=require('../lib/model.cjs');
const image=Object.freeze({id:'00000000-0000-4000-8000-000000000001',kind:'image'});
const recording=Object.freeze({...image,recording:true,videoFile:'a'.repeat(64)+'.mp4',imageFile:'b'.repeat(64)+'.png'});
const text=Object.freeze({id:'00000000-0000-4000-8000-000000000002',kind:'text'});

test('captured images default to opening the preview with the crop editor',()=>{
  assert.deepEqual(capturedImageEvent({},image),{selectId:image.id,kind:'image',preview:true,crop:true});
  assert.deepEqual(capturedImageEvent(undefined,image),{selectId:image.id,kind:'image',preview:true,crop:true});
});
test('each captured-image preference maps to its capture event',()=>{
  assert.deepEqual(capturedImageEvent({capturedImageOpens:'crop'},image),{selectId:image.id,kind:'image',preview:true,crop:true});
  assert.deepEqual(capturedImageEvent({capturedImageOpens:'preview'},image),{selectId:image.id,kind:'image',preview:true});
  assert.deepEqual(capturedImageEvent({capturedImageOpens:'shelf'},image),{selectId:image.id,kind:'image'});
  assert.equal(capturedImageEvent({capturedImageOpens:'off'},image),null);
});
test('recordings and non-image captures never open a crop editor',()=>{
  assert.deepEqual(capturedImageEvent({capturedImageOpens:'crop'},recording),{selectId:recording.id,kind:'image'});
  assert.deepEqual(capturedImageEvent({capturedImageOpens:'preview'},recording),{selectId:recording.id,kind:'image'});
  assert.equal(capturedImageEvent({capturedImageOpens:'crop'},text),null);
  assert.equal(capturedImageEvent({capturedImageOpens:'crop'},null),null);
});
test('settings validation accepts only the known capture modes',()=>{
  assert.equal(settings({capturedImageOpens:'shelf'}).capturedImageOpens,'shelf');
  for(const mode of OPEN_MODES)assert.equal(settings({capturedImageOpens:mode}).capturedImageOpens,mode);
  assert.throws(()=>settings({capturedImageOpens:'explode'}),/Invalid preference/);
});
test('legacy openAfterScreenshot stores migrate without reopening opted-out captures',()=>{
  assert.equal(settings({openAfterScreenshot:false}).capturedImageOpens,'off');
  assert.equal(settings({openAfterScreenshot:true}).capturedImageOpens,'crop');
  assert.equal(settings({}).capturedImageOpens,'crop');
  assert.equal(settings({openAfterScreenshot:false},settings({openAfterScreenshot:false})).capturedImageOpens,'off');
  assert.equal(settings({capturedImageOpens:'preview'},settings({openAfterScreenshot:false})).capturedImageOpens,'preview');
});
