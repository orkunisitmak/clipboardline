'use strict';

// Only use before mouse.down(): ordinary state packets may replace a node while
// Playwright waits for stable geometry. A new locator resolves the current node.
async function preparePreGestureLocator(resolve,method,{timeout=3000,maxAttempts=8,now=()=>performance.now()}={}){
 if(!['scrollIntoViewIfNeeded','hover'].includes(method))throw new TypeError('Unsupported pre-gesture action');
 const deadline=now()+timeout;let lastError;
 const remaining=()=>{const value=deadline-now();if(value<=0)throw lastError||new Error('Pre-gesture readiness deadline expired');return value;};
 for(let attempt=0;attempt<maxAttempts;attempt++){
  try{
   const waitTimeout=remaining(),locator=resolve();await locator.waitFor({state:'visible',timeout:waitTimeout});await locator[method]({timeout:remaining()});return;
  }catch(error){
   const first=String(error?.message||'').split('\n',1)[0];
   if(error?.name==='TimeoutError'||!/(?:^|: )Element is (?:not attached to the DOM|detached from document)$/.test(first))throw error;
   lastError=error;if(attempt+1===maxAttempts||now()>=deadline)throw error;
  }
 }
 throw lastError||new Error('Pre-gesture readiness attempts exhausted');
}
module.exports={preparePreGestureLocator};
