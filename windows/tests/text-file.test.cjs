'use strict';

const assert=require('node:assert/strict');
const {test}=require('node:test');
const {text}=require('../lib/model.cjs');
const {decodeTextFile}=require('../lib/text-file.cjs');

test('decodes UTF-16LE text imports with a byte-order mark',()=>{
  const expected='ClipboardLine — merhaba 🌱\nİkinci satır';
  const contents=Buffer.concat([Buffer.from([0xff,0xfe]),Buffer.from(expected,'utf16le')]);
  assert.equal(text(decodeTextFile(contents)),expected);
});

test('decodes UTF-16BE text imports with a byte-order mark',()=>{
  const expected='ClipboardLine — merhaba 🌱\nİkinci satır';
  const body=Buffer.from(expected,'utf16le').swap16();
  const contents=Buffer.concat([Buffer.from([0xfe,0xff]),body]);
  assert.equal(text(decodeTextFile(contents)),expected);
});

test('rejects UTF-16BE imports with an incomplete code unit',()=>{
  const contents=Buffer.from([0xfe,0xff,0x00,0x41,0x00]);
  assert.throws(()=>decodeTextFile(contents),/Invalid UTF-16BE text file/);
});

test('strips a UTF-8 byte-order mark from text imports',()=>{
  const expected='ClipboardLine — merhaba';
  const contents=Buffer.concat([Buffer.from([0xef,0xbb,0xbf]),Buffer.from(expected,'utf8')]);
  assert.equal(decodeTextFile(contents),expected);
});

test('keeps plain UTF-8 text imports unchanged',()=>{
  const expected='ClipboardLine — merhaba 🌱';
  assert.equal(decodeTextFile(Buffer.from(expected,'utf8')),expected);
});


test('rejects UTF-16LE imports with an incomplete code unit',()=>{
  const contents=Buffer.from([0xff,0xfe,0x41]);
  assert.throws(()=>decodeTextFile(contents),/Invalid UTF-16LE text file/);
});
