'use strict';
const path=require('node:path');
// A Windows PowerShell 5.1 helper must not inherit PowerShell 7's module search
// path (GitHub runners launch npm from pwsh). It can select incompatible Core
// security/utility modules, or a user module with the same trusted name.
function windowsEnvironment(environment=process.env){
  const clean={...environment};for(const key of Object.keys(clean))if(key.toLowerCase()==='psmodulepath')delete clean[key];
  clean.PSModulePath=path.win32.join(environment.SystemRoot||environment.SYSTEMROOT||'C:\\Windows','System32','WindowsPowerShell','v1.0','Modules');return clean;
}
module.exports={windowsEnvironment};
