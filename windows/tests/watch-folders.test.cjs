'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { win32 } = require('node:path');
const { folderKey, watchedFolders, shelfRevealPatch } = require('../lib/watch-folders.cjs');

const SYSTEM = 'E:\\OneDrive\\Resimler\\Screenshots';
const OWN = 'D:\\Captures';
const folders = (settings, system = SYSTEM) => watchedFolders(settings, system, win32);

test('the system Screenshots folder is watched after the user folders while the setting is on', () => {
  assert.deepEqual(folders({ watchFolders: [OWN], watchSystemScreenshots: true }), [OWN, SYSTEM]);
  assert.deepEqual(folders({ watchFolders: [], watchSystemScreenshots: true }), [SYSTEM]);
});

test('a Screenshots folder the user already watches is not watched twice', () => {
  for (const own of [SYSTEM, SYSTEM.toUpperCase(), SYSTEM + '\\', 'E:\\OneDrive\\Resimler\\Other\\..\\Screenshots', 'E:/OneDrive/Resimler/Screenshots']) {
    assert.deepEqual(folders({ watchFolders: [own, OWN], watchSystemScreenshots: true }), [own, OWN]);
  }
});

test('turning the setting off drops the system folder and keeps the user folders', () => {
  assert.deepEqual(folders({ watchFolders: [OWN], watchSystemScreenshots: false }), [OWN]);
  assert.deepEqual(folders({ watchFolders: [], watchSystemScreenshots: false }), []);
  assert.deepEqual(folders({ watchFolders: [SYSTEM], watchSystemScreenshots: false }), [SYSTEM], 'the user chose this folder themselves');
});

test('an unresolved system folder adds nothing and the saved list is never changed', () => {
  const settings = { watchFolders: [OWN], watchSystemScreenshots: true };
  for (const missing of [null, undefined, '']) assert.deepEqual(watchedFolders(settings, missing, win32), [OWN]);
  folders(settings).push('changed');
  assert.deepEqual(settings.watchFolders, [OWN]);
});

test('a pending import is matched to its folder without regard to case', () => {
  assert.equal(folderKey(SYSTEM, win32), folderKey(SYSTEM.toUpperCase() + '\\', win32));
  assert.notEqual(folderKey(SYSTEM, win32), folderKey(OWN, win32));
});

test('selecting a new item on a hidden shelf shows that shelf alone', () => {
  const event = { selectId: 'item-1', kind: 'image' };
  assert.deepEqual(shelfRevealPatch({ visibleKinds: ['text', 'link'] }, 'shelves', event), { visibleKinds: ['image'] });
  assert.equal(shelfRevealPatch({ visibleKinds: ['image', 'text'] }, 'shelves', event), null);
});

test('an empty visible list already shows every shelf, so selecting keeps the others', () => {
  assert.equal(shelfRevealPatch({ visibleKinds: [] }, 'shelves', { selectId: 'item-1', kind: 'image' }), null);
  assert.equal(shelfRevealPatch({}, 'shelves', { selectId: 'item-1', kind: 'image' }), null);
});

test('only a shelf selection reveals a shelf', () => {
  const settings = { visibleKinds: ['text'] };
  assert.equal(shelfRevealPatch(settings, 'library', { selectId: 'item-1', kind: 'image' }), null);
  assert.equal(shelfRevealPatch(settings, 'shelves', { kind: 'image' }), null);
  assert.equal(shelfRevealPatch(settings, 'shelves', { selectId: 'item-1', kind: 'folder' }), null);
  assert.equal(shelfRevealPatch(settings, 'shelves', null), null);
});
