'use strict';
// The rope reacts to weight, the same closed-form wave as macOS HangMotion
// (contracts/hang-motion.json): arrivals pull it down, removals let it spring
// back, and the ripple runs out to neighbouring cards. Idle shelves cost nothing.
(function(scope){
 const ROPE={arrivalAmplitude:6,removalAmplitude:-4,falloff:260,waveSpeed:1100,frequency:2.0,decay:5.5,lifetime:1.2,maximumDip:10,maximumChanges:3};
 const SWING={arrivalDegrees:10,stiffness:70,damping:7,breezeSpeed:1800,breezeMaximumDelay:0.6};
 const DROP={distance:-46,response:0.42,dampingFraction:0.82};
 function dip(x,time,plucks){
  let total=0;
  for(const pluck of plucks){const distance=Math.abs(x-pluck.x),age=time-pluck.time,tau=age-distance/ROPE.waveSpeed;if(tau<=0||age>ROPE.lifetime)continue;total+=pluck.amplitude*Math.exp(-distance/ROPE.falloff)*Math.exp(-ROPE.decay*tau)*Math.sin(2*Math.PI*ROPE.frequency*tau);}
  return Math.max(-ROPE.maximumDip,Math.min(ROPE.maximumDip,total));
 }
 // A unit-mass spring released from `from` at rest, as SwiftUI's interpolatingSpring.
 function spring(from,stiffness,damping,t){
  if(t<=0)return from;const gamma=damping/2,omega=Math.sqrt(Math.max(0,stiffness-gamma*gamma));
  return from*Math.exp(-gamma*t)*(Math.cos(omega*t)+gamma/omega*Math.sin(omega*t));
 }
 function swing(degrees,t){return spring(degrees,SWING.stiffness,SWING.damping,t);}
 function drop(t){const omega=2*Math.PI/DROP.response;return spring(DROP.distance,omega*omega,2*DROP.dampingFraction*omega,t);}
 function breezeDelay(x){return Math.max(0,Math.min(SWING.breezeMaximumDelay,x/SWING.breezeSpeed));}
 function diff(old,next){
  const before=new Set(old),after=new Set(next);
  const added=next.map((id,index)=>({id,index})).filter(item=>!before.has(item.id));
  const removed=old.map((id,index)=>({id,index})).filter(item=>!after.has(item.id));
  return added.length+removed.length>ROPE.maximumChanges||(!old.length&&!next.length)?{added:[],removed:[]}:{added,removed};
 }
 class HangRopes{
  constructor({reduceMotion,now=()=>performance.now()/1000,frame=callback=>requestAnimationFrame(callback)}){this.reduceMotion=reduceMotion;this.now=now;this.frame=frame;this.shelves=new Map();this.scheduled=false;}
  shelf(kind){if(!this.shelves.has(kind))this.shelves.set(kind,{ids:null,positions:new Map(),plucks:[],cards:new Map()});return this.shelves.get(kind);}
  // Called after every render with each visible shelf element.
  observe(element){
   const kind=element.dataset.shelf,shelf=this.shelf(kind),cards=[...element.querySelectorAll('.cards [data-item-id]')],ids=cards.map(card=>card.dataset.itemId),left=element.getBoundingClientRect().left;
   const positions=new Map(cards.map(card=>{const box=card.getBoundingClientRect();return[card.dataset.itemId,box.left-left+box.width/2];}));
   if(shelf.ids&&!this.reduceMotion()){const time=this.now(),{added,removed}=diff(shelf.ids,ids);
    for(const item of added){shelf.plucks.push({x:positions.get(item.id),time,amplitude:ROPE.arrivalAmplitude});shelf.cards.set(item.id,{arrived:time});}
    for(const item of removed)if(shelf.positions.has(item.id))shelf.plucks.push({x:shelf.positions.get(item.id),time,amplitude:ROPE.removalAmplitude});
    if(added.length||removed.length)this.schedule();}
   shelf.ids=ids;shelf.positions=positions;
  }
  // The shelves were revealed: one soft gust crosses each row from the left.
  breeze(){
   if(this.reduceMotion())return;const time=this.now();
   for(const shelf of this.shelves.values())for(const [id,x] of shelf.positions)shelf.cards.set(id,{...shelf.cards.get(id),gust:time+breezeDelay(x),degrees:1.6+Math.random()*0.8});
   this.schedule();
  }
  schedule(){if(this.scheduled)return;this.scheduled=true;this.frame(()=>this.tick());}
  tick(){
   this.scheduled=false;const time=this.now();let alive=false;
   for(const [kind,shelf] of this.shelves){
    shelf.plucks=shelf.plucks.filter(pluck=>time-pluck.time<=ROPE.lifetime);
    const element=document.querySelector(`.shelf[data-shelf="${kind}"]`);if(!element)continue;
    for(const card of element.querySelectorAll('.cards [data-item-id]')){
     const id=card.dataset.itemId,x=shelf.positions.get(id)??0,state=shelf.cards.get(id);let y=dip(x,time,shelf.plucks),tilt=0,live=false;
     if(state?.arrived!=null){const t=time-state.arrived;if(t<1.6){y+=drop(t);tilt+=swing(SWING.arrivalDegrees,t);card.style.opacity=String(Math.min(1,t/0.16));live=true;}else{delete state.arrived;card.style.opacity='';}}
     if(state?.gust!=null){const t=time-state.gust;if(t<0)live=true;else if(t<1.9){tilt+=t<0.3?state.degrees*(1-Math.pow(1-t/0.3,2)):swing(state.degrees,t-0.3);live=true;}else delete state.gust;}
     if(state&&!live)shelf.cards.delete(id);
     if(live||shelf.plucks.length){alive=true;card.style.translate=`0 ${y.toFixed(2)}px`;card.style.rotate=`${tilt.toFixed(2)}deg`;}
     else{card.style.translate='';card.style.rotate='';}
    }
    const path=element.querySelector('svg.rope path');if(path){if(!path.dataset.rest)path.dataset.rest=path.getAttribute('d');path.setAttribute('d',shelf.plucks.length?this.ropePath(element,shelf):path.dataset.rest);}
    if(shelf.plucks.length)alive=true;
   }
   if(alive)this.schedule();
  }
  ropePath(element,shelf){
   const width=Math.max(1,element.getBoundingClientRect().width),sag=Math.min(30,width*.018),time=this.now();let d='';
   for(let x=0;x<=width+8;x+=8){const px=Math.min(width,x),f=px/width,y=32+4*sag*f*(1-f)+dip(px,time,shelf.plucks);d+=(d?' L ':'M ')+(px/width*1000).toFixed(1)+' '+y.toFixed(2);}
   return d;
  }
 }
 const exports={ROPE,SWING,DROP,dip,spring,swing,drop,breezeDelay,diff,HangRopes};
 if(typeof module==='object'&&module.exports)module.exports=exports;else scope.clipboardLineHang=exports;
})(typeof window==='object'?window:globalThis);
