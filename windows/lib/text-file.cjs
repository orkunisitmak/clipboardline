'use strict';

function decodeStrict(contents,encoding,label) {
  try { return new TextDecoder(encoding,{fatal:true,ignoreBOM:true}).decode(contents); }
  catch { throw new TypeError('Invalid '+label+' text file.'); }
}

function decodeTextFile(contents) {
  if (!Buffer.isBuffer(contents)) throw new TypeError('Text file contents must be a Buffer.');
  if (contents.length >= 2 && contents[0] === 0xff && contents[1] === 0xfe) {
    const utf16le = contents.subarray(2);
    if (utf16le.length % 2 !== 0) throw new TypeError('Invalid UTF-16LE text file.');
    return decodeStrict(utf16le,'utf-16le','UTF-16LE');
  }
  if (contents.length >= 2 && contents[0] === 0xfe && contents[1] === 0xff) {
    const utf16be = contents.subarray(2);
    if (utf16be.length % 2 !== 0) throw new TypeError('Invalid UTF-16BE text file.');
    return decodeStrict(utf16be,'utf-16be','UTF-16BE');
  }
  const utf8 = contents.length >= 3 && contents[0] === 0xef && contents[1] === 0xbb && contents[2] === 0xbf
    ? contents.subarray(3)
    : contents;
  return decodeStrict(utf8,'utf-8','UTF-8');
}

module.exports = {decodeTextFile};
