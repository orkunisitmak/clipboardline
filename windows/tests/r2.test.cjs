'use strict';
const {test} = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {
  sha256Hex,
  validateR2Config,
  isR2Configured,
  makeObjectKey,
  signR2Request,
  httpsR2Transport,
  testR2Connection,
  uploadR2Object,
  MemoryR2SecretStore,
  FileR2SecretStore
} = require('../lib/r2.cjs');
const {Store} = require('../lib/model.cjs');

const png = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==',
  'base64'
);

test('SigV4 signer matches the cross-platform reference vector byte-for-byte', () => {
  const body = Buffer.from('hello r2\n', 'utf8');
  const payloadHash = sha256Hex(body);
  assert.equal(
    payloadHash,
    ['a0455c221b23d13d', 'f3054c5ab80a86ed', '34443655930de1fb', '35dd96f9c13569cf'].join('')
  );

  const signed = signR2Request({
    method: 'PUT',
    endpoint: 'https://test-account.r2.cloudflarestorage.com',
    pathSegments: ['test-bucket', 'clips', 'sample0123456789.txt'],
    extraHeaders: {'Content-Type': 'text/plain; charset=utf-8', 'Content-Length': String(body.length)},
    payloadHash,
    accessKeyId: 'test-access-key',
    secretAccessKey: 's'.repeat(24),
    date: new Date('2026-10-27T12:00:00Z')
  });

  assert.equal(signed.url, 'https://test-account.r2.cloudflarestorage.com/test-bucket/clips/sample0123456789.txt');
  const expectedRequestDigest = ['1ec28a5bd48cdd64', '277f9dfa59a6e9c7', 'a1ca2378a7b32948', '8eda15c920be8b44'].join('');
  assert.equal(
    signed.stringToSign,
    `AWS4-HMAC-SHA256\n20261027T120000Z\n20261027/auto/s3/aws4_request\n${expectedRequestDigest}`
  );
  const expectedSig = ['6b74abc012176dcf', '41459c106469d48d', 'd1ca9fb42c11fcf4', '409c90097dcd927c'].join('');
  assert.equal(
    signed.headers.Authorization,
    `AWS4-HMAC-SHA256 Credential=test-access-key/20261027/auto/s3/aws4_request, SignedHeaders=content-length;content-type;host;x-amz-content-sha256;x-amz-date, Signature=${expectedSig}`
  );
});

test('R2 config validation normalizes safe values and rejects insecure or private endpoints', () => {
  const valid = validateR2Config({
    r2AccountId: 'test-account',
    r2AccessKeyId: 'test-access-key',
    r2Bucket: 'My-Clips',
    r2PublicBaseUrl: 'https://cdn.example.com/public/',
    r2KeyPrefix: '/2026/oct/'
  });
  assert.equal(valid.endpoint, 'https://test-account.r2.cloudflarestorage.com');
  assert.equal(valid.bucket, 'my-clips');
  assert.equal(valid.publicBaseUrl, 'https://cdn.example.com/public');
  assert.equal(valid.keyPrefix, '2026/oct');
  assert.equal(makeObjectKey(valid.keyPrefix, 'tok123', '.PNG'), '2026/oct/tok123.png');
  assert.equal(isR2Configured({
    r2AccountId: 'test-account',
    r2AccessKeyId: 'test-access-key',
    r2Bucket: 'my-clips',
    r2PublicBaseUrl: 'https://cdn.example.com'
  }, true), true);
  assert.equal(isR2Configured({
    r2AccountId: 'test-account',
    r2AccessKeyId: 'test-access-key',
    r2Bucket: 'my-clips',
    r2PublicBaseUrl: 'https://cdn.example.com'
  }, false), false);

  const userInfoEndpoint = 'https://' + 'u' + ':' + 'p@s3.example.com';
  for (const badEndpoint of ['http://s3.example.com', 'https://localhost', 'https://127.0.0.1', 'https://10.0.0.5', 'https://192.168.1.1', userInfoEndpoint]) {
    assert.throws(() => validateR2Config({
      r2AccountId: badEndpoint,
      r2AccessKeyId: 'test-access-key',
      r2Bucket: 'my-clips',
      r2PublicBaseUrl: 'https://cdn.example.com',
      r2KeyPrefix: ''
    }));
  }
  for (const badBucket of ['ab', 'my_clips', 'bad..bucket', '-clips', '192.168.1.1']) {
    assert.throws(() => validateR2Config({
      r2AccountId: 'test-account',
      r2AccessKeyId: 'test-access-key',
      r2Bucket: badBucket,
      r2PublicBaseUrl: 'https://cdn.example.com',
      r2KeyPrefix: ''
    }));
  }
  assert.throws(() => validateR2Config({
    r2AccountId: 'test-account',
    r2AccessKeyId: 'test-access-key',
    r2Bucket: 'my-clips',
    r2PublicBaseUrl: 'http://cdn.example.com',
    r2KeyPrefix: ''
  }));
  assert.throws(() => validateR2Config({
    r2AccountId: 'test-account',
    r2AccessKeyId: 'test-access-key',
    r2Bucket: 'my-clips',
    r2PublicBaseUrl: 'https://cdn.example.com',
    r2KeyPrefix: 'clips/../secret'
  }));
});

test('HTTPS transport blocks private DNS resolution before opening a connection', async () => {
  const transport = httpsR2Transport({
    resolver: async () => [{address: '10.0.0.8', family: 4}]
  });
  await assert.rejects(
    () => transport({url: 'https://s3.example.com/my-clips', method: 'GET', headers: {}, body: null}),
    /Private network destinations are blocked/i
  );
});

test('testR2Connection and uploadR2Object sign S3 requests and handle HTTP errors', async () => {
  const calls = [];
  let status = 200;
  const transport = async req => {
    calls.push(req);
    return {status, body: Buffer.alloc(0)};
  };
  const config = validateR2Config({
    r2AccountId: 'test-account',
    r2AccessKeyId: 'test-access-key',
    r2Bucket: 'test-bucket',
    r2PublicBaseUrl: 'https://cdn.example.com',
    r2KeyPrefix: 'clips'
  });
  const secret = 's'.repeat(24);
  const fixedDate = new Date('2026-10-27T12:00:00Z');

  await testR2Connection({config, secretAccessKey: secret, transport, now: () => fixedDate});
  assert.equal(calls.length, 1);
  assert.equal(calls[0].method, 'GET');
  assert.equal(calls[0].url, 'https://test-account.r2.cloudflarestorage.com/test-bucket?list-type=2&max-keys=1');

  const uploaded = await uploadR2Object({
    data: Buffer.from('clipboard note', 'utf8'),
    fileExtension: 'txt',
    token: 'tok0000000000001',
    config,
    secretAccessKey: secret,
    transport,
    now: () => fixedDate
  });
  assert.equal(uploaded.objectKey, 'clips/tok0000000000001.txt');
  assert.equal(uploaded.publicUrl, 'https://cdn.example.com/clips/tok0000000000001.txt');
  assert.equal(calls.length, 2);
  assert.equal(calls[1].method, 'PUT');
  assert.equal(calls[1].headers['content-type'], 'text/plain; charset=utf-8');

  status = 403;
  await assert.rejects(() => testR2Connection({config, secretAccessKey: secret, transport, now: () => fixedDate}), /403/);
  await assert.rejects(() => uploadR2Object({
    data: Buffer.from('fail', 'utf8'),
    fileExtension: 'txt',
    token: 'tok0000000000002',
    config,
    secretAccessKey: secret,
    transport,
    now: () => fixedDate
  }), /403/);
});

test('FileR2SecretStore encrypts via safeStorage, never writes plaintext, and rejects symlinks', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'clipboardline-r2-secret-'));
  try {
    const mask = crypto.randomBytes(32);
    const fakeSafeStorage = {
      isEncryptionAvailable: () => true,
      encryptString: plain => {
        const src = Buffer.from(plain, 'utf8');
        return Buffer.from(src.map((byte, idx) => byte ^ mask[idx % mask.length]));
      },
      decryptString: buf => {
        const out = Buffer.from(buf.map((byte, idx) => byte ^ mask[idx % mask.length]));
        return out.toString('utf8');
      }
    };
    const store = new FileR2SecretStore(dir, fakeSafeStorage);
    const secretValue = 'z'.repeat(24);
    assert.equal(store.hasSecret(), false);
    store.saveSecret(secretValue);
    assert.equal(store.hasSecret(), true);
    const onDisk = fs.readFileSync(store.file);
    assert.equal(onDisk.includes(Buffer.from(secretValue, 'utf8')), false);
    assert.equal(store.readSecret(), secretValue);
    store.clearSecret();
    assert.equal(store.hasSecret(), false);

    const target = path.join(dir, 'outside.bin');
    fs.writeFileSync(target, 'x');
    fs.symlinkSync(target, store.file);
    assert.equal(store.hasSecret(), false);
    assert.throws(() => store.saveSecret(secretValue), /symlink/i);
  } finally {
    fs.rmSync(dir, {recursive: true, force: true});
  }
});

test('Store records uploadedUrl, preserves it on identical recapture, invalidates on content edits, and never persists secrets', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'clipboardline-r2-store-'));
  let now = 1000;
  try {
    const store = new Store(dir, {clock: () => now});
    store.modify('setSettings', {
      patch: {
        r2AccountId: 'test-account',
        r2AccessKeyId: 'test-access-key',
        r2Bucket: 'test-bucket',
        r2PublicBaseUrl: 'https://cdn.example.com',
        r2KeyPrefix: 'clips'
      }
    });
    const secrets = new MemoryR2SecretStore('w'.repeat(24));
    assert.equal(fs.readFileSync(store.file, 'utf8').includes(secrets.readSecret()), false);

    const text = store.insert('text', 'Original text');
    store.modify('recordUpload', {id: text.id, url: 'https://cdn.example.com/clips/one.txt'});
    assert.equal(store.item(text.id).uploadedUrl, 'https://cdn.example.com/clips/one.txt');

    // Identical recapture preserves uploadedUrl.
    now = 2000;
    const recaptured = store.insert('text', 'Original text');
    assert.equal(recaptured.id, text.id);
    assert.equal(store.item(text.id).uploadedUrl, 'https://cdn.example.com/clips/one.txt');

    // Renaming/notes keep uploadedUrl; changing text clears it.
    store.modify('details', {id: text.id, name: 'Pinned note', notes: 'Extra context', text: 'Original text'});
    assert.equal(store.item(text.id).uploadedUrl, 'https://cdn.example.com/clips/one.txt');
    store.modify('editText', {id: text.id, text: 'Mutated text'});
    assert.equal(store.item(text.id).uploadedUrl, undefined);

    // Image markup save invalidates uploadedUrl.
    const image = store.insert('image', png);
    store.modify('recordUpload', {id: image.id, url: 'https://cdn.example.com/clips/img.png'});
    assert.equal(store.item(image.id).uploadedUrl, 'https://cdn.example.com/clips/img.png');
    store.modify('saveImage', {
      id: image.id,
      dataUrl: 'data:image/png;base64,' + png.toString('base64'),
      crop: {x: 0, y: 0, width: 1, height: 1},
      annotations: [{type: 'rectangle', x: 0, y: 0, width: 1, height: 1}]
    });
    assert.equal(store.item(image.id).uploadedUrl, undefined);
  } finally {
    fs.rmSync(dir, {recursive: true, force: true});
  }
});
