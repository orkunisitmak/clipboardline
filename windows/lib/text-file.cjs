'use strict';

function decodeTextFile(contents) {
  if (!Buffer.isBuffer(contents)) throw new TypeError('Text file contents must be a Buffer.');
  if (contents.length >= 2 && contents[0] === 0xff && contents[1] === 0xfe) {
    const utf16le = contents.subarray(2);
    if (utf16le.length % 2 !== 0) throw new TypeError('Invalid UTF-16LE text file.');
    return utf16le.toString('utf16le');
  }
  if (contents.length >= 2 && contents[0] === 0xfe && contents[1] === 0xff) {
    const utf16be = contents.subarray(2);
    if (utf16be.length % 2 !== 0) throw new TypeError('Invalid UTF-16BE text file.');
    return Buffer.from(utf16be).swap16().toString('utf16le');
  }
  const utf8 = contents.length >= 3 && contents[0] === 0xef && contents[1] === 0xbb && contents[2] === 0xbf
    ? contents.subarray(3)
    : contents;
  return utf8.toString('utf8');
}

module.exports = {decodeTextFile};
