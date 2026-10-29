'use strict';
const {contextBridge,ipcRenderer} = require('electron');
contextBridge.exposeInMainWorld('clipboardLine',Object.freeze({
  diagnostics:()=>({sandboxed:process.sandboxed===true,contextIsolated:process.contextIsolated===true}),
  state:()=>ipcRenderer.invoke('clipboardline:state'),
  command:(action,payload={})=>ipcRenderer.invoke('clipboardline:command',action,payload),
  subscribeMotion:listener=>{if(typeof listener!=='function')throw new TypeError('Expected a listener');const wrapped=(_event,value)=>{if(!Number.isSafeInteger(value?.token)||!['prepare','open','close','reset'].includes(value.phase))return;Promise.resolve().then(()=>listener(value)).then(result=>ipcRenderer.send('clipboardline:shelf-motion-finished',{token:value.token,phase:value.phase,completed:result?.completed===true}),()=>ipcRenderer.send('clipboardline:shelf-motion-finished',{token:value.token,phase:value.phase,completed:false}));};ipcRenderer.on('clipboardline:shelf-motion',wrapped);return()=>ipcRenderer.removeListener('clipboardline:shelf-motion',wrapped);},
  subscribe:listener=>{ if(typeof listener!=='function')throw new TypeError('Expected a listener');const wrapped=(_event,state)=>listener(state);ipcRenderer.on('clipboardline:changed',wrapped);return()=>ipcRenderer.removeListener('clipboardline:changed',wrapped); }
}));
