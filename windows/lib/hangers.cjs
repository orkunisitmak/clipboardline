'use strict';
// Thirty hangers shared by macOS and Windows. Each is drawn in a 40x40 box with
// the rope groove at y=12, so any size or lean pivots on the rope.
// `node scripts/generate-hangers.cjs` writes contracts/hangers.json and the Mac catalog from this file.
(function(scope){
function shade(hex, amount) {
  const n = parseInt(hex.slice(1), 16), f = c => Math.round(amount < 0 ? c * (1 + amount) : c + (255 - c) * amount);
  return '#' + [n >> 16, (n >> 8) & 255, n & 255].map(f).map(c => c.toString(16).padStart(2, '0')).join('');
}
const METAL = '#d7d9de', METAL_EDGE = '#8e9097';
function peg({ c, w = 11, h = 34, deco = '' }) {
  const x = 20 - w / 2, dark = shade(c, -0.3);
  return `<rect x="${x}" y="2" width="${w}" height="${h}" rx="${w * 0.32}" fill="${c}" stroke="${dark}" stroke-width=".6"/>`
    + `<rect x="${x + 1.3}" y="3.2" width="${w * 0.26}" height="${h - 3}" rx="1" fill="#fff" opacity=".28"/>`
    + `<rect x="${x}" y="11.2" width="${w}" height="1.6" fill="${shade(c, -0.45)}" opacity=".55"/>`
    + `<line x1="20" y1="${2 + h * 0.5}" x2="20" y2="${2 + h - 1}" stroke="${dark}" stroke-width=".8"/>`
    + `<rect x="${x - 1.4}" y="${2 + h * 0.42}" width="${w + 2.8}" height="3.4" rx="1.7" fill="${METAL}" stroke="${METAL_EDGE}" stroke-width=".5"/>` + deco;
}
const grain = '<path d="M17 5 q1 8 0 14 M23 7 q-1 7 0 12 M18.5 24 q.8 5 0 9" stroke="#7a4f2a" stroke-width=".5" fill="none" opacity=".55"/>';
const heart = col => `<path d="M20 31 l-3.6-3.6 a2.1 2.1 0 0 1 3.6-2.6 a2.1 2.1 0 0 1 3.6 2.6 z" fill="${col}"/>`;
const star = col => `<path d="M20 23.5 l1.3 2.7 3 .4 -2.2 2 .5 2.9 -2.6-1.4 -2.6 1.4 .5-2.9 -2.2-2 3-.4z" fill="${col}"/>`;
const flower = col => `<g fill="${col}">${[0, 72, 144, 216, 288].map(a => `<ellipse cx="20" cy="25.2" rx="1.5" ry="2.4" transform="rotate(${a} 20 28)"/>`).join('')}</g><circle cx="20" cy="28" r="1.4" fill="#ffd84d"/>`;
const dots = col => `<g fill="${col}"><circle cx="17.5" cy="7" r="1.1"/><circle cx="22.5" cy="16" r="1.1"/><circle cx="17.5" cy="24" r="1.1"/><circle cx="22.5" cy="30" r="1.1"/></g>`;
const stripes = col => `<g fill="${col}" opacity=".9"><rect x="14.5" y="6" width="11" height="2"/><rect x="14.5" y="23" width="11" height="2"/><rect x="14.5" y="29" width="11" height="2"/></g>`;
const bow = col => `<path d="M20 27 l-6-3.5 v7z M20 27 l6-3.5 v7z" fill="${col}"/><circle cx="20" cy="27" r="1.6" fill="${shade(col, -0.25)}"/>`;
function binder({ c }) {
  return `<path d="M13 13 L11 1.5 h18 L27 13" stroke="${METAL}" stroke-width="1.5" fill="none"/>`
    + `<path d="M9 14 h22 l-3 20 h-16z" fill="${c}" stroke="${shade(c, -0.35)}" stroke-width=".6"/>`
    + `<rect x="9" y="13" width="22" height="3" rx="1.2" fill="${shade(c, 0.25)}"/>`;
}
function bulldog({ c }) {
  return `<path d="M13 15 C11 5 29 5 27 15" stroke="${shade(c, -0.25)}" stroke-width="1.6" fill="none"/>`
    + `<rect x="10" y="13" width="20" height="19" rx="2.5" fill="${c}" stroke="${shade(c, -0.35)}" stroke-width=".6"/>`
    + `<rect x="9" y="11" width="22" height="4.5" rx="2.25" fill="${shade(c, 0.3)}" stroke="${shade(c, -0.3)}" stroke-width=".5"/>`
    + `<rect x="12" y="18" width="5" height="11" rx="1.5" fill="#fff" opacity=".25"/>`;
}
function paperclip({ c }) {
  return `<path d="M17.5 6 v22 a2.5 2.5 0 0 0 5 0 v-19 a4.5 4.5 0 0 0 -9 0 v22 a7 7 0 0 0 14 0 v-17" stroke="${c}" stroke-width="2" fill="none" stroke-linecap="round"/>`;
}
function button({ c }) {
  return peg({ c: shade(c, -0.1), w: 8, h: 30 })
    + `<circle cx="20" cy="9" r="7.5" fill="${c}" stroke="${shade(c, -0.3)}" stroke-width=".6"/><circle cx="17.8" cy="7" r="2" fill="#fff" opacity=".35"/>`
    + `<circle cx="18.3" cy="10" r=".9" fill="${shade(c, -0.45)}"/><circle cx="21.7" cy="10" r=".9" fill="${shade(c, -0.45)}"/>`;
}
function claw({ c }) {
  const teeth = Array.from({ length: 6 }, (_, i) => `<path d="M${10.5 + i * 3.8} 15 q1.9 9 0 17" stroke="${c}" stroke-width="2.4" fill="none" stroke-linecap="round"/>`).join('');
  return teeth + `<rect x="8" y="6" width="24" height="10" rx="5" fill="${c}" stroke="${shade(c, -0.3)}" stroke-width=".6"/><rect x="10" y="7.5" width="12" height="2.5" rx="1.2" fill="#fff" opacity=".3"/>`;
}
const HANGERS = [
  { name: 'Coral peg', draw: () => peg({ c: '#ff6b6b' }) },
  { name: 'Sky peg', draw: () => peg({ c: '#5ac8fa' }) },
  { name: 'Mint peg', draw: () => peg({ c: '#5fd4a4' }) },
  { name: 'Lemon peg', draw: () => peg({ c: '#ffd84d' }) },
  { name: 'Lavender slim peg', draw: () => peg({ c: '#a78bfa', w: 8 }) },
  { name: 'Pink slim peg', draw: () => peg({ c: '#ff7eb6', w: 8 }) },
  { name: 'Wooden peg', draw: () => peg({ c: '#c99a63', deco: grain }) },
  { name: 'Walnut peg', draw: () => peg({ c: '#8a5a35', deco: grain }) },
  { name: 'Orange mini peg', draw: () => peg({ c: '#ff9f0a', w: 9, h: 24 }) },
  { name: 'Teal mini peg', draw: () => peg({ c: '#2ec4b6', w: 9, h: 24 }) },
  { name: 'Heart peg', draw: () => peg({ c: '#ff9ac8', deco: heart('#e0245e') }) },
  { name: 'Star peg', draw: () => peg({ c: '#4d8bff', deco: star('#ffd84d') }) },
  { name: 'Flower peg', draw: () => peg({ c: '#9bc59d', deco: flower('#ffffff') }) },
  { name: 'Ladybird peg', draw: () => peg({ c: '#ff453a', deco: dots('#1c1c1e') }) },
  { name: 'Candy stripe peg', draw: () => peg({ c: '#f3e3c3', deco: stripes('#ff6b6b') }) },
  { name: 'Graphite binder', draw: () => binder({ c: '#3a3a3f' }) },
  { name: 'Blue binder', draw: () => binder({ c: '#4d8bff' }) },
  { name: 'Coral binder', draw: () => binder({ c: '#ff7a59' }) },
  { name: 'Steel bulldog', draw: () => bulldog({ c: '#b9bcc4' }) },
  { name: 'Brass bulldog', draw: () => bulldog({ c: '#d4a64a' }) },
  { name: 'Mint paperclip', draw: () => paperclip({ c: '#5fd4a4' }) },
  { name: 'Pink paperclip', draw: () => paperclip({ c: '#ff7eb6' }) },
  { name: 'Silver paperclip', draw: () => paperclip({ c: '#c9ccd2' }) },
  { name: 'Lemon button peg', draw: () => button({ c: '#ffd84d' }) },
  { name: 'Lilac button peg', draw: () => button({ c: '#c4a7ff' }) },
  { name: 'Pink claw', draw: () => claw({ c: '#ff9ac8' }) },
  { name: 'Tortoise claw', draw: () => claw({ c: '#9a6234' }) },
  { name: 'Bow peg', draw: () => peg({ c: '#5ac8fa', deco: bow('#ff7eb6') }) },
  { name: 'Wide peach peg', draw: () => peg({ c: '#ffb26b', w: 14 }) },
  { name: 'Wooden heart peg', draw: () => peg({ c: '#d8ae78', deco: grain + heart('#f3e3c3') }) }
];
const SVG=HANGERS.map(h=>`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 40" width="40" height="40">${h.draw()}</svg>`);
// A stable per-item draw: the same card keeps its hanger across launches.
function hangerFor(id){let h=2166136261;for(const c of String(id)){h^=c.charCodeAt(0);h=Math.imul(h,16777619)>>>0;}const a=h%HANGERS.length,b=(h>>>8)&255,c=(h>>>16)&255;return{index:a,size:0.82+b/255*0.4,lean:(c/255-0.5)*14};}
const exports={HANGERS:HANGERS.map((h,i)=>({name:h.name,svg:SVG[i]})),hangerFor,ROPE_Y:12,BOX:40};
if(typeof module==='object'&&module.exports)module.exports=exports;else scope.clipboardLineHangers=exports;
})(typeof window==='object'?window:globalThis);
