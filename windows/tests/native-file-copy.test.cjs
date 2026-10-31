'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const os = require('node:os');
const {copyFiles} = require('../lib/native-files.cjs');

test('a source removed before native copy returns a rejected Promise, not a synchronous exception', async () => {
  const missing = path.join(os.tmpdir(), 'clipboardline-removed-copy-source-00000000.png');
  let promise;
  assert.doesNotThrow(() => {
    promise = copyFiles({files:[missing]});
  }, 'callers may attach a rejection handler for a removed file');
  assert.ok(promise instanceof Promise);
  await assert.rejects(promise, /unavailable/i);
});

// Windows PowerShell decodes piped stdin with the OEM code page unless told otherwise,
// so UTF-8 JSON paths/text with non-ASCII characters (Turkish usernames) arrived mangled.
test('every native helper decodes its UTF-8 JSON stdin as UTF-8', async () => {
  const fs = require('node:fs');
  if (process.platform !== 'win32') return;
  const {MediaJobs} = require('../lib/media.cjs');
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'clipboardline-utf8-'));
  try {
    const source = path.join(directory, 'kayıt şğü.mp4');
    fs.writeFileSync(source, Buffer.alloc(64));
    const jobs = new MediaJobs({directory: path.join(directory, 'jobs')});
    // A mangled path fails the helper's existence check at the Input stage;
    // the correct path reaches the (invalid) media decoder instead.
    await assert.rejects(jobs.probe(source), {code: 'MEDIA_UNSUPPORTED_OR_FAILED', stage: 'Decode'});
    jobs.dispose();
  } finally { fs.rmSync(directory, {recursive: true, force: true}); }
});

test('file copy resolves an existing file whose name is not ASCII', async () => {
  const fs = require('node:fs');
  if (process.platform !== 'win32') return;
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'clipboardline-utf8-copy-'));
  try {
    const source = path.join(directory, 'kayıt şğü.png');
    fs.writeFileSync(source, Buffer.from('89504e470d0a1a0a', 'hex'));
    // A mangled path made the helper's Get-Item fail, so the copy rejected as unavailable.
    await copyFiles({files: [source]});
  } finally { fs.rmSync(directory, {recursive: true, force: true}); }
});
