'use strict';
class OcrQueue {
 constructor({enabled=()=>true,closing=()=>false,process=async()=>{},schedule=work=>setImmediate(work)}={}){
  this.items=[];this.head=0;this.pending=new Set();this.enabled=enabled;this.closing=closing;this.process=process;this.schedule=schedule;this.indexing=false;
 }
 enqueue(id){
  if(this.closing()||!this.enabled()||this.pending.has(id))return false;
  this.items.push(id);this.pending.add(id);this.drainSoon();return true;
 }
 dequeue(){
  if(this.head>=this.items.length)return undefined;
  const id=this.items[this.head++];this.pending.delete(id);
  if(this.head>=64&&this.head*2>=this.items.length){this.items=this.items.slice(this.head);this.head=0;}
  return id;
 }
 discardPending(){this.items=[];this.head=0;this.pending.clear();}
 get size(){return this.items.length-this.head;}
 drainSoon(){
  if(this.indexing||!this.size||!this.enabled()||this.closing())return;
  this.indexing=true;this.schedule(()=>this.drain());
 }
 async drain(){
  try{
   while(this.size&&!this.closing()){
    const id=this.dequeue();
    if(!this.enabled())continue;
    try{await this.process(id);}catch{}
   }
  }finally{
   this.indexing=false;
   if(this.size&&this.enabled()&&!this.closing())this.drainSoon();
  }
 }
}
function createOcrQueue(options){
 const queue=new OcrQueue(options);
 return {queue,queueOCR:id=>queue.enqueue(id)};
}
module.exports={OcrQueue,createOcrQueue};

