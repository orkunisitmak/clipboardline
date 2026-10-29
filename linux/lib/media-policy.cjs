'use strict';
const LOCAL_ORIGINS=new Set(['null','file://']);

// Electron44 serializes the installed local document as file://. Chromium can
// also serialize an opaque local origin as null. Never reflect arbitrary input.
function mediaOrigin({method,origin,initiator}){
  if(method!=='GET')return null;
  origin=origin||null;initiator=initiator||null;
  if(origin!==null&&!LOCAL_ORIGINS.has(origin)||initiator!==null&&!LOCAL_ORIGINS.has(initiator))return null;
  if(origin&&initiator&&origin!==initiator)return null;
  return origin||'null';
}
module.exports={mediaOrigin};
