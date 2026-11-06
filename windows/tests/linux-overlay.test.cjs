'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {OverlayFocus}=require('../lib/linux-overlay.cjs');

function clock(){
  const timers=new Map();let next=1;
  return{timers,schedule:(callback,delay)=>{const id=next++;timers.set(id,{callback,delay});return id;},cancel:id=>timers.delete(id),run(){const due=[...timers.entries()];timers.clear();for(const [,timer]of due)timer.callback();}};
}
test('a buried Wayland line is dismissed after focus loss, never when focus returns first',()=>{
  const time=clock(),focus=new OverlayFocus({delay:200,schedule:time.schedule,cancel:time.cancel});let dismissed=0;
  focus.blurred(()=>true,()=>dismissed++);assert.equal([...time.timers.values()][0].delay,200);
  time.run();assert.equal(dismissed,1);
  focus.blurred(()=>true,()=>dismissed++);focus.focused();time.run();assert.equal(dismissed,1,'a transient blur followed by focus keeps the line');
  focus.blurred(()=>false,()=>dismissed++);time.run();assert.equal(dismissed,1,'a reopen or hide in the meantime makes the blur stale');
  focus.blurred(()=>true,()=>dismissed++);focus.blurred(()=>true,()=>dismissed++);assert.equal(time.timers.size,1,'repeated blur keeps one pending check');time.run();assert.equal(dismissed,2);
});
test('file dialogs and drags hold the line; a blur during the hold is checked on release',()=>{
  const time=clock(),focus=new OverlayFocus({schedule:time.schedule,cancel:time.cancel});let dismissed=0,stillUnfocused=true;
  const dialog=focus.hold(),drag=focus.hold();
  focus.blurred(()=>stillUnfocused,()=>dismissed++);time.run();assert.equal(dismissed,0,'the portal dialog owns focus');
  dialog();dialog();assert.equal(focus.holds,1,'a release is counted once');assert.equal(time.timers.size,0,'another hold is still active');
  drag();assert.equal(time.timers.size,1);time.run();assert.equal(dismissed,1,'the drop target kept focus');
  const second=focus.hold();focus.blurred(()=>stillUnfocused,()=>dismissed++);focus.focused();second();assert.equal(time.timers.size,0,'focus returned before the dialog closed');
  stillUnfocused=false;const third=focus.hold();focus.blurred(()=>stillUnfocused,()=>dismissed++);third();time.run();assert.equal(dismissed,1);
});
