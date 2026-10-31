'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const catalogs = require('../locales.js');
const { languageCode, translated } = require('../lib/status-summary.cjs');

const renderer = fs.readFileSync(path.join(__dirname, '../renderer.js'), 'utf8');
const windowsMain = fs.readFileSync(path.join(__dirname, '../main.cjs'), 'utf8');
const rendererTranslationKeys = [...renderer.matchAll(/\bt\(\s*(['"])((?:\\.|(?!\1)[^\\])*?)\1\s*\)/g)].map(match => {
  const value = match[1] === "'" ? match[2].replace(/\\'/g, "'") : match[2];
  return JSON.parse(`"${value.replace(/"/g, '\\"')}"`);
});
const swiftDirectory = path.join(__dirname, '../../Sources/Tendedero');
const swiftFiles = fs.readdirSync(swiftDirectory).filter(file => file.endsWith('.swift'));
const swiftTranslationKeys = new Set(swiftFiles.flatMap(file => {
  const source = fs.readFileSync(path.join(swiftDirectory, file), 'utf8');
  return [...source.matchAll(/\bL\(\s*"((?:\\.|[^"\\])*)"/g)].map(match => match[1]);
}));
const windowsRuntimeErrorKeys = [...new Set([
  windowsMain,
  ...fs.readdirSync(path.join(__dirname, '../lib'))
    .filter(file => file.endsWith('.cjs'))
    .map(file => fs.readFileSync(path.join(__dirname, '../lib', file), 'utf8'))
].flatMap(source => [...source.matchAll(/new Error\('([^']*)'\)/g)].map(match => match[1])))];
const locales = ['az', 'en', 'es', 'fr', 'ja', 'ko', 'pt-BR', 'tr', 'zh-Hans'];

const settingsText = [
  'Settings',
  'General',
  'Sources',
  'History',
  'Keyboard shortcuts',
  'Updates',
  'About',
  'Language',
  'System language',
  'Colors',
  'Soft colors',
  'Neutral glass',
  'Card size',
  'Small',
  'Medium',
  'Large',
  'Open after screenshot',
  'Focus the captured image immediately so Enter and Space work.',
  'Sounds',
  'Launch at login',
  'Images',
  'Texts',
  'Links',
  'Capture copied images',
  'Capture copied text',
  'Text copies never open the shelves automatically.',
  'Capture copied links',
  'A standalone URL becomes a link; paragraphs remain text.',
  'Fetch link titles and thumbnails',
  'Optional network access to the linked public website or YouTube.',
  'Recognize text in new images',
  'On-device OCR indexes new images for search.',
  'Watch image folders',
  'Add folder',
  'External originals stay in place.',
  'Private clipboard markers are ignored. YouTube/site metadata may contact the public linked website; OCR runs locally.'
];

const actionPaletteCopy = [
  'Search this Library view',
  'Select an item first.',
  'Restore this item first.',
  'Select a still image first.',
  'Select an image first.',
  'Select a text item first.',
  'Select a link first.',
  'Start editing text first.',
  'Nothing to undo.',
  'Available in Library.',
  'Available on the shelves.',
  'Browse selected items',
  'Open Library first.',
  'Select an item in Trash first.',
  'Select one item first.',
  'Select an annotation first.',
  'No annotations to clear.',
  'Start image markup first.',
  'No update available.',
  'Nothing to redo.'
];

const windowsRuntimeMessages = [
  'Image unavailable',
  'Select an editable field in another application, then reopen the shelves.',
  'Paste canceled by another browsing action.',
  'Select a regular file.',
  'Recording exceeds the 2 GB import limit.',
  'The recording changed while importing.',
  'File exceeds import limit',
  'Text file exceeds import limit',
  'Unsupported image file',
  'Screen capture is unavailable',
  'OCR requires a still image',
  'Recognizing image text locally…',
  'Image changed during recognition',
  'Focus the shortcut recorder before recording.',
  'Select an available recording.',
  'The recording changed. Reopen its preview before trimming.',
  'Choose a nonempty interval within this recording.',
  'Video operation canceled.',
  'Link unavailable',
  'Image text ready',
  'Images, recordings and text',
  'ClipBoardLine update available',
  'ClipBoardLine %@ is ready. Click to review and install.',
  'ClipBoardLine could not start',
  'Imported %d · failed %d. %@: %@',
  'Shortcuts %@ are unavailable. %@',
  'Could not restore: %@.',
  'Working previous shortcuts are kept.',
  'Choose another combination in Settings.',
  'The image could not be opened.',
  'Enable link metadata in Sources before refreshing link previews.',
  'Offline image search is unavailable.',
  'No text found in this image.',
  'Recognized text copied',
  'Choose watched folders with the folder picker.',
  'Updates use a public, cryptographically signed Windows channel.',
  'ClipBoardLine %@ is available.',
  'Update check failed: %@',
  'Downloading verified update…',
  'Verified update is ready to install.',
  'Update download failed: %@',
  'Check for a signed update first',
  'Installing update and reopening ClipBoardLine…',
  'Update installation failed: %@',
  'Development builds use a separate library. Install an official release to use its signed update channel.',
  'Development builds cannot install official updates.',
  'Windows installer can run only on Windows.',
  'Installer integrity check failed',
  'Permanent deletion is incomplete. %@ Retry cleanup in Settings.',
  'Clipboard capture: %@',
  'Link preview could not be refreshed: %@',
  '%@ Falling back to bounded clipboard polling.'
];

const translatedLabels = [
  'Settings', 'General', 'Sources', 'History', 'Keyboard shortcuts', 'Updates',
  'About', 'Language', 'System language', 'Colors', 'Soft colors',
  'Neutral glass', 'Card size', 'Open after screenshot', 'Launch at login',
  'Images', 'Texts', 'Links', 'Capture copied images', 'Capture copied text',
  'Capture copied links', 'Fetch link titles and thumbnails',
  'Recognize text in new images', 'Watch image folders', 'Add folder'
];

const validSameSpelling = {
  az: new Set(['Tendedero · MIT', 'Tesseract OCR', 'Video']),
  es: new Set(['General', 'Tendedero · MIT', 'Tesseract OCR']),
  fr: new Set(['Actions', 'Application', 'Sources', 'Images', 'Tendedero · MIT', 'Tesseract OCR', 'Type']),
  ja: new Set(['Tendedero · MIT', 'Tesseract OCR']),
  ko: new Set(['Tendedero · MIT', 'Tesseract OCR']),
  'pt-BR': new Set(['Links', 'Tendedero · MIT', 'Tesseract OCR']),
  tr: new Set(['Tendedero · MIT', 'Tesseract OCR', 'Video']),
  'zh-Hans': new Set(['Tendedero · MIT', 'Tesseract OCR'])
};

test('General and Sources copy exists in all nine locale catalogs', () => {
  assert.deepEqual(Object.keys(catalogs).sort(), locales);
  for (const locale of locales) {
    for (const key of settingsText) {
      assert.equal(typeof catalogs[locale][key], 'string', `${locale} is missing: ${key}`);
      assert.notEqual(catalogs[locale][key].trim(), '', `${locale} is blank: ${key}`);
    }
  }
});

test('all locale catalogs contain the same complete key set', () => {
  const sourceKeys = Object.keys(catalogs.en);
  for (const locale of locales) {
    assert.deepEqual(Object.keys(catalogs[locale]), sourceKeys, `${locale} catalog keys differ from English`);
  }
});

test('settings labels use a translated value in every non-English locale', () => {
  for (const locale of locales.filter(value => value !== 'en')) {
    for (const key of translatedLabels) {
      if (validSameSpelling[locale]?.has(key)) continue;
      assert.notEqual(catalogs[locale][key], key, `${locale} leaves this label in English: ${key}`);
    }
  }
});

test('every app string is localized in each non-English catalog', () => {
  for (const locale of locales.filter(value => value !== 'en')) {
    for (const [key, source] of Object.entries(catalogs.en)) {
      const value = catalogs[locale][key];
      assert.equal(typeof value, 'string', `${locale} is missing: ${key}`);
      assert.notEqual(value.trim(), '', `${locale} is blank: ${key}`);
      if (validSameSpelling[locale]?.has(key)) continue;
      assert.notEqual(value, source, `${locale} still uses the English value: ${key}`);
    }
  }
});

test('literal Windows and macOS translation keys exist in every locale', () => {
  for (const locale of locales) {
    for (const key of rendererTranslationKeys) {
      assert.equal(typeof catalogs[locale][key], 'string', `${locale} is missing Windows key: ${key}`);
    }
    for (const key of swiftTranslationKeys) {
      assert.equal(typeof catalogs[locale][key], 'string', `${locale} is missing macOS key: ${key}`);
    }
  }
});

test('localized app strings preserve their printf placeholders', () => {
  const placeholders = value => value.match(/%(?:\d+\$)?[@dfis]/g) || [];
  for (const locale of locales.filter(value => value !== 'en')) {
    for (const [key, source] of Object.entries(catalogs.en)) {
      const expected = placeholders(source), actual = placeholders(catalogs[locale][key]);
      const positional = expected.some(value => /\d+\$/.test(value));
      assert.deepEqual(positional ? actual.sort() : actual, positional ? expected.sort() : expected, `${locale} changed placeholders for: ${key}`);
    }
  }
});

test('Windows Settings and fallback copy passes through the locale lookup', () => {
  const localizedCopy = [
    'Windows uses Control for copy, paste and app commands. Record a combination or turn an action off. Letter keys work only while browsing.',
    'Find shortcut\u2026',
    'Windows uses its own signed installer channel. Download integrity is checked before the app is replaced.',
    'Local clipboard shelves and a saved library for Windows.',
    'Settings sections',
    'Update available',
    'The secure desktop connection is unavailable. Open this interface through the installed application.',
    'Search actions\u2026', 'Browse', 'Run', 'Clipboard shelves', 'Folder actions', 'Search folders', 'Keep at least one shelf visible.'
  ];
  for (const key of localizedCopy) assert.ok(rendererTranslationKeys.includes(key), `Windows copy bypasses translation: ${key}`);
});

test('Windows action palette copy exists in every locale', () => {
  for (const locale of locales) {
    for (const key of actionPaletteCopy) {
      assert.equal(typeof catalogs[locale][key], 'string', `${locale} is missing action palette copy: ${key}`);
      assert.notEqual(catalogs[locale][key].trim(), '', `${locale} has blank action palette copy: ${key}`);
    }
  }
});

test('Windows runtime notices and recoverable errors exist in every locale', () => {
  for (const locale of locales) {
    for (const key of windowsRuntimeMessages) {
      assert.equal(typeof catalogs[locale][key], 'string', `${locale} is missing Windows runtime copy: ${key}`);
      assert.notEqual(catalogs[locale][key].trim(), '', `${locale} has blank Windows runtime copy: ${key}`);
    }
  }
});

test('all fixed Windows runtime errors are translated in every locale', () => {
  for (const locale of locales) {
    for (const key of windowsRuntimeErrorKeys) {
      assert.equal(typeof catalogs[locale][key], 'string', `${locale} is missing runtime error: ${key}`);
      assert.notEqual(catalogs[locale][key].trim(), '', `${locale} has a blank runtime error: ${key}`);
      if (locale !== 'en') assert.notEqual(catalogs[locale][key], key, `${locale} leaves runtime error in English: ${key}`);
    }
  }
});

test('Windows native notices and dialogs use locale-aware main-process copy', () => {
  assert.match(windowsMain, /new Notification\(\{title:mainText\('ClipBoardLine update available'\),body:mainText\('ClipBoardLine %@ is ready\. Click to review and install\.',manifest\.version\)/);
  assert.match(windowsMain, /name:mainText\('Images, recordings and text'\)/);
  assert.match(windowsMain, /dialog\.showErrorBox\(mainText\('ClipBoardLine could not start'\),mainText\(error\.message\)\)/);
  assert.match(windowsMain, /notify\(item\.ocrText\?'Image text ready':'No text found in this image\.'\)/);
  assert.match(windowsMain, /mainText\('Imported %d · failed %d\. %@: %@',imported\.length,failures\.length,failure\.filename,localizedError\)/);
  assert.ok(renderer.includes("'Shortcuts %@ are unavailable. %@'"), 'Shortcut conflict notices must use a formatted locale key');
  for (const locale of locales) {
    for (const key of ['ClipBoardLine update available', 'ClipBoardLine %@ is ready. Click to review and install.', 'Images, recordings and text', 'ClipBoardLine could not start']) {
      assert.equal(typeof catalogs[locale][key], 'string', `${locale} is missing native Windows copy: ${key}`);
    }
  }
});

test('main-process localization formats imported counts, names, errors, and update versions', () => {
  for (const locale of locales) {
    const language = languageCode(locale, 'en');
    const localizedError = translated(language, 'Installer integrity check failed');
    const imported = translated(language, 'Imported %d · failed %d. %@: %@', 2, 1, 'broken.txt', localizedError);
    const expectedImported = catalogs[locale]['Imported %d · failed %d. %@: %@']
      .replace('%d', '2').replace('%d', '1').replace('%@', 'broken.txt').replace('%@', localizedError);
    assert.equal(imported, expectedImported, `${locale} did not format the native import failure`);
    assert.equal(translated(language, 'ClipBoardLine %@ is ready. Click to review and install.', '9.8.7'), catalogs[locale]['ClipBoardLine %@ is ready. Click to review and install.'].replace('%@', '9.8.7'), `${locale} did not format the desktop notification version`);
  }
});

test('Windows runtime status and error templates are localized at display time', () => {
  assert.match(renderer, /localizedMessage\(update\.message\|\|/);
  assert.match(renderer, /localizedMessage\(update\.error\)/);
  assert.match(renderer, /toast\(localizedMessage\(message\)\)/);

  const start = renderer.indexOf('const FORMATTED_MESSAGES=');
  const end = renderer.indexOf('\nfunction toast', start);
  assert.ok(start >= 0 && end > start, 'runtime localization helpers are missing');
  const source = renderer.slice(start, end);
  for (const locale of locales.filter(value => value !== 'en')) {
    const helpers = new Function('t', `${source}\nreturn { localizedMessage, localizedFormat };`)(
      key => catalogs[locale][key] || key
    );
    const error = helpers.localizedMessage('Update check failed: Installer integrity check failed');
    assert.equal(error, catalogs[locale]['Update check failed: %@'].replace('%@', catalogs[locale]['Installer integrity check failed']), `${locale} did not localize a nested update error`);
    assert.equal(helpers.localizedMessage('ClipBoardLine 9.8.7 is available.'), catalogs[locale]['ClipBoardLine %@ is available.'].replace('%@', '9.8.7'), `${locale} did not preserve the update version`);
    assert.equal(helpers.localizedMessage('Imported 2 · failed 1. broken.txt: Installer integrity check failed'), catalogs[locale]['Imported %d · failed %d. %@: %@'].replace('%d', '2').replace('%d', '1').replace('%@', 'broken.txt').replace('%@', catalogs[locale]['Installer integrity check failed']), `${locale} did not localize an import failure`);
    assert.equal(helpers.localizedMessage('Shortcuts Ctrl+Alt+K are unavailable. Choose another combination in Settings.'), catalogs[locale]['Shortcuts %@ are unavailable. %@'].replace('%@', 'Ctrl+Alt+K').replace('%@', catalogs[locale]['Choose another combination in Settings.']), `${locale} did not localize shortcut conflicts`);
    assert.equal(helpers.localizedFormat('Permanently remove %d records? This cannot be undone.', 12), catalogs[locale]['Permanently remove %d records? This cannot be undone.'].replace('%d', '12'), `${locale} did not format the deletion message`);
  }
});

test('Windows action palette localizes titles and availability details', () => {
  assert.match(renderer, /esc\(localizedActionText\(value\.title\)\)/);
  assert.match(renderer, /esc\(localizedActionText\(value\.detail\|\|''\)\)/);
  assert.match(renderer, /selectedLabel\(ids\.length\)/);
  for (const key of ['Open folder', 'Add to folder', 'Remove from folder', 'Open tag', 'Settings']) {
    assert.ok(renderer.includes(`t('${key}')`), `Dynamic action title does not localize its fixed label: ${key}`);
  }
});

test('settings help text and privacy note pass through the locale lookup', () => {
  assert.match(renderer, /description\?`<small>\$\{esc\(localizedMessage\(description\)\)\}<\/small>`/);
  assert.match(renderer, /esc\(t\('Private clipboard markers are ignored\.[^']*'\)\)/);
});
