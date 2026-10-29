'use strict';
// Linux has no signed update feed. Never instantiate the Windows updater here,
// including its cached manifests, announcements or download paths.
class ManualUpdates{
 constructor(_directory,{build,version,changed=()=>{}}={}){
  this.changed=changed;
  this.state={status:'manual',message:'Linux packages are updated manually from the project releases.',currentVersion:version,currentBuild:build,canInstall:false,busy:false};
 }
 set(value){this.state={...this.state,...value,status:'manual',canInstall:false,busy:false};this.changed();}
 check(){return Promise.resolve(this.state);}
 announce(){}
}
module.exports={ManualUpdates};
