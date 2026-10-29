'use strict';
// electron-builder afterAllArtifactBuild hook. fpm 1.17 accepts
// --pacman-optional-depends but its .PKGINFO template reads a different
// attribute, so `optdepend` lines are never written. Add them here and keep
// the package's .MTREE integrity record for .PKGINFO consistent.
// Also usable directly: node scripts/pacman-optdepends.cjs <file.pacman>
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),crypto=require('node:crypto'),zlib=require('node:zlib');
const {execFileSync}=require('node:child_process');
const OPTIONAL=require('../package.json').clipboardLineLinux?.pacmanOptionalDepends||[];

function withOptionalDepends(pkginfo,optional){
 const lines=pkginfo.split('\n').filter(line=>!/^optdepend = /.test(line));
 let at=lines.reduce((last,line,index)=>/^depend = /.test(line)?index:last,-1);
 if(at<0)at=lines.reduce((last,line,index)=>/^\S+ = /.test(line)?index:last,lines.length-1);
 lines.splice(at+1,0,...optional.map(value=>'optdepend = '+value));
 return lines.join('\n');
}
function withPkginfoDigest(mtree,pkginfo){
 const digest=algorithm=>crypto.createHash(algorithm).update(pkginfo).digest('hex');
 let found=false;
 const text=mtree.split('\n').map(line=>{
  if(!line.startsWith('./.PKGINFO '))return line;found=true;
  return line.replace(/ size=\d+/,' size='+pkginfo.length).replace(/ md5digest=[0-9a-f]+/,' md5digest='+digest('md5')).replace(/ sha256digest=[0-9a-f]+/,' sha256digest='+digest('sha256'));
 }).join('\n');
 if(!found)throw new Error('.MTREE has no .PKGINFO entry.');
 return text;
}
function patch(file,optional=OPTIONAL){
 if(!optional.length)return false;
 const work=fs.mkdtempSync(path.join(os.tmpdir(),'clipboardline-pacman-'));
 try{
  execFileSync('bsdtar',['-xf',file,'-C',work,'.PKGINFO','.MTREE']);
  const pkginfo=Buffer.from(withOptionalDepends(fs.readFileSync(path.join(work,'.PKGINFO'),'utf8'),optional));
  const mtree=withPkginfoDigest(zlib.gunzipSync(fs.readFileSync(path.join(work,'.MTREE'))).toString('utf8'),pkginfo);
  fs.writeFileSync(path.join(work,'.PKGINFO'),pkginfo);fs.writeFileSync(path.join(work,'.MTREE'),zlib.gzipSync(mtree,{level:9}));
  // Metadata first (owned by root like the original), then every other entry
  // copied unchanged from the original archive without extracting it.
  const tar=path.join(work,'package.tar'),owner=['--uid','0','--gid','0','--uname','root','--gname','root'];
  execFileSync('bsdtar',['-cf',tar,'--format','pax',...owner,'-C',work,'.MTREE','.PKGINFO']);
  execFileSync('bsdtar',['-rf',tar,'--exclude','.MTREE','--exclude','.PKGINFO','@'+file]);
  const before=execFileSync('bsdtar',['-tf',file],{maxBuffer:64*1024*1024}).toString().split('\n').filter(Boolean).sort();
  const after=execFileSync('bsdtar',['-tf',tar],{maxBuffer:64*1024*1024}).toString().split('\n').filter(Boolean).sort();
  if(before.join('\n')!==after.join('\n'))throw new Error('Rebuilt pacman archive entries differ from the original.');
  execFileSync('xz',['-T0','-9','--check=crc64','-f',tar]);
  // The temporary folder may be another filesystem (tmpfs): copy beside the
  // package, then replace it atomically.
  fs.copyFileSync(tar+'.xz',file+'.tmp');fs.renameSync(file+'.tmp',file);
  return true;
 }finally{fs.rmSync(work,{recursive:true,force:true});}
}
module.exports=async function afterAllArtifactBuild(result){
 for(const file of result.artifactPaths||[])if(file.endsWith('.pacman')&&patch(file))console.log('  • added pacman optdepends  file='+path.relative(process.cwd(),file));
 return [];
};
module.exports.patch=patch;module.exports.withOptionalDepends=withOptionalDepends;module.exports.withPkginfoDigest=withPkginfoDigest;
if(require.main===module)for(const file of process.argv.slice(2))console.log(file+': '+(patch(path.resolve(file))?'optdepends added':'nothing to add'));
