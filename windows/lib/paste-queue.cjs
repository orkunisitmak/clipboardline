'use strict';

// Match macOS Line.pasteQueue: session-only and never persisted, so copied
// content stays out of preferences. The renderer sends ids oldest first.
class PasteQueue{
 constructor(){this.ids=[];}
 replace(ids){this.ids=[...ids];return this.ids.length;}
 // Items deleted or trashed after queueing are dropped so they cannot block the queue.
 next(available){while(this.ids.length&&!available(this.ids[0]))this.ids.shift();return this.ids[0]||null;}
 // Drops the head only if it is still the pasted item, so a queue replaced mid-paste is not shortened.
 complete(id){if(this.ids[0]===id)this.ids.shift();}
}
module.exports={PasteQueue};
