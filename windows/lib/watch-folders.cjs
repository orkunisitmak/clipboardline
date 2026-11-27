'use strict';

const nodePath = require('node:path');

const SHELF_KINDS = ['image', 'text', 'link'];

/** Identity of a watched folder; Windows paths compare case-insensitively. */
function folderKey(folder, pathApi = nodePath) {
  return pathApi.resolve(folder).toLowerCase();
}

/**
 * Returns the folders to watch: the user's own, plus the system Screenshots
 * folder while the setting is on, unless the user already watches that folder.
 */
function watchedFolders(settings, systemFolder, pathApi = nodePath) {
  const folders = [...(settings?.watchFolders || [])];
  if (!settings?.watchSystemScreenshots || !systemFolder) return folders;
  const system = folderKey(systemFolder, pathApi);
  if (!folders.some(folder => folderKey(folder, pathApi) === system)) folders.push(systemFolder);
  return folders;
}

/**
 * Like macOS focusShelf: selecting an item on a hidden shelf shows that shelf
 * alone. Returns the settings patch for it, or null when the shelf is already
 * visible. An empty visibleKinds list shows every shelf.
 */
function shelfRevealPatch(settings, next, event) {
  if (next !== 'shelves' || !event?.selectId || !SHELF_KINDS.includes(event.kind)) return null;
  const visible = settings?.visibleKinds || [];
  return !visible.length || visible.includes(event.kind) ? null : { visibleKinds: [event.kind] };
}

module.exports = { folderKey, watchedFolders, shelfRevealPatch };
