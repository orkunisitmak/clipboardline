'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {rejectRecordedSettings}=require('./shortcut-recording-acceptance.cjs');

test('native recorder exception fixture awaits the asynchronous state before sending its exact current token',async()=>{
 const commands=[];let resolveState;const state=new Promise(resolve=>{resolveState=resolve;});
 const output={result:{error:'Choose watched folders with the folder picker.'}};
 const pending=rejectRecordedSettings({state:()=>state,command:async(action,payload)=>{commands.push({action,payload});return output;}});
 await Promise.resolve();assert.deepEqual(commands,[]);resolveState({shortcutRecordingToken:'isolated-native-recorder-token'});assert.equal(await pending,output);
 assert.deepEqual(commands,[{action:'setSettings',payload:{recordingToken:'isolated-native-recorder-token',patch:{watchFolders:[]}}}]);
});

test('native recorder exception fixture rejects missing or invalid tokens before mutating settings',async()=>{
 for(const token of [undefined,null,'',7]){
  let called=false;await assert.rejects(()=>rejectRecordedSettings({state:async()=>({shortcutRecordingToken:token}),command:async()=>{called=true;}}),/active shortcut recorder token/);assert.equal(called,false);
 }
});

test('native recorder exception fixture does not issue a settings command if state retrieval fails',async()=>{
 let called=false;await assert.rejects(()=>rejectRecordedSettings({state:async()=>{throw new Error('Synthetic state failure');},command:async()=>{called=true;}}),/Synthetic state failure/);assert.equal(called,false);
});
