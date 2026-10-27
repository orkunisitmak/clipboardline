'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const https = require('node:https');
const net = require('node:net');
const {publicAddress, publicURL} = require('./network.cjs');

const MAXIMUM_UPLOAD_BYTES = 512 * 1024 * 1024;
const BLOCKED_SUFFIXES = ['local', 'localhost', 'internal', 'home', 'arpa', 'lan', 'corp', 'localdomain', 'onion', 'invalid'];
const EMPTY_PAYLOAD_HASH = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

function uriEncode(value) {
  const bytes = Buffer.from(String(value), 'utf8');
  let out = '';
  for (const byte of bytes) {
    const unreserved = (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) ||
      (byte >= 48 && byte <= 57) || byte === 45 || byte === 95 || byte === 46 || byte === 126;
    out += unreserved ? String.fromCharCode(byte) : '%' + byte.toString(16).toUpperCase().padStart(2, '0');
  }
  return out;
}

function sha256Hex(data) {
  return crypto.createHash('sha256').update(data).digest('hex');
}

function hmac(key, message) {
  return crypto.createHmac('sha256', key).update(message, 'utf8').digest();
}

function formatTimestamps(date) {
  const value = date instanceof Date ? date : new Date(date);
  const pad = n => String(n).padStart(2, '0');
  const dateStamp = `${value.getUTCFullYear()}${pad(value.getUTCMonth() + 1)}${pad(value.getUTCDate())}`;
  const amzDate = `${dateStamp}T${pad(value.getUTCHours())}${pad(value.getUTCMinutes())}${pad(value.getUTCSeconds())}Z`;
  return {amzDate, dateStamp};
}

function isPrintableASCII(value) {
  for (let i = 0; i < value.length; i++) {
    const code = value.charCodeAt(i);
    if (code < 0x21 || code > 0x7e) return false;
  }
  return true;
}

function isPublicHost(rawHost) {
  const lower = String(rawHost || '').replace(/^\[|\]$/g, '').toLowerCase();
  if (!lower || Buffer.byteLength(lower, 'utf8') > 253 || !lower.includes('.') || lower.endsWith('.')) return false;
  if (net.isIP(lower)) return publicAddress(lower);
  if (!/^[a-z0-9.-]+$/.test(lower)) return false;
  if (BLOCKED_SUFFIXES.some(suffix => lower === suffix || lower.endsWith('.' + suffix))) return false;
  const labels = lower.split('.');
  if (labels.some(label => !label || label.length > 63 || label.startsWith('-') || label.endsWith('-'))) return false;
  return /[a-z]/.test(labels[labels.length - 1]);
}

function parseEndpoint(raw) {
  const value = String(raw || '').trim();
  if (!value) throw new Error('Enter a valid Cloudflare R2 Account ID or HTTPS endpoint');
  if (value.includes('://')) {
    let url;
    try { url = new URL(value); } catch { throw new Error('Enter a valid Cloudflare R2 Account ID or HTTPS endpoint'); }
    if (url.protocol !== 'https:') throw new Error('Cloudflare R2 endpoint must use HTTPS');
    const host = url.hostname.toLowerCase();
    if (url.username || url.password || url.search || url.hash || (url.port && url.port !== '443') ||
        !isPublicHost(host) || (url.pathname && url.pathname !== '/')) {
      throw new Error('Enter a valid Cloudflare R2 Account ID or HTTPS endpoint');
    }
    return `https://${host}`;
  }
  const cleaned = value.toLowerCase();
  if (cleaned.length < 3 || cleaned.length > 96 || !/^[a-z0-9.-]+$/.test(cleaned) ||
      cleaned.startsWith('-') || cleaned.endsWith('-') || cleaned.startsWith('.') || cleaned.endsWith('.') ||
      cleaned.includes('..')) {
    throw new Error('Enter a valid Cloudflare R2 Account ID or HTTPS endpoint');
  }
  const host = cleaned.endsWith('.r2.cloudflarestorage.com') ? cleaned : `${cleaned}.r2.cloudflarestorage.com`;
  if (!isPublicHost(host)) throw new Error('Enter a valid Cloudflare R2 Account ID or HTTPS endpoint');
  return `https://${host}`;
}

function isValidBucket(bucket) {
  if (typeof bucket !== 'string' || bucket.length < 3 || bucket.length > 63 || bucket.includes('..')) return false;
  if (!/^[a-z0-9][a-z0-9.-]*[a-z0-9]$/.test(bucket)) return false;
  return net.isIP(bucket) === 0;
}

function parsePublicBaseUrl(raw) {
  const trimmed = String(raw || '').trim();
  if (!trimmed) throw new Error('Enter a valid HTTPS public base URL (for example, your r2.dev or custom domain)');
  let url;
  try { url = new URL(trimmed); } catch {
    throw new Error('Enter a valid HTTPS public base URL (for example, your r2.dev or custom domain)');
  }
  const host = url.hostname.toLowerCase();
  if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash ||
      (url.port && url.port !== '443') || !isPublicHost(host)) {
    throw new Error('Enter a valid HTTPS public base URL (for example, your r2.dev or custom domain)');
  }
  if (url.pathname && !isPrintableASCII(url.pathname)) {
    throw new Error('Enter a valid HTTPS public base URL (for example, your r2.dev or custom domain)');
  }
  const segments = url.pathname.split('/').filter(Boolean);
  if (segments.some(part => part === '.' || part === '..')) {
    throw new Error('Enter a valid HTTPS public base URL (for example, your r2.dev or custom domain)');
  }
  return segments.length ? `https://${host}/${segments.join('/')}` : `https://${host}`;
}

function normalizePrefix(raw) {
  const trimmed = String(raw || '').trim().replace(/^\/+|\/+$/g, '');
  if (!trimmed) return '';
  if (Buffer.byteLength(trimmed, 'utf8') > 128 || trimmed.includes('\\') || /[\u0000-\u001f\u007f-\u009f]/u.test(trimmed)) {
    throw new Error("Enter a valid key prefix without '..'");
  }
  const parts = trimmed.split('/');
  if (parts.some(part => !part || part === '.' || part === '..')) {
    throw new Error("Enter a valid key prefix without '..'");
  }
  return parts.join('/');
}

function validateR2Config(raw = {}) {
  const endpoint = parseEndpoint(raw.accountId ?? raw.r2AccountId ?? '');
  const accessKeyId = String(raw.accessKeyId ?? raw.r2AccessKeyId ?? '').trim();
  if (!accessKeyId || Buffer.byteLength(accessKeyId, 'utf8') > 128 || !isPrintableASCII(accessKeyId)) {
    throw new Error('Enter an R2 Access Key ID');
  }
  const bucket = String(raw.bucket ?? raw.r2Bucket ?? '').trim().toLowerCase();
  if (!isValidBucket(bucket)) throw new Error('Enter a valid R2 bucket name');
  const publicBaseUrl = parsePublicBaseUrl(raw.publicBaseUrl ?? raw.r2PublicBaseUrl ?? '');
  const keyPrefix = normalizePrefix(raw.keyPrefix ?? raw.r2KeyPrefix ?? '');
  return {endpoint, accessKeyId, bucket, publicBaseUrl, keyPrefix, region: 'auto'};
}

function isR2Configured(settings = {}, hasSecret = false) {
  if (!hasSecret) return false;
  try { validateR2Config(settings); return true; } catch { return false; }
}

function randomToken(length = 16) {
  const alphabet = '0123456789abcdefghijklmnopqrstuvwxyz';
  const count = Math.max(8, length);
  let out = '';
  for (let i = 0; i < count; i++) out += alphabet[crypto.randomInt(alphabet.length)];
  return out;
}

function makeObjectKey(prefix, token, fileExtension) {
  const ext = String(fileExtension || '').toLowerCase().replace(/^\.+|\.+$/g, '') || 'bin';
  const name = `${token}.${ext}`;
  return prefix ? `${prefix}/${name}` : name;
}

function contentTypeForExtension(ext) {
  switch (String(ext || '').toLowerCase().replace(/^\./, '')) {
    case 'png': return 'image/png';
    case 'jpg':
    case 'jpeg': return 'image/jpeg';
    case 'webp': return 'image/webp';
    case 'gif': return 'image/gif';
    case 'heic': return 'image/heic';
    case 'tif':
    case 'tiff': return 'image/tiff';
    case 'bmp': return 'image/bmp';
    case 'mp4': return 'video/mp4';
    case 'mov': return 'video/quicktime';
    case 'txt': return 'text/plain; charset=utf-8';
    default: return 'application/octet-stream';
  }
}

function publicObjectURL(baseUrl, objectKey) {
  const encodedKey = String(objectKey).split('/').filter(Boolean).map(uriEncode).join('/');
  const result = `${baseUrl}/${encodedKey}`;
  const parsed = new URL(result);
  if (parsed.protocol !== 'https:') {
    throw new Error('Enter a valid HTTPS public base URL (for example, your r2.dev or custom domain)');
  }
  return parsed.href;
}

function signR2Request({
  method,
  endpoint,
  pathSegments,
  queryItems = [],
  extraHeaders = {},
  payloadHash,
  accessKeyId,
  secretAccessKey,
  region = 'auto',
  service = 's3',
  date = new Date()
}) {
  const parsedEndpoint = new URL(endpoint);
  if (parsedEndpoint.protocol !== 'https:' || !parsedEndpoint.hostname) {
    throw new Error('Enter a valid Cloudflare R2 Account ID or HTTPS endpoint');
  }
  const host = parsedEndpoint.hostname.toLowerCase();
  const encodedPath = '/' + pathSegments.map(uriEncode).join('/');
  const encodedQuery = queryItems
    .map(([k, v]) => [uriEncode(k), uriEncode(v)])
    .sort((a, b) => (a[0] === b[0] ? (a[1] < b[1] ? -1 : a[1] > b[1] ? 1 : 0) : (a[0] < b[0] ? -1 : 1)))
    .map(([k, v]) => `${k}=${v}`)
    .join('&');
  const url = `https://${host}${encodedPath}${encodedQuery ? '?' + encodedQuery : ''}`;

  const {amzDate, dateStamp} = formatTimestamps(date);
  const headers = {
    host,
    'x-amz-content-sha256': payloadHash,
    'x-amz-date': amzDate
  };
  for (const [key, value] of Object.entries(extraHeaders)) {
    headers[key.toLowerCase()] = String(value).trim();
  }
  const sortedKeys = Object.keys(headers).sort();
  const canonicalHeaders = sortedKeys.map(key => `${key}:${headers[key]}\n`).join('');
  const signedHeaders = sortedKeys.join(';');
  const canonicalRequest = [
    method.toUpperCase(),
    encodedPath,
    encodedQuery,
    canonicalHeaders,
    signedHeaders,
    payloadHash
  ].join('\n');

  const credentialScope = `${dateStamp}/${region}/${service}/aws4_request`;
  const stringToSign = [
    'AWS4-HMAC-SHA256',
    amzDate,
    credentialScope,
    sha256Hex(Buffer.from(canonicalRequest, 'utf8'))
  ].join('\n');

  const kDate = hmac(Buffer.from('AWS4' + secretAccessKey, 'utf8'), dateStamp);
  const kRegion = hmac(kDate, region);
  const kService = hmac(kRegion, service);
  const kSigning = hmac(kService, 'aws4_request');
  const signature = hmac(kSigning, stringToSign).toString('hex');

  const wireHeaders = {};
  for (const key of sortedKeys) {
    if (key !== 'host') wireHeaders[key] = headers[key];
  }
  wireHeaders.Authorization = `AWS4-HMAC-SHA256 Credential=${accessKeyId}/${credentialScope}, SignedHeaders=${signedHeaders}, Signature=${signature}`;

  return {url, method: method.toUpperCase(), headers: wireHeaders, canonicalRequest, stringToSign};
}

function httpsR2Transport({resolver, timeout = 45000} = {}) {
  return async ({url: input, method, headers, body}) => {
    const {url, address} = await publicURL(input, resolver);
    if (url.protocol !== 'https:') throw new Error('Cloudflare R2 endpoint must use HTTPS');
    return new Promise((resolve, reject) => {
      const request = https.request(url, {
        method,
        headers,
        minVersion: 'TLSv1.2',
        lookup: (_hostname, options, callback) => options.all ? callback(null, [address]) : callback(null, address.address, address.family),
        timeout
      }, response => {
        const chunks = [];
        let length = 0;
        response.on('data', chunk => {
          length += chunk.length;
          if (length <= 256 * 1024) chunks.push(chunk);
        });
        response.on('error', () => reject(new Error('Cloudflare R2 connection failed')));
        response.on('end', () => resolve({status: response.statusCode || 0, body: Buffer.concat(chunks)}));
      });
      request.on('timeout', () => request.destroy(new Error('Cloudflare R2 connection failed')));
      request.on('error', () => reject(new Error('Cloudflare R2 connection failed')));
      if (body && body.length) request.write(body);
      request.end();
    });
  };
}

async function testR2Connection({config, secretAccessKey, transport = httpsR2Transport(), now = () => new Date()}) {
  const validated = config.endpoint ? config : validateR2Config(config);
  const secret = String(secretAccessKey || '').trim();
  if (!secret || Buffer.byteLength(secret, 'utf8') > 512 || !isPrintableASCII(secret)) {
    throw new Error('Enter an R2 Secret Access Key');
  }
  const signed = signR2Request({
    method: 'GET',
    endpoint: validated.endpoint,
    pathSegments: [validated.bucket],
    queryItems: [['list-type', '2'], ['max-keys', '1']],
    payloadHash: EMPTY_PAYLOAD_HASH,
    accessKeyId: validated.accessKeyId,
    secretAccessKey: secret,
    region: validated.region,
    date: now()
  });
  let response;
  try {
    response = await transport({url: signed.url, method: signed.method, headers: signed.headers, body: null});
  } catch {
    throw new Error('Cloudflare R2 connection failed');
  }
  if (response.status < 200 || response.status >= 300) {
    throw new Error(`Cloudflare R2 rejected the credentials or bucket (${response.status})`);
  }
}

async function uploadR2Object({
  config,
  secretAccessKey,
  data,
  fileExtension,
  token = randomToken(),
  transport = httpsR2Transport(),
  now = () => new Date()
}) {
  const buffer = Buffer.isBuffer(data) ? data : Buffer.from(data);
  if (buffer.length > MAXIMUM_UPLOAD_BYTES) throw new Error('File is too large to upload (512 MB limit)');
  const validated = config.endpoint ? config : validateR2Config(config);
  const secret = String(secretAccessKey || '').trim();
  if (!secret || Buffer.byteLength(secret, 'utf8') > 512 || !isPrintableASCII(secret)) {
    throw new Error('Enter an R2 Secret Access Key');
  }
  const objectKey = makeObjectKey(validated.keyPrefix, token, fileExtension);
  const publicUrl = publicObjectURL(validated.publicBaseUrl, objectKey);
  const pathSegments = [validated.bucket, ...objectKey.split('/').filter(Boolean)];
  const contentType = contentTypeForExtension(fileExtension);
  const signed = signR2Request({
    method: 'PUT',
    endpoint: validated.endpoint,
    pathSegments,
    extraHeaders: {'content-type': contentType, 'content-length': String(buffer.length)},
    payloadHash: sha256Hex(buffer),
    accessKeyId: validated.accessKeyId,
    secretAccessKey: secret,
    region: validated.region,
    date: now()
  });
  let response;
  try {
    response = await transport({url: signed.url, method: signed.method, headers: signed.headers, body: buffer});
  } catch {
    throw new Error('Cloudflare R2 connection failed');
  }
  if (response.status < 200 || response.status >= 300) {
    throw new Error(`Cloudflare R2 upload failed (${response.status})`);
  }
  return {objectKey, publicUrl};
}

class MemoryR2SecretStore {
  constructor(initial = '') { this.secret = initial ? String(initial) : ''; }
  hasSecret() { return this.secret.length > 0; }
  readSecret() { return this.secret || null; }
  saveSecret(value) {
    const trimmed = String(value || '').trim();
    if (!trimmed || Buffer.byteLength(trimmed, 'utf8') > 512 || !isPrintableASCII(trimmed)) {
      throw new Error('Enter an R2 Secret Access Key');
    }
    this.secret = trimmed;
  }
  clearSecret() { this.secret = ''; }
}

class FileR2SecretStore {
  constructor(directory, safeStorage) {
    this.directory = path.resolve(directory);
    this.file = path.join(this.directory, 'r2-secret.bin');
    this.safeStorage = safeStorage;
  }
  hasSecret() {
    try {
      const stat = fs.lstatSync(this.file);
      return stat.isFile() && !stat.isSymbolicLink() && stat.size > 0 && stat.size <= 8192;
    } catch { return false; }
  }
  readSecret() {
    if (!this.hasSecret()) return null;
    if (!this.safeStorage?.isEncryptionAvailable?.()) {
      throw new Error('Encrypted credential storage is unavailable on this system');
    }
    const stat = fs.lstatSync(this.file);
    if (!stat.isFile() || stat.isSymbolicLink()) throw new Error('Credential file must not be a symlink');
    const bytes = fs.readFileSync(this.file);
    const value = this.safeStorage.decryptString(bytes);
    if (!value || !isPrintableASCII(value)) throw new Error('Enter an R2 Secret Access Key');
    return value;
  }
  saveSecret(secret) {
    const trimmed = String(secret || '').trim();
    if (!trimmed || Buffer.byteLength(trimmed, 'utf8') > 512 || !isPrintableASCII(trimmed)) {
      throw new Error('Enter an R2 Secret Access Key');
    }
    if (!this.safeStorage?.isEncryptionAvailable?.()) {
      throw new Error('Encrypted credential storage is unavailable on this system');
    }
    if (fs.existsSync(this.file) && fs.lstatSync(this.file).isSymbolicLink()) {
      throw new Error('Credential file must not be a symlink');
    }
    const encrypted = this.safeStorage.encryptString(trimmed);
    const temporary = `${this.file}.tmp-${crypto.randomUUID()}`;
    let descriptor;
    try {
      descriptor = fs.openSync(temporary, 'wx', 0o600);
      fs.writeFileSync(descriptor, encrypted);
      fs.fsyncSync(descriptor);
      fs.closeSync(descriptor);
      descriptor = null;
      fs.renameSync(temporary, this.file);
    } finally {
      if (descriptor != null) fs.closeSync(descriptor);
      if (fs.existsSync(temporary)) fs.unlinkSync(temporary);
    }
  }
  clearSecret() {
    try {
      if (fs.existsSync(this.file)) {
        if (fs.lstatSync(this.file).isSymbolicLink()) throw new Error('Credential file must not be a symlink');
        fs.unlinkSync(this.file);
      }
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
  }
}

module.exports = {
  MAXIMUM_UPLOAD_BYTES,
  EMPTY_PAYLOAD_HASH,
  uriEncode,
  sha256Hex,
  formatTimestamps,
  normalizePrefix,
  validateR2Config,
  isR2Configured,
  randomToken,
  makeObjectKey,
  contentTypeForExtension,
  publicObjectURL,
  signR2Request,
  httpsR2Transport,
  testR2Connection,
  uploadR2Object,
  MemoryR2SecretStore,
  FileR2SecretStore
};
