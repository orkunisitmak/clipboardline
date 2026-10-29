'use strict';
const DIMENSIONS=512,SIDE=256;
function normalized(values){if(!values||values.length!==DIMENSIONS)return null;let sum=Math.fround(0);for(const value of values){if(!Number.isFinite(value))return null;sum=Math.fround(sum+Math.fround(value*value));}const norm=Math.sqrt(sum);if(!Number.isFinite(norm)||norm<=0)return null;return Float32Array.from(values,value=>value/norm);}
function score(query,vectors){if(!query||query.length!==DIMENSIONS||!query.every(Number.isFinite)||!Array.isArray(vectors)||!vectors.length||vectors.length>4)return null;let best=-Infinity;for(const vector of vectors){if(!vector||vector.length!==DIMENSIONS||!vector.every(Number.isFinite))return null;let sum=Math.fround(0);for(let i=0;i<DIMENSIONS;i++)sum=Math.fround(sum+Math.fround(query[i]*vector[i]));if(Number.isFinite(sum))best=Math.max(best,sum);}return Number.isFinite(best)?best:null;}
function rankedMatches(values){const scores=values.filter(value=>Number.isFinite(value.score)),best=Math.max(0,...scores.map(value=>value.score)),mean=scores.length?scores.reduce((sum,value)=>sum+value.score,0)/scores.length:0,spread=scores.length?Math.max(.01,Math.sqrt(scores.reduce((sum,value)=>sum+(value.score-mean)**2,0)/scores.length)):1;return scores.filter(value=>value.score>=Math.max(.22,best-.045)&&(scores.length<8||value.score>=.30||(value.score-mean)/spread>=1.25)).sort((a,b)=>b.score-a.score||a.id.localeCompare(b.id)).slice(0,200);}
function imageRegions(width,height){if(!Number.isInteger(width)||!Number.isInteger(height)||width<1||height<1||width>1024||height>1024)throw new Error('Invalid semantic image dimensions.');const long=Math.max(width,height),short=Math.min(width,height);if(short<120||long/short>4)return[];const views=[null];if(long/short>1.3){const tiles=Math.min(3,Math.ceil(long/short));for(let i=0;i<tiles;i++){const offset=(long-short)*i/(tiles-1);views.push({x:width>=height?offset:0,y:width>=height?0:offset,width:short,height:short});}}return views;}
function imageTensors(bitmap,width,height){
 if(!(bitmap instanceof Uint8Array)||bitmap.byteLength!==width*height*4)throw new Error('Invalid semantic image pixels.');
 return imageRegions(width,height).map(crop=>{
  const output=new Float32Array(3*SIDE*SIDE),scale=SIDE/Math.max(width,height),fit=crop?{x:0,y:0,width:SIDE,height:SIDE}:{x:(SIDE-width*scale)/2,y:(SIDE-height*scale)/2,width:width*scale,height:height*scale},region=crop||{x:0,y:0,width,height};
  for(let y=0;y<SIDE;y++)for(let x=0;x<SIDE;x++){
   const at=y*SIDE+x;if(x+.5<fit.x||x+.5>=fit.x+fit.width||y+.5<fit.y||y+.5>=fit.y+fit.height){output[at]=output[SIDE*SIDE+at]=output[2*SIDE*SIDE+at]=128/255;continue;}
   const fx=Math.max(0,Math.min(width-1,region.x+((x+.5-fit.x)/fit.width)*region.width-.5)),fy=Math.max(0,Math.min(height-1,region.y+((y+.5-fit.y)/fit.height)*region.height-.5)),x0=Math.floor(fx),y0=Math.floor(fy),x1=Math.min(width-1,x0+1),y1=Math.min(height-1,y0+1),dx=fx-x0,dy=fy-y0;
   const sample=channel=>{const a=bitmap[(y0*width+x0)*4+channel]*(1-dx)+bitmap[(y0*width+x1)*4+channel]*dx,b=bitmap[(y1*width+x0)*4+channel]*(1-dx)+bitmap[(y1*width+x1)*4+channel]*dx;return a*(1-dy)+b*dy;};
   const alpha=sample(3)/255;for(let channel=0;channel<3;channel++){const color=sample(2-channel);output[channel*SIDE*SIDE+at]=(color*alpha+128*(1-alpha))/255;}
  }return output;
 });
}
module.exports={DIMENSIONS,SIDE,normalized,score,rankedMatches,imageRegions,imageTensors};
