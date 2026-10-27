'use strict';
const {execFile}=require('node:child_process');
const crypto=require('node:crypto');
const {which}=require('./linux-clipboard.cjs');

// Linux focus and paste bridge. Window identity is read from the compositor
// (Hyprland, Sway, KDE via kdotool, X11 via xdotool). Sessions without an
// identity API, such as GNOME Wayland, use the compositor's own focus return
// after the shelves hide. Only window ids and process ids are retained.
const KEY_CTRL=29,KEY_V=47;
function exec(file,args,{timeout=4000}={}){
  return new Promise((resolve,reject)=>execFile(file,args,{timeout,maxBuffer:4*1024*1024},(error,stdout)=>error?reject(error):resolve(String(stdout))));
}
function session(environment=process.env){
  const desktop=String(environment.XDG_CURRENT_DESKTOP||'').toLowerCase();
  const wayland=!!environment.WAYLAND_DISPLAY||environment.XDG_SESSION_TYPE==='wayland';
  let compositor='other';
  if(environment.HYPRLAND_INSTANCE_SIGNATURE)compositor='hyprland';
  else if(environment.SWAYSOCK)compositor='sway';
  else if(desktop.includes('kde'))compositor='kde';
  else if(desktop.includes('gnome'))compositor='gnome';
  return{type:wayland?'wayland':environment.DISPLAY?'x11':'none',compositor};
}
function focusedSway(node){
  if(!node||typeof node!=='object')return null;
  if(node.focused&&Number.isInteger(node.pid))return node;
  for(const child of[...(node.nodes||[]),...(node.floating_nodes||[])]){const found=focusedSway(child);if(found)return found;}
  return null;
}
// paste-target.cjs accepts decimal handles. Map each backend id to a stable
// 63-bit decimal digest and keep the reverse mapping in this process.
function handleFor(id){return(BigInt('0x'+crypto.createHash('sha256').update(String(id)).digest('hex').slice(0,15))+1n).toString();}

class LinuxDesktop{
  constructor({environment=process.env,run=exec,find=name=>which(name,{environment}),sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms)),ownPID=process.pid}={}){
    this.environment=environment;this.run=run;this.find=find;this.sleep=sleep;this.ownPID=ownPID;this.session=session(environment);this.windows=new Map();
    this.cancelled=0;
  }
  windowBackend(){
    const{type,compositor}=this.session;
    if(compositor==='hyprland'&&this.find('hyprctl'))return'hyprland';
    if(compositor==='sway'&&this.find('swaymsg'))return'sway';
    if(type==='wayland'&&compositor==='kde'&&this.find('kdotool'))return'kdotool';
    if(type==='x11'&&this.find('xdotool'))return'xdotool';
    return null;
  }
  keyBackend(){
    const{type,compositor}=this.session;
    if(type==='x11'&&this.find('xdotool'))return'xdotool';
    if(type==='wayland'&&['hyprland','sway','other'].includes(compositor)&&this.find('wtype'))return'wtype';
    if(this.find('ydotool'))return'ydotool';
    if(type==='wayland'&&this.find('wtype'))return'wtype';
    return null;
  }
  async active(){
    const backend=this.windowBackend();
    if(backend==='hyprland'){const value=JSON.parse(await this.run('hyprctl',['-j','activewindow']));if(!value||typeof value.address!=='string'||!Number.isInteger(value.pid))return null;return{id:value.address,pid:value.pid};}
    if(backend==='sway'){const value=focusedSway(JSON.parse(await this.run('swaymsg',['-t','get_tree','-r'])));return value?{id:String(value.id),pid:value.pid}:null;}
    if(backend==='kdotool'||backend==='xdotool'){
      const id=(await this.run(backend,['getactivewindow'])).trim();if(!id||id.length>100)return null;
      const pid=Number((await this.run(backend,['getwindowpid',id])).trim());return Number.isInteger(pid)&&pid>0?{id,pid}:null;
    }
    return null;
  }
  identity(active,implicit=false){
    const handle=handleFor(implicit?'implicit:'+crypto.randomUUID():active.id);
    this.windows.set(handle,{...active,implicit});if(this.windows.size>64)this.windows.delete(this.windows.keys().next().value);
    // Linux exposes no portable editable/secure field state. The field is
    // trusted as the user's choice; password managers mark their own copies.
    return{handle,processId:implicit?1:active.pid,runtime:'0',editable:true,secure:false,backend:implicit?'implicit':this.windowBackend()};
  }
  async capture(){
    if(this.session.type==='none')return null;
    let active=null;try{active=await this.active();}catch{}
    if(active?.pid===this.ownPID)return null;
    if(active)return this.identity(active);
    return this.keyBackend()?this.identity({id:'implicit',pid:1},true):null;
  }
  target(value){
    const entry=value&&this.windows.get(value.handle);
    if(!entry)throw new Error('No previous application was captured.');
    return entry;
  }
  async activate(entry){
    const backend=this.windowBackend();
    if(entry.implicit||!backend)return;
    if(backend==='hyprland')await this.run('hyprctl',['dispatch','focuswindow','address:'+entry.id]);
    else if(backend==='sway')await this.run('swaymsg',[`[con_id=${Number(entry.id)}]`,'focus']);
    else if(backend==='xdotool')await this.run('xdotool',['windowactivate','--sync',entry.id]);
    else await this.run('kdotool',['windowactivate',entry.id]);
  }
  async verify(entry){
    if(entry.implicit)return;
    let active=null;try{active=await this.active();}catch{}
    if(!active)throw new Error('The previous application has closed.');
    if(active.id!==entry.id&&active.pid!==this.ownPID)throw new Error('Another window became active. Reopen the shelves from the intended field.');
  }
  async restore(value){const entry=this.target(value);await this.activate(entry);return{ok:true,mode:'Restore'};}
  async preparePaste(value){const entry=this.target(value);await this.verify(entry);return{ok:true,mode:'PreparePaste'};}
  async validatePaste(value){
    const entry=this.target(value),generation=this.cancelled;
    await this.activate(entry);
    // Let the compositor finish returning focus and the shortcut keys settle.
    await this.sleep(entry.implicit?180:90);
    if(generation!==this.cancelled)throw new Error('Paste canceled.');
    if(!entry.implicit){let active=null;try{active=await this.active();}catch{}if(!active||active.id!==entry.id)throw new Error('Focus changed before paste. No keys were sent.');}
    return{ok:true,mode:'ValidatePaste'};
  }
  async paste(value){
    const entry=this.target(value),generation=this.cancelled;
    if(!entry.implicit){let active=null;try{active=await this.active();}catch{}if(!active||active.id!==entry.id)throw new Error('Focus changed immediately before paste. No keys were sent.');}
    if(generation!==this.cancelled)throw new Error('Paste canceled.');
    const backend=this.keyBackend();
    if(backend==='xdotool')await this.run('xdotool',['key','--clearmodifiers','ctrl+v']);
    else if(backend==='wtype')await this.run('wtype',['-M','ctrl','v','-m','ctrl']);
    else if(backend==='ydotool')await this.run('ydotool',['key',`${KEY_CTRL}:1`,`${KEY_V}:1`,`${KEY_V}:0`,`${KEY_CTRL}:0`]);
    else throw new Error('Automatic paste needs xdotool (X11), wtype or ydotool (Wayland). The item was copied; paste it manually.');
    return{ok:true,mode:'Paste'};
  }
  cancel(){this.cancelled++;}
  diagnostics(){return{ok:true,platform:'linux',session:this.session.type,compositor:this.session.compositor,windowBackend:this.windowBackend(),keyBackend:this.keyBackend()};}
}
module.exports={LinuxDesktop,session,handleFor,focusedSway};
