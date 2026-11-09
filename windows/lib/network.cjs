'use strict';
const dns = require('node:dns').promises;
const net = require('node:net');
const http = require('node:http');
const https = require('node:https');
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
const asciiLetter = code => code >= 65 && code <= 90 || code >= 97 && code <= 122;
const isWhitespace = character => character === ' ' || character === '\t' || character === '\n' || character === '\r' || character === '\f';
function tagStart(html, at) {
  if (html[at] !== '<') return null;
  let start = at + 1, closing = false;
  if (html[start] === '/') { closing = true; start++; }
  if (!asciiLetter(html.charCodeAt(start))) return null;
  let end = start;
  while (asciiLetter(html.charCodeAt(end))) {
    end++;
    if (end - start > 6) return null;
  }
  if (!html[end] || !(isWhitespace(html[end]) || html[end] === '/' || html[end] === '>')) return null;
  const name = html.slice(start, end).toLowerCase();
  if (!['meta', 'title', 'script', 'style'].includes(name)) return null;
  return {name, closing, afterName: end};
}
function tagEnd(html, at) {
  let quote = '';
  for (let cursor = at; cursor < html.length; cursor++) {
    const character = html[cursor];
    if (quote) { if (character === quote) quote = ''; }
    else if (character === '"' || character === "'") quote = character;
    else if (character === '>') return cursor;
  }
  return -1;
}
function findClosing(html, name, from) {
  let cursor = from;
  while (cursor < html.length) {
    const opening = html.indexOf('<', cursor);
    if (opening < 0) return null;
    const tag = tagStart(html, opening);
    if (tag?.closing && tag.name === name) {
      const end = tagEnd(html, tag.afterName);
      return end < 0 ? null : {start: opening, end};
    }
    cursor = opening + 1;
  }
  return null;
}
function sanitizeHTML(html) {
  const output = [];
  let kept = 0, cursor = 0;
  while (cursor < html.length) {
    if (html.startsWith('<!--', cursor)) {
      const end = html.indexOf('-->', cursor + 4);
      output.push(html.slice(kept, cursor));
      if (end < 0) return output.join('');
      cursor = end + 3; kept = cursor; continue;
    }
    if (html[cursor] === '<') {
      const tag = tagStart(html, cursor);
      if (tag && !tag.closing && (tag.name === 'script' || tag.name === 'style')) {
        const openingEnd = tagEnd(html, tag.afterName);
        const close = openingEnd < 0 ? null : findClosing(html, tag.name, openingEnd + 1);
        output.push(html.slice(kept, cursor));
        if (!close) return output.join('');
        cursor = close.end + 1; kept = cursor; continue;
      }
    }
    cursor++;
  }
  output.push(html.slice(kept));
  return output.join('');
}
function attributes(html, start, end) {
  const result = {};
  let cursor = start;
  while (cursor < end) {
    while (cursor < end && (isWhitespace(html[cursor]) || html[cursor] === '/')) cursor++;
    const nameStart = cursor;
    while (cursor < end && !isWhitespace(html[cursor]) && !['=', '/', '>'].includes(html[cursor])) cursor++;
    if (cursor === nameStart) { cursor++; continue; }
    const name = html.slice(nameStart, cursor).toLowerCase();
    while (cursor < end && isWhitespace(html[cursor])) cursor++;
    if (html[cursor] !== '=') continue;
    cursor++;
    while (cursor < end && isWhitespace(html[cursor])) cursor++;
    if (cursor >= end) break;
    const quote = html[cursor] === '"' || html[cursor] === "'" ? html[cursor++] : '';
    const valueStart = cursor;
    if (quote) { while (cursor < end && html[cursor] !== quote) cursor++; }
    else { while (cursor < end && !isWhitespace(html[cursor]) && html[cursor] !== '>') cursor++; }
    if (['property', 'name', 'content'].includes(name) && cursor - valueStart <= 8192) result[name] = entities(html.slice(valueStart, cursor));
    if (quote && cursor < end) cursor++;
  }
  return result;
}
function extractMetadata(html) {
  const values = {};
  let title = '', metas = 0, cursor = 0;
  while (cursor < html.length) {
    const opening = html.indexOf('<', cursor);
    if (opening < 0) break;
    const tag = tagStart(html, opening);
    if (!tag || tag.closing) { cursor = opening + 1; continue; }
    if (tag.name === 'meta') {
      const end = tagEnd(html, tag.afterName);
      if (end < 0) break;
      if (metas++ < 256) {
        const parsed = attributes(html, tag.afterName, end);
        const key = String(parsed.property || parsed.name || '').toLowerCase();
        if (key && parsed.content !== undefined && values[key] === undefined) {
          values[key] = ['og:image:secure_url', 'og:image', 'twitter:image'].includes(key) ? parsed.content : parsed.content.slice(0, 2000);
        }
      }
      cursor = end + 1; continue;
    }
    if (tag.name === 'title' && !title) {
      const end = tagEnd(html, tag.afterName);
      const close = end < 0 ? null : findClosing(html, 'title', end + 1);
      if (!close) break;
      title = html.slice(end + 1, close.start);
      cursor = close.end + 1; continue;
    }
    cursor = opening + 1;
  }
  return {values, title};
}
function strippedTags(value, limit = 8192) {
  let output = '', cursor = 0;
  while (cursor < value.length && output.length < limit) {
    if (value[cursor] === '<') {
      const next = value[cursor + 1];
      const tagLike = asciiLetter(value.charCodeAt(cursor + 1)) || (next === '/' && asciiLetter(value.charCodeAt(cursor + 2))) || next === '!' || next === '?';
      if (tagLike) {
        const end = tagEnd(value, cursor + 1);
        if (end >= 0) { cursor = end + 1; continue; }
      }
      output += '<'; cursor++; continue;
    }
    const next = value.indexOf('<', cursor);
    const end = next < 0 ? value.length : next;
    output += value.slice(cursor, Math.min(end, cursor + limit - output.length));
    cursor = end;
  }
  return output;
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
    return {title: String(data.title || '').trim().slice(0, 500)||url.hostname, author: String(data.author_name || '').trim().slice(0, 200), thumbnail: typeof data.thumbnail_url==='string'?data.thumbnail_url:''};
  }
  const response = await fetcher(url.href); if (!/text\/html|application\/xhtml/i.test(response.type)) return {title: url.hostname};
  const html = decodeHTML(response.bytes, response.type);
  // Collapse layout whitespace only in display text; og:image stays a URL.
  const parsed = extractMetadata(sanitizeHTML(html)), metadata = parsed.values;
  const title = collapse(metadata['og:title'] || '') || collapse(metadata['twitter:title'] || '') || collapse(entities(strippedTags(parsed.title || ''))) || url.hostname;
  // Take the first image the thumbnail fetch would not refuse outright, so an HTTP secure_url does not hide a valid og:image.
  let thumbnail = '';
  for (const name of ['og:image:secure_url', 'og:image', 'twitter:image']) {
    const value = metadata[name] || ''; if (!value.trim()) continue;
    try { const image = new URL(value, response.url); metadataGuard(image); literalDestination(image); thumbnail = image.href; break; } catch {}
  }
  return {title: title.slice(0, 500), thumbnail};
}
module.exports = {publicAddress, publicURL, boundedFetch, metadataGuard,metadataFetch,thumbnailFetch,linkMetadata};
