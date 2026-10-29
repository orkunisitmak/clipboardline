'use strict';
const fs=require('node:fs');
const path=require('node:path');
const {Readable}=require('node:stream');

function mediaGenerationMatches(search,route,file){
 if(!search)return true; // Existing unversioned media URLs remain compatible.
 const requested=/^\?v=([a-f0-9]{64})$/.exec(search),managed=/^([a-f0-9]{64})\.(png|mp4|mov)$/.exec(path.basename(file));
 if(!requested||!managed||requested[1]!==managed[1])return false;
 if(route==='/video')return managed[2]==='mp4'||managed[2]==='mov';
 return (route===undefined||route==='/thumbnail')&&managed[2]==='png';
}

function byteRange(value,size){
 if(value==null)return{start:0,end:size-1,partial:false};
 if(typeof value!=='string'||value.length>100)return null;
 const match=/^bytes=(\d*)-(\d*)$/.exec(value);
 if(!match||(!match[1]&&!match[2]))return null;
 let start,end;
 if(!match[1]){const suffix=Number(match[2]);if(!Number.isSafeInteger(suffix)||suffix<=0)return null;start=Math.max(0,size-suffix);end=size-1;}
 else{start=Number(match[1]);end=match[2]?Number(match[2]):size-1;if(!Number.isSafeInteger(start)||!Number.isSafeInteger(end)||start<0||start>=size||end<start)return null;end=Math.min(end,size-1);}
 return{start,end,partial:true};
}

function mediaResponse(file,{mime='image/png',origin='null',range=null,Response:ResponseClass=globalThis.Response}={}){
 const stat=fs.lstatSync(file);if(!stat.isFile()||stat.isSymbolicLink()||!Number.isSafeInteger(stat.size)||stat.size<=0)throw new Error('Managed media unavailable.');
 const selected=byteRange(range,stat.size);
 const headers={'Content-Type':mime,'Cache-Control':'no-store','X-Content-Type-Options':'nosniff','Access-Control-Allow-Origin':origin,'Vary':'Origin','Accept-Ranges':'bytes'};
 if(!selected)return new ResponseClass(null,{status:416,headers:{...headers,'Content-Range':'bytes */'+stat.size,'Content-Length':'0'}});
 const {start,end,partial}=selected;
 headers['Content-Length']=String(end-start+1);
 if(partial)headers['Content-Range']=`bytes ${start}-${end}/${stat.size}`;
 return new ResponseClass(Readable.toWeb(fs.createReadStream(file,{start,end})),{status:partial?206:200,headers});
}
module.exports={byteRange,mediaResponse,mediaGenerationMatches};
