'use strict';
// Renderer Date.now and main Date.now do not share a precision/clamping origin.
// Establish completion using the actual request/ack/hide events in one main
// process sequence instead of allowing a cross-clock timestamp tolerance.
function nativeCloseOrder({hidden,requests,acknowledgements,hides},rendererFinished){
 const request=requests.length===1&&requests[0].phase==='close'?requests[0]:null,ack=request&&acknowledgements.find(value=>value.token===request.token&&value.phase==='close'&&value.completed===true),hide=hides.length===1?hides[0]:null;
 const proof={requestToken:request?.token??null,requestSequence:request?.sequence??null,ackSequence:ack?.sequence??null,hideSequence:hide?.sequence??null,completed:ack?.completed===true,phase:ack?.phase??null};
 proof.hiddenOnlyAfterEnd=hidden===true&&rendererFinished===true&&[proof.requestToken,proof.requestSequence,proof.ackSequence,proof.hideSequence].every(value=>Number.isSafeInteger(value)&&value>0)&&proof.requestSequence<proof.ackSequence&&proof.ackSequence<proof.hideSequence;
 return proof;
}
module.exports={nativeCloseOrder};
