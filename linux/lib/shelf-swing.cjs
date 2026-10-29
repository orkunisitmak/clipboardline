'use strict';
// Cards hang from clothespins: they swing in when they arrive, sway as the
// line comes to rest and when the breeze passes, and nudge when copied. The
// springs are the Mac line's (PeggedView), sampled into compositor-only
// keyframes on the individual rotate/translate/opacity properties.
(function(scope){
 const ARRIVAL={angle:16,drop:46,swing:{stiffness:46,damping:2.6},fall:{stiffness:223.8,damping:21.5}};
 const NUDGE={rise:300,spring:{stiffness:38,damping:2.4}};
 const BREEZE={every:[7000,16000],angle:[1.6,3.4],delay:[0,350]},REVEAL={angle:[3,6],delay:[0,120]},COPIED=3;
 // Underdamped spring released from `from` at rest, until it stays within `rest`.
 function spring(from,{stiffness,damping,mass=1},{rest=0.05,step=1000/30}={}){
  const w0=Math.sqrt(stiffness/mass),zeta=damping/(2*Math.sqrt(stiffness*mass)),decay=zeta*w0;
  const wd=zeta<1?w0*Math.sqrt(1-zeta*zeta):0,b=wd?decay*from/wd:0;
  const at=t=>zeta<1?Math.exp(-decay*t)*(from*Math.cos(wd*t)+b*Math.sin(wd*t)):from*Math.exp(-w0*t)*(1+w0*t);
  const duration=Math.min(6000,Math.max(step,1000*Math.log(Math.max(Math.abs(from),rest)/rest*(1+Math.abs(b/(from||1))))/decay));
  const count=Math.max(2,Math.ceil(duration/step));
  return{duration,values:Array.from({length:count+1},(_value,index)=>index===count?0:at(index/count*duration/1000))};
 }
 // Ease out to `angle` (Mac: 0.3 s), then the spring brings the card back.
 function nudgeKeyframes(angle){
  const back=spring(angle,NUDGE.spring),total=NUDGE.rise+back.duration,frames=[];
  for(let index=0;index<=6;index++){const progress=index/6,eased=1-Math.pow(1-progress,3);frames.push({rotate:(angle*eased).toFixed(3)+'deg',offset:progress*NUDGE.rise/total});}
  back.values.forEach((value,index)=>{if(index)frames.push({rotate:value.toFixed(3)+'deg',offset:(NUDGE.rise+index/(back.values.length-1)*back.duration)/total});});
  frames[frames.length-1].offset=1;return{frames,duration:total};
 }
 function sampled(values,key,unit,duration){return{frames:values.map((value,index)=>({[key]:value.toFixed(3)+unit,offset:index/(values.length-1)})),duration};}
 class ShelfSwing{
  constructor({cards,motion,random=Math.random,schedule=(callback,ms)=>setTimeout(callback,ms),cancel=id=>clearTimeout(id),ready=()=>true}){
   this.cards=cards;this.motion=motion;this.random=random;this.schedule=schedule;this.cancelTimer=cancel;this.ready=ready;this.known=null;this.arrivals=new Set();this.breezeTimer=null;
  }
  get reduced(){return !!this.motion?.matches;}
  between([low,high]){return low+this.random()*(high-low);}
  play(element,frames,duration,delay=0){
   if(!element?.animate)return null;
   return element.animate(frames,{duration,delay,easing:'linear',composite:'replace'});
  }
  // Items new since the last snapshot swing in once their card is on screen.
  observe(ids){
   const current=new Set(ids);
   if(this.known)for(const id of current)if(!this.known.has(id))this.arrivals.add(id);
   for(const id of this.arrivals)if(!current.has(id))this.arrivals.delete(id);
   this.known=current;
  }
  arrive(element){
   if(this.reduced||!element)return;
   const swing=spring(ARRIVAL.angle,ARRIVAL.swing),fall=spring(-ARRIVAL.drop,ARRIVAL.fall);
   const rotate=sampled(swing.values,'rotate','deg',swing.duration),drop=sampled(fall.values,'translate','px',fall.duration);
   drop.frames=drop.frames.map(frame=>({translate:'0 '+frame.translate,offset:frame.offset}));
   this.play(element,rotate.frames,rotate.duration);this.play(element,drop.frames,drop.duration);
   this.play(element,[{opacity:0},{opacity:1}],Math.min(240,fall.duration));
  }
  nudge(element,angle,delay=0){
   if(this.reduced||!element)return;
   const {frames,duration}=nudgeKeyframes(angle);this.play(element,frames,duration,delay);
  }
  // The line comes to rest: arrivals swing in, every other card sways.
  revealed(){
   if(this.reduced)return;
   for(const element of this.cards()){
    const id=element.dataset?.itemId;
    if(id&&this.arrivals.delete(id))this.arrive(element);
    else this.nudge(element,this.between(REVEAL.angle)*(this.random()<0.5?-1:1),this.between(REVEAL.delay));
   }
  }
  // Arrivals captured while the line is already showing.
  arrived(){
   if(this.reduced||!this.ready())return;
   for(const element of this.cards()){const id=element.dataset?.itemId;if(id&&this.arrivals.delete(id))this.arrive(element);}
  }
  breeze(on){
   if(this.breezeTimer!==null){this.cancelTimer(this.breezeTimer);this.breezeTimer=null;}
   if(!on||this.reduced)return;
   this.breezeTimer=this.schedule(()=>{
    this.breezeTimer=null;
    if(this.ready())for(const element of this.cards())this.nudge(element,this.between(BREEZE.angle),this.between(BREEZE.delay));
    this.breeze(true);
   },this.between(BREEZE.every));
  }
 }
 const exports={ShelfSwing,spring,nudgeKeyframes,ARRIVAL,NUDGE,BREEZE,REVEAL,COPIED};
 if(typeof module==='object'&&module.exports)module.exports=exports;else scope.clipboardLineShelfSwing=exports;
})(typeof window==='object'?window:globalThis);
