'use strict';
const dns = require('node:dns').promises;
const net = require('node:net');
const http = require('node:http');
const https = require('node:https');
const graphemes = new Intl.Segmenter('en', {granularity: 'grapheme'});
// Cut on whole characters like Swift's String.prefix, never through a surrogate pair.
function prefix(text, count) { let out = '', n = 0; for (const {segment} of graphemes.segment(text)) { if (n++ === count) break; out += segment; } return out; }
function publicAddress(address) {
  if (address.startsWith('::ffff:')) return publicAddress(address.slice(7));
  if (net.isIP(address) === 4) {
    const p = address.split('.').map(Number); const [a,b,c] = p;
    return !(a === 0 || a === 10 || a === 127 || a >= 224 || (a === 100 && b >= 64 && b <= 127) ||
      (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31) ||
      (a === 192 && (b === 168 || b === 0 || (b === 88 && c === 99))) ||
      (a === 198 && (b === 18 || b === 19 || (b === 51 && c === 100))) || (a === 203 && b === 0 && c === 113));
  }
  if (net.isIP(address) === 6) {
    const halves=address.toLowerCase().split('::');let left=halves[0]?halves[0].split(':'):[],right=halves[1]?halves[1].split(':'):[];
    const expand=parts=>parts.flatMap(part=>part.includes('.')?(()=>{const bytes=part.split('.').map(Number);return[((bytes[0]<<8)|bytes[1]).toString(16),((bytes[2]<<8)|bytes[3]).toString(16)];})():[part]);
    left=expand(left);right=expand(right);const words=[...left,...Array(8-left.length-right.length).fill('0'),...right].map(value=>parseInt(value,16));
    return (words[0]&0xe000)===0x2000 && !(words[0]===0x2001&&((words[1]&0xfe00)===0||words[1]===0x0db8)) && words[0]!==0x2002 && !(words[0]===0x3fff&&(words[1]&0xf000)===0);
  }
  return false;
}
// Everything publicURL can refuse without a DNS lookup.
function literalDestination(url) {
  const host = url.hostname.replace(/^\[|\]$/g, '').toLowerCase();
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.port && !['80', '443'].includes(url.port) ||
      /(^localhost$|\.(local|internal|home|localhost|test|invalid)$)/.test(host)) throw new Error('Only public HTTP(S) destinations are allowed');
  if (net.isIP(host) && !publicAddress(host)) throw new Error('Private network destinations are blocked');
  return host;
}
async function publicURL(input, resolver = dns.lookup) {
  const url = new URL(input); const host = literalDestination(url);
  const addresses = net.isIP(host) ? [{address: host, family: net.isIP(host)}] : await resolver(host, {all: true, verbatim: true});
  if (!addresses.length || addresses.some(value => !publicAddress(value.address))) throw new Error('Private network destinations are blocked');
  return {url, address: addresses[0]};
}
async function boundedFetch(input, {maximum = 512 * 1024, redirects = 3, resolver, timeout = 8000, deadline, guard} = {}) {
  if(guard)guard(new URL(input));
  // `deadline` is a duration for the whole call chain: fix the end once, redirects get only what is left, DNS counts too.
  const end = deadline ? Date.now() + deadline : 0, remaining = () => end - Date.now(), expired = () => new Error('Network request timed out');
  let wait; const resolving = publicURL(input, resolver);
  const {url, address} = deadline ? await Promise.race([resolving, new Promise((_, fail) => { wait = setTimeout(() => fail(expired()), deadline); })]).finally(() => clearTimeout(wait)) : await resolving;
  if (deadline && remaining() <= 0) throw expired();
  return new Promise((resolve, reject) => {
    const request = (url.protocol === 'https:' ? https : http).get(url, {
      headers: {'User-Agent': 'ClipBoardLine/1.7.0', Accept: '*/*'},
      lookup: (_hostname, options, callback) => options.all ? callback(null, [address]) : callback(null, address.address, address.family),
      timeout
    }, response => {
      if ([301,302,303,307,308].includes(response.statusCode)) {
        response.resume(); if (!redirects || !response.headers.location) { reject(new Error('Too many redirects')); return; }
        let next; try { next = new URL(response.headers.location, url).href; } catch { reject(new Error('Invalid redirect location')); return; }
        const left = deadline && remaining(); if (deadline && left <= 0) { reject(expired()); return; }
        boundedFetch(next, {maximum, redirects: redirects - 1, resolver, timeout, deadline: left, guard}).then(resolve, reject); return;
      }
      if (response.statusCode !== 200 || Number(response.headers['content-length'] || 0) > maximum) { response.destroy(); reject(new Error('Remote response is unavailable or too large')); return; }
      const blocks = []; let length = 0;
      response.on('data', block => { length += block.length; if (length > maximum) { response.destroy(new Error('Response exceeds size limit')); } else blocks.push(block); });
      response.on('error', reject); response.on('end', () => resolve({bytes: Buffer.concat(blocks), url: url.href, type: String(response.headers['content-type'] || '')}));
    });
    request.on('timeout', () => request.destroy(new Error('Network request timed out'))); request.on('error', reject);
    // `timeout` is an idle-socket limit; a server dripping one byte per interval never trips it.
    if (deadline) { const timer = setTimeout(() => request.destroy(expired()), remaining()); request.once('close', () => clearTimeout(timer)); }
  });
}
function metadataGuard(url){
  if(url.protocol!=='https:')throw new Error('Automatic link metadata requires HTTPS.');
  // As on macOS, only named hosts are fetched: no IP literals and no trailing-dot hosts.
  if(net.isIP(url.hostname.replace(/^\[|\]$/g,''))||url.hostname.endsWith('.'))throw new Error('Automatic link metadata needs a named host.');
  const sensitive=new Set(['token','accesstoken','refreshtoken','idtoken','apikey','auth','authorization','authentication','authtoken','code','signature','sig','session','sessionid','state','password','secret','clientsecret','credential','credentials','accesskeyid','key','keypairid','policy','verifier','jwt','bearer']);
  for(const key of url.searchParams.keys()){const normalized=key.toLowerCase().replace(/[^a-z0-9]/g,'');if(/^(xamz|xgoog|oauth)/.test(normalized)||sensitive.has(normalized))throw new Error('Sensitive link parameters are not fetched automatically.');}
}
function metadataFetch(input,options={}){return boundedFetch(input,{deadline:20000,...options,guard:metadataGuard});}
function thumbnailFetch(input,options={}){return metadataFetch(input,{...options,maximum:5*1024*1024});}
const NAMED_ENTITIES = {amp:'&',quot:'"',lt:'<',gt:'>',apos:'\'',nbsp:' ',ccedil:'ç',Ccedil:'Ç',ouml:'ö',Ouml:'Ö',uuml:'ü',Uuml:'Ü',gbreve:'ğ',Gbreve:'Ğ',scedil:'ş',Scedil:'Ş',inodot:'ı',Idot:'İ',acirc:'â',icirc:'î',ucirc:'û',auml:'ä',Auml:'Ä',szlig:'ß',eacute:'é',Eacute:'É',egrave:'è',agrave:'à',aacute:'á',iacute:'í',oacute:'ó',uacute:'ú',ntilde:'ñ',ndash:'–',mdash:'—',hellip:'…',lsquo:'‘',rsquo:'’',ldquo:'“',rdquo:'”',laquo:'«',raquo:'»',bull:'•',middot:'·',copy:'©',reg:'®',trade:'™',euro:'€',pound:'£'};
const ENTITY = new RegExp(`&(?:#(\\d{1,7})|#[xX]([0-9a-fA-F]{1,6})|(${Object.keys(NAMED_ENTITIES).join('|')}));`, 'g');
// Titles such as "It&#8217;s" or "A&#x2F;B" must not show raw references.
// Invalid or control code points stay literal rather than injecting text.
const entities = value => value.replace(ENTITY, (match, decimal, hex, name) => {
  if (name) return NAMED_ENTITIES[name];
  const code = decimal ? Number(decimal) : parseInt(hex, 16);
  return code > 0x1f && code <= 0x10ffff && !(code >= 0x7f && code <= 0x9f) && !(code >= 0xd800 && code <= 0xdfff) ? String.fromCodePoint(code) : match;
});
// Turkish pages are often still windows-1254 / ISO-8859-9; encoding sniffing order: BOM, header, XML declaration (XHTML only), early <meta charset>.
function decodeHTML(bytes, type = '') {
  const head = bytes.subarray(0, 2048).toString('latin1'), known = label => { try { return new TextDecoder(label).encoding; } catch { return ''; } };
  // Encoding sniffing order: BOM, Content-Type charset parameter, XML declaration (XHTML), meta charset; unknown labels fall through.
  const declared = [...head.matchAll(/<meta[^>]*[\s"';]charset\s*=\s*["']?([\w.:-]+)/gi)].map(match => /^utf-16/i.test(match[1]) ? 'utf-8' : match[1]), label = [
    bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf ? 'utf-8' : '',
    /(?:^|;)\s*charset\s*=\s*["']?([\w.:-]+)/i.exec(type)?.[1],
    /application\/xhtml\+xml/i.test(type) ? /^\s*<\?xml[^>]*\sencoding\s*=\s*["']([\w.:-]+)/i.exec(head)?.[1] : '',
    // A meta declaration of UTF-16 cannot be true for ASCII-compatible markup; HTML treats it as UTF-8.
    ...declared
  ].map(value => value && known(value)).find(Boolean);
  if (label) return new TextDecoder(label).decode(bytes);
  try { return new TextDecoder('utf-8', {fatal: true}).decode(bytes); } catch { return new TextDecoder('windows-1252').decode(bytes); }
}
// Bidirectional marks, embeddings, overrides and isolates can reorder a title to spoof another one; joiners stay.
// As on macOS, drop control characters except whitespace (U+0085 counts as whitespace).
const collapse = value => value.replace(/[\u0000-\u0008\u000e-\u001f\u007f-\u0084\u0086-\u009f\u061C\u200E\u200F\u202A-\u202E\u2066-\u2069]/g, '').replace(/[\s\u0085]+/g, ' ').trim();
// Scans a start tag's attributes, honoring quoted values, until its closing '>'.
// An unquoted '<' or 4096 characters without '>' ends the attempt, so a page of
// unclosed tags costs linear work instead of a backtracking regex scan. A failed
// scan reports where it stopped, so callers can resume there instead of rescanning.
function tagAttributes(html, start) {
  let quote = '', index = start;
  for (const end = Math.min(html.length, start + 4096); index < end; index++) {
    const ch = html[index];
    if (quote) { if (ch === quote) quote = ''; }
    else if (ch === '"' || ch === "'") quote = ch;
    else if (ch === '>') return {ok: true, text: html.slice(start, index), end: index + 1};
    else if (ch === '<') break;
  }
  return {ok: false, end: index};
}
// Visits start tags in document order, skipping comments, script and style
// bodies and every tag's quoted attributes, so text inside them is never taken
// as a tag. An XHTML self-closing <script/> or <style/> has no body. Every
// cursor only moves forward, so the work stays linear. A value returned by
// visit ends the walk.
function walkTags(html, xhtml, visit) {
  const tokens = /<!--|<([a-z][\w:-]*)/gi; let match;
  while ((match = tokens.exec(html))) {
    if (match[0] === '<!--') { const end = html.indexOf('-->', tokens.lastIndex); if (end < 0) return; tokens.lastIndex = end + 3; continue; }
    const name = match[1].toLowerCase(), tag = tagAttributes(html, tokens.lastIndex); tokens.lastIndex = tag.end; if (!tag.ok) continue;
    if ((name === 'script' || name === 'style') && !(xhtml && tag.text.endsWith('/'))) { const end = new RegExp('</' + name + '\\s*>', 'gi'); end.lastIndex = tag.end; if (!end.exec(html)) return; tokens.lastIndex = end.lastIndex; continue; }
    const result = visit(name, tag); if (result !== undefined) return result;
  }
}
// Uses the first title whose closing tag follows within 2000 characters.
function documentTitle(html, xhtml) {
  const closing = /<\/title\s*>/gi; let close = null;
  return walkTags(html, xhtml, (name, tag) => {
    if (name !== 'title') return;
    if (!close || close.index < tag.end) { closing.lastIndex = tag.end; close = closing.exec(html); if (!close) return ''; }
    if (close.index - tag.end <= 2000) return html.slice(tag.end, close.index);
  }) || '';
}
function meta(html, name, xhtml) {
  return walkTags(html, xhtml, (tagName, tag) => {
    if (tagName !== 'meta') return;
    const attributes = {};
    for (const attr of tag.text.matchAll(/([A-Za-z_:][A-Za-z0-9_:.-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))/g)) attributes[attr[1].toLowerCase()] = attr[2] ?? attr[3] ?? attr[4];
    if ([attributes.property, attributes.name].some(key => String(key).toLowerCase() === name)) return entities(attributes.content || '');
  }) || '';
}
async function linkMetadata(input, fetcher = metadataFetch) {
  metadataGuard(new URL(input));
  const url = new URL(input); const youtube = /^(www\.|m\.|music\.)?youtube\.com$/.test(url.hostname) || url.hostname === 'youtu.be';
  if (youtube) {
    // As on macOS, ask oEmbed about the canonical host: a YouTube Music link is the same video.
    const video = new URL(url.href); if (video.hostname === 'music.youtube.com') video.hostname = 'www.youtube.com';
    const response = await fetcher('https://www.youtube.com/oembed?url=' + encodeURIComponent(video.href) + '&format=json', {maximum: 64 * 1024});
    const data = JSON.parse(response.bytes.toString('utf8'));
    if(!data||typeof data!=='object'||Array.isArray(data))return{title:url.hostname,author:'',thumbnail:''};
    return {title: prefix(String(data.title || '').trim(), 500)||url.hostname, author: prefix(String(data.author_name || '').trim(), 200), thumbnail: typeof data.thumbnail_url==='string'?data.thumbnail_url:''};
  }
  const response = await fetcher(url.href); if (!/text\/html|application\/xhtml/i.test(response.type)) return {title: url.hostname};
  const html = decodeHTML(response.bytes, response.type), xhtml = /application\/xhtml/i.test(response.type);
  // Collapse layout whitespace only in display text; og:image stays a URL.
  const title = collapse(meta(html, 'og:title', xhtml)) || collapse(meta(html, 'twitter:title', xhtml)) || collapse(entities(documentTitle(html, xhtml).replace(/<[^>]*>/g, ''))) || url.hostname;
  // Take the first image the thumbnail fetch would not refuse outright, so an HTTP secure_url does not hide a valid og:image.
  let thumbnail = '';
  for (const name of ['og:image:secure_url', 'og:image', 'twitter:image']) {
    const value = meta(html, name, xhtml); if (!value.trim()) continue;
    try { const image = new URL(value, response.url); metadataGuard(image); literalDestination(image); thumbnail = image.href; break; } catch {}
  }
  return {title: prefix(title, 500), thumbnail};
}
module.exports = {publicAddress, publicURL, boundedFetch, metadataGuard,metadataFetch,thumbnailFetch,linkMetadata};
