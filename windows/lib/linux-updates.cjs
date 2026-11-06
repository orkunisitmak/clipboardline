'use strict';
// Linux packages have no signed in-app channel yet. AppImage, .deb and .rpm
// installs are replaced by a newer package; checks never download or install.
const RELEASES='https://github.com/orkunisitmak/clipboardline/releases';
class ManualUpdates{
  constructor({version='0.0.0',build=0,changed=()=>{}}={}){this.changed=changed;this.manifest=null;this.state={status:'manual',message:'Install newer Linux releases as an AppImage, .deb or .rpm package.',error:null,checkedAt:null,lastAttemptAt:null,currentVersion:version,currentBuild:build,busy:false,canInstall:false,availableVersion:null,availableBuild:null,releasesURL:RELEASES};}
  set(state){this.state={...this.state,...state,busy:false,canInstall:false};try{this.changed();}catch{}}
  check(){return Promise.resolve(this.state);}
  announce(){}
  install(){return Promise.reject(new Error('Linux packages are updated by installing a newer release.'));}
}
module.exports={ManualUpdates,RELEASES};
