'use strict';
const {execFileSync}=require('node:child_process');
const fs=require('node:fs'),path=require('node:path');
if(process.platform!=='linux')throw new Error('Build the Linux helper on Linux.');
const directory=path.join(__dirname,'build');fs.mkdirSync(directory,{recursive:true});
execFileSync('cc',['-std=c11','-O2','-Wall','-Wextra','-Werror','-D_FORTIFY_SOURCE=2','-fstack-protector-strong',path.join(__dirname,'clipboard-monitor.c'),'-o',path.join(directory,'clipboardline-x11'),'-lX11','-lXfixes','-Wl,-z,relro,-z,now'],{stdio:'inherit'});
