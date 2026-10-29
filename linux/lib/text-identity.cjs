'use strict';

// Match macOS TextIdentity without changing the captured clipboard body.
// Spaces, indentation, case and internal blank lines remain significant.
function textIdentity(value) {
  const normalized=value.normalize('NFC').replace(/\r\n?/g,'\n');
  const trimmed=normalized.replace(/^\n+|\n+$/g,'');
  return trimmed.length ? trimmed : normalized;
}

module.exports={textIdentity};
