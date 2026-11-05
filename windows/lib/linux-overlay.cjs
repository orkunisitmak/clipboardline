'use strict';
// Wayland gives clients no keep-above or skip-taskbar request, so activating
// another application buries the full-screen shelf window while it still
// counts as shown: the next toggle hides an invisible line and a reopen skips
// the slide. Dismiss the line when it loses focus instead, as a launcher would,
// except while its own file dialog or drag holds focus.
class OverlayFocus {
 constructor({delay=200,schedule=setTimeout,cancel=clearTimeout}={}){this.delay=delay;this.schedule=schedule;this.cancelTimer=cancel;this.holds=0;this.pending=null;this.timer=null;}
 hold(){
  this.holds++;let released=false;
  return()=>{if(released)return;released=true;this.holds--;if(!this.holds&&this.pending)this.arm();};
 }
 blurred(check,dismiss){this.pending={check,dismiss};this.arm();}
 focused(){this.pending=null;this.disarm();}
 arm(){
  this.disarm();
  this.timer=this.schedule(()=>{
   this.timer=null;if(this.holds||!this.pending)return;
   const {check,dismiss}=this.pending;this.pending=null;if(check())dismiss();
  },this.delay);
 }
 disarm(){if(this.timer!==null){this.cancelTimer(this.timer);this.timer=null;}}
}
module.exports={OverlayFocus};
