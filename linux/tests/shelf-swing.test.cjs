'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {ShelfSwing,spring,nudgeKeyframes,ARRIVAL,BREEZE}=require('../lib/shelf-swing.cjs');

const card=id=>({dataset:{itemId:id},played:[],animate(frames,options){this.played.push({frames,options});return{};}});
function harness({reduced=false,ready=true}={}){
  const cards=[card('a'),card('b'),card('c')],timers=[];
  const swing=new ShelfSwing({cards:()=>cards,motion:{matches:reduced},random:()=>0.5,schedule:(callback,ms)=>{timers.push({callback,ms});return timers.length;},cancel:id=>{timers[id-1].canceled=true;},ready:()=>ready});
  return{swing,cards,timers};
}
test('springs settle from the Mac line amplitudes and end exactly at rest',()=>{
  const arrival=spring(ARRIVAL.angle,ARRIVAL.swing);
  assert.equal(arrival.values[0],16);assert.equal(arrival.values.at(-1),0);assert.ok(Math.min(...arrival.values)<-5,'the card swings past the pin');
  assert.ok(arrival.duration>3000&&arrival.duration<=6000,'a slow, lazy swing like the Mac');
  const nudge=nudgeKeyframes(3);assert.equal(nudge.frames[0].rotate,'0.000deg');assert.equal(nudge.frames[6].rotate,'3.000deg');assert.deepEqual(nudge.frames.at(-1),{rotate:'0.000deg',offset:1});
  assert.ok(nudge.frames.every((frame,index,frames)=>!index||frame.offset>=frames[index-1].offset));
});
test('only items new since the first snapshot swing in; the rest sway as the line comes to rest',()=>{
  const {swing,cards}=harness();
  swing.observe(['a','b']);assert.equal(swing.arrivals.size,0,'the opening library is not an arrival');
  swing.observe(['a','b','c']);assert.deepEqual([...swing.arrivals],['c']);
  swing.revealed();
  const [a,,c]=cards;
  assert.equal(a.played.length,1);assert.equal(a.played[0].frames[6].rotate,'4.500deg','reveal sway between 3 and 6 degrees');assert.equal(a.played[0].options.delay,60);
  assert.equal(c.played.length,3,'an arrival swings, drops and fades in');
  assert.equal(c.played[0].frames[0].rotate,'16.000deg');assert.equal(c.played[1].frames[0].translate,'0 -46.000px');assert.deepEqual(c.played[2].frames,[{opacity:0},{opacity:1}]);
  assert.equal(swing.arrivals.size,0);swing.revealed();assert.equal(c.played.length,4,'an arrival plays once');
  swing.observe(['a','b']);swing.observe(['a','b','c']);swing.observe(['a','b']);assert.equal(swing.arrivals.size,0,'a removed item is no longer pending');
});
test('arrivals while the line is open play at once; the breeze repeats only while it is shown',()=>{
  const {swing,cards,timers}=harness();
  swing.observe(['a']);swing.observe(['a','b']);swing.arrived();assert.equal(cards[1].played.length,3);
  swing.breeze(true);assert.equal(timers[0].ms,(BREEZE.every[0]+BREEZE.every[1])/2);
  timers[0].callback();assert.ok(cards.every(element=>element.played.at(-1).frames[6].rotate==='2.500deg'));assert.equal(timers.length,2,'the next gust is scheduled');
  swing.breeze(false);assert.equal(timers[1].canceled,true);
});
test('reduced motion and a busy line keep every card still',()=>{
  const reduced=harness({reduced:true});reduced.swing.observe(['a']);reduced.swing.observe(['a','b']);reduced.swing.revealed();reduced.swing.arrived();reduced.swing.breeze(true);reduced.swing.nudge(reduced.cards[0],3);
  assert.ok(reduced.cards.every(element=>!element.played.length));assert.equal(reduced.timers.length,0);
  const busy=harness({ready:false});busy.swing.observe(['a']);busy.swing.observe(['a','c']);busy.swing.arrived();busy.swing.breeze(true);busy.timers[0].callback();
  assert.ok(busy.cards.every(element=>!element.played.length),'no gust or arrival while moving, dragging or hidden');assert.equal(busy.swing.arrivals.size,1,'the arrival waits for the line');
});
