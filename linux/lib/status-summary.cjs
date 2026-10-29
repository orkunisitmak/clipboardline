'use strict';
const catalogs=require('../locales.js');
const KINDS=['image','text','link'];
function languageCode(value='system',systemLocale='en'){
 const code=String(value==='system'||!value?systemLocale:value);if(/^pt(?:-|$)/i.test(code))return'pt-BR';if(/^zh(?:-|$)/i.test(code))return'zh-Hans';const language=code.split('-')[0].toLowerCase();return Object.hasOwn(catalogs,language)?language:'en';
}
function translated(language,key,...values){let index=0;return(catalogs[language]?.[key]||catalogs.en[key]||key).replace(/%[@d]/g,()=>String(values[index++]??''));}
function statusSummary({items=[],settings={},updateVersion=null,systemLocale='en'}={}){
 const kinds=Array.isArray(settings.visibleKinds)&&settings.visibleKinds.length?new Set(settings.visibleKinds):new Set(KINDS),counts={image:0,text:0,link:0};
 for(const item of items)if(item&&!item.trashedAt&&!item.hiddenFromShelf&&kinds.has(item.kind)&&Object.hasOwn(counts,item.kind))counts[item.kind]++;
 const count=counts.image+counts.text+counts.link,badge=count>9?'9+':String(count),language=languageCode(settings.language,systemLocale),version=typeof updateVersion==='string'&&updateVersion?updateVersion:null;
 const description=count?translated(language,'%d images · %d texts · %d links on the line',counts.image,counts.text,counts.link):translated(language,'The line is empty');
 const update=version?translated(language,'Update available')+' · '+(version.length>28?version.slice(0,27)+'…':version):null;
 const tooltip=['ClipBoardLine',description,update].filter(Boolean).join('\n').slice(0,127);
 return Object.freeze({images:counts.image,texts:counts.text,links:counts.link,count,badge,language,description,tooltip,updateVersion:version,dim:count===0&&!version,highlight:!!version,iconKey:badge+':'+(count===0&&!version?'dim':'normal')+':'+!!version,menuKey:JSON.stringify([language,version]),key:JSON.stringify([counts.image,counts.text,counts.link,language,version])});
}
const GLYPHS=Object.freeze({
 '0':['111','101','101','101','111'],'1':['010','110','010','010','111'],'2':['111','001','111','100','111'],'3':['111','001','111','001','111'],'4':['101','101','111','001','001'],
 '5':['111','100','111','001','111'],'6':['111','100','111','101','111'],'7':['111','001','010','010','010'],'8':['111','101','111','101','111'],'9':['111','101','111','001','111'],'+':['000','010','111','010','000']
});
// NativeImage's tightly packed Windows BGRA data. Drawing is bounded to three
// tiny scale representations and never decodes clipboard images on the UI path.
function badgeBitmap(source,size,{badge,dim=false,highlight=false}){
 if(!Buffer.isBuffer(source)||source.length!==size*size*4||![16,32,48].includes(size)||!Object.hasOwn(GLYPHS,badge)&&badge!=='9+')throw new Error('Invalid tray artwork or badge.');
 const buffer=Buffer.from(source),scale=size/16,width=(badge.length===2?9:7)*scale,height=7*scale,left=size-width,top=size-height,radius=3*scale;
 const paint=(x,y,color)=>{const at=(y*size+x)*4;buffer[at]=color[2];buffer[at+1]=color[1];buffer[at+2]=color[0];buffer[at+3]=255;};
 const fill=highlight?[10,132,255]:[246,250,255],ink=highlight?[255,255,255]:[16,35,59];
 for(let y=top;y<size;y++)for(let x=left;x<size;x++){const cx=Math.max(left+radius,Math.min(x+.5,size-radius)),cy=Math.max(top+radius,Math.min(y+.5,size-radius));if((x+.5-cx)**2+(y+.5-cy)**2<=radius**2)paint(x,y,fill);}
 const textWidth=(badge.length*3+badge.length-1)*scale,startX=left+(width-textWidth)/2,startY=top+scale;
 for(const[index,glyph]of[...badge].entries())for(let y=0;y<5;y++)for(let x=0;x<3;x++)if(GLYPHS[glyph][y][x]==='1')for(let dy=0;dy<scale;dy++)for(let dx=0;dx<scale;dx++)paint(startX+index*4*scale+x*scale+dx,startY+y*scale+dy,ink);
 if(dim)for(let at=0;at<buffer.length;at++)buffer[at]=Math.round(buffer[at]*.45);
 return buffer;
}
function trayIcon(nativeImage,artwork,summary){
 const image=nativeImage.createEmpty();
 for(const scale of[1,2,3]){const size=16*scale,bitmap=artwork.resize({width:size,height:size,quality:'best'}).toBitmap();image.addRepresentation({scaleFactor:scale,width:size,height:size,buffer:badgeBitmap(bitmap,size,summary)});}
 return image;
}
class StatusTray{
 constructor({tray,createIcon,createMenu}){this.tray=tray;this.createIcon=createIcon;this.createMenu=createMenu;this.icons=new Map();this.current=null;this.image=null;this.menu=null;this.revision=0;this.imageRevision=0;this.menuRevision=0;}
 refresh(input){
  if(this.disposed||this.tray.isDestroyed?.())return false;
  const next=statusSummary(input);if(this.current?.key===next.key)return false;
  if(this.current?.iconKey!==next.iconKey){let image=this.icons.get(next.iconKey);if(!image){image=this.createIcon(next);this.icons.set(next.iconKey,image);if(this.icons.size>22)this.icons.delete(this.icons.keys().next().value);}this.tray.setImage(image);this.image=image;this.imageRevision++;}
  if(this.current?.tooltip!==next.tooltip)this.tray.setToolTip(next.tooltip);
  if(this.current?.menuKey!==next.menuKey){this.menu=this.createMenu(next);this.tray.setContextMenu(this.menu);this.menuRevision++;}
  this.current=next;this.revision++;return true;
 }
 dispose(){this.disposed=true;this.icons.clear();}
 snapshot(){return this.current?{...this.current,revision:this.revision,imageRevision:this.imageRevision,menuRevision:this.menuRevision,cachedIcons:this.icons.size}:null;}
}
module.exports={statusSummary,languageCode,translated,badgeBitmap,trayIcon,StatusTray};
