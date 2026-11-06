'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const os = require('node:os');
const {copyFiles} = require('../lib/native-files.cjs');

// Copy helpers write the real Windows clipboard. Only its text can be put back:
// other formats do not outlive the PowerShell process that would read them.
function clipboard(command, file) {
  require('node:child_process').execFileSync('powershell.exe', ['-NoProfile', '-STA', '-NonInteractive', '-Command', command], {windowsHide: true, env: {...process.env, CLIPBOARD_FILE: file}});
}
async function restoringClipboard(directory, run) {
  const saved = path.join(directory, 'clipboard-before.txt');
  clipboard('[IO.File]::WriteAllText($env:CLIPBOARD_FILE,[string](Get-Clipboard -Raw))', saved);
  try { await run(); } finally {
    clipboard('$t=[IO.File]::ReadAllText($env:CLIPBOARD_FILE);if($t){Set-Clipboard -Value $t}else{Add-Type -AssemblyName System.Windows.Forms;[Windows.Forms.Clipboard]::Clear()}', saved);
  }
}

// The Windows file helper; Linux copies file lists through lib/linux-native.cjs.
test('a source removed before native copy returns a rejected Promise, not a synchronous exception', {skip:process.platform!=='win32'}, async () => {
  const missing = path.join(os.tmpdir(), 'clipboardline-removed-copy-source-00000000.png');
  let promise;
  assert.doesNotThrow(() => {
    promise = copyFiles({files:[missing]});
  }, 'callers may attach a rejection handler for a removed file');
  assert.ok(promise instanceof Promise);
  await assert.rejects(promise, /unavailable/i);
});

// Windows PowerShell decodes piped stdin with the OEM code page unless told otherwise,
// so UTF-8 JSON paths/text with non-ASCII characters (non-ASCII usernames) arrived mangled.
test('the media helper decodes its UTF-8 JSON stdin as UTF-8', async () => {
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
    await restoringClipboard(directory, () => copyFiles({files: [source]}));
  } finally { fs.rmSync(directory, {recursive: true, force: true}); }
});

test('image copy keeps a path and clipboard text that are not ASCII', async () => {
  const fs = require('node:fs');
  if (process.platform !== 'win32') return;
  const native = require('../lib/native.cjs');
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'clipboardline-utf8-image-'));
  try {
    const source = path.join(directory, 'kayıt şğü.png'), text = 'şğü ıİ', copied = path.join(directory, 'copied.txt');
    fs.writeFileSync(source, Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==', 'base64'));
    await restoringClipboard(directory, async () => {
      await native.copyImages({files: [source], marker: Buffer.from('marker').toString('base64'), text});
      clipboard('[IO.File]::WriteAllText($env:CLIPBOARD_FILE,[string](Get-Clipboard -Raw))', copied);
    });
    assert.equal(fs.readFileSync(copied, 'utf8'), text);
  } finally { fs.rmSync(directory, {recursive: true, force: true}); }
});
