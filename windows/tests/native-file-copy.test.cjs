'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const os = require('node:os');
const {copyFiles} = require('../lib/native-files.cjs');

test('a source removed before native copy returns a rejected Promise, not a synchronous exception', {skip:process.platform!=='win32'}, async () => {
  const missing = path.join(os.tmpdir(), 'clipboardline-removed-copy-source-00000000.png');
  let promise;
  assert.doesNotThrow(() => {
    promise = copyFiles({files:[missing]});
  }, 'callers may attach a rejection handler for a removed file');
  assert.ok(promise instanceof Promise);
  await assert.rejects(promise, /unavailable/i);
});
