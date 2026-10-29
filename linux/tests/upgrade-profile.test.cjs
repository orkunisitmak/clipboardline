'use strict';
const assert = require('node:assert/strict');
const {test} = require('node:test');
const {reviewedPrevious, previousInstallerURL, previousInstallerOptions, verifyPreviousInstaller} = require('./upgrade-profile.cjs');
test('historical build63 to66 previous identities and download limits stay immutable', () => {
  const expected = [
    [63,{version:'1.7.0',build:62,sha256:'0f6f1aa59a406b5d7d2e2a64eb1dc1797fde4fc205e8781eb381645137923541'}],
    [64,{version:'1.7.1',build:63,sha256:'f8e45afd1ce3ae4d5bbe1c6f355697cbe9f258e5297685a49d94cd05644631b1'}],
    [65,{version:'1.7.2',build:64,sha256:'6bd6d9cb53efbb343e35e59206ee220166fc0c8838811cd03c241a340c3e583b'}],
    [66,{version:'1.7.2',build:65,sha256:'62cebf204958ca8729c8fd569d7c5a6f83c73aeced6d1f63760500a6b2cf5a8f'}]
  ];
  for (const [build, profile] of expected) {
    assert.deepEqual(reviewedPrevious(build), profile);
    assert.deepEqual(previousInstallerOptions(build), {maximum:200*1024*1024,timeout:120000});
    assert.equal(Object.isFrozen(reviewedPrevious(build)), true);
  }
});
test('build67 requires the genuine published model-bearing build66 with exact size and SHA', () => {
  assert.deepEqual(reviewedPrevious(67), {version:'1.7.3',build:66,size:545768617,sha256:'191731aa02077ac975dee65566640c62a23430b49fed54915a2e75f99e84d100',sourceRevision:'8bb1543507ba79854f654c63dfb074c38a40fb9d'});
  assert.equal(previousInstallerURL(67), 'https://github.com/orkunisitmak/clipboardline-desktop/releases/download/windows-1.7.3-build66/ClipBoardLine-Setup-1.7.3-x64.exe');
  assert.deepEqual(previousInstallerOptions(67), {maximum:545768617,timeout:120000});
  assert.ok(previousInstallerOptions(67).maximum > 200*1024*1024);
  assert.ok(previousInstallerOptions(67).maximum <= 1024**3);
  assert.throws(() => { reviewedPrevious(67).size = 1024**3; }, TypeError);
});
test('build68 requires the genuine published 1.7.4 build67 with exact size, hash and source', () => {
  assert.deepEqual(reviewedPrevious(68), {version:'1.7.4',build:67,size:545769370,sha256:'d6b9b2b066f4172c55ccf75bf38118430ab22a761306ef40ba0890e4ea18223f',sourceRevision:'ee7878362a8f740b36bb9a17114bc2aad3cfd0f3'});
  assert.equal(previousInstallerURL(68), 'https://github.com/orkunisitmak/clipboardline-desktop/releases/download/windows-1.7.4-build67/ClipBoardLine-Setup-1.7.4-x64.exe');
  assert.deepEqual(previousInstallerOptions(68), {maximum:545769370,timeout:120000});
  assert.equal(Object.isFrozen(reviewedPrevious(68)), true);
  assert.throws(() => verifyPreviousInstaller(68, Buffer.alloc(100)), /exact reviewed size/);
});
test('build69 pins the genuine published 1.7.5 build68 size, hash and source', () => {
  assert.deepEqual(reviewedPrevious(69), {version:'1.7.5',build:68,size:545769250,sha256:'d37f86b5e355a58e3303899aa6917efb495a7f1d2a02732fd7e843cc1ef442e7',sourceRevision:'0d71154257aef8042a53ee6ff169079eddbb42bd'});
  assert.equal(previousInstallerURL(69), 'https://github.com/orkunisitmak/clipboardline-desktop/releases/download/windows-1.7.5-build68/ClipBoardLine-Setup-1.7.5-x64.exe');
  assert.deepEqual(previousInstallerOptions(69), {maximum:545769250,timeout:120000});
  assert.throws(() => verifyPreviousInstaller(69, Buffer.alloc(100)), /exact reviewed size/);
});
test('unknown, coerced or missing candidate profiles cannot select a previous installer', () => {
  for (const build of [undefined,null,true,'67','68','69','70','71',62,72,NaN,67.5]) {
    assert.throws(() => reviewedPrevious(build), /reviewed/);
    assert.throws(() => previousInstallerURL(build), /reviewed/);
    assert.throws(() => previousInstallerOptions(build), /reviewed/);
  }
});
test('previous bytes must satisfy the exact reviewed size and cryptographic identity', () => {
  assert.throws(() => verifyPreviousInstaller(67, Buffer.alloc(100)), /exact reviewed size/);
  assert.throws(() => verifyPreviousInstaller(66, Buffer.from('synthetic tampered installer')), /pinned release SHA256/);
  assert.throws(() => verifyPreviousInstaller(67, 'not binary bytes'), /downloaded as bytes/);
});

test('build70 pins the genuine published1.7.6build69 without modifying earlier profiles',()=>{
 assert.deepEqual(reviewedPrevious(70),{version:'1.7.6',build:69,size:545771823,sha256:'76af8435fca09d076ae7eb17c396399fc4dfdfd5099b8ce9b5ad67ddc7e9d531',sourceRevision:'9517b92eb83deb619a4a8f0ab1fbc288e87747e5'});
 assert.equal(previousInstallerURL(70),'https://github.com/orkunisitmak/clipboardline-desktop/releases/download/windows-1.7.6-build69/ClipBoardLine-Setup-1.7.6-x64.exe');
 assert.deepEqual(previousInstallerOptions(70),{maximum:545771823,timeout:120000});
 assert.throws(()=>verifyPreviousInstaller(70,Buffer.alloc(100)),/exact reviewed size/);
});

test('build71 pins genuine published1.7.7build70',()=>{
 assert.deepEqual(reviewedPrevious(71),{version:'1.7.7',build:70,size:545777945,sha256:'89b9d3d3ddc91d1ddddfb6b07ee73930686d9d2cbbc80a4785746befc9ad9768',sourceRevision:'1c93c163e7e45d102d13c1077dd8baa969eab8ba'});
 assert.equal(previousInstallerURL(71),'https://github.com/orkunisitmak/clipboardline-desktop/releases/download/windows-1.7.7-build70/ClipBoardLine-Setup-1.7.7-x64.exe');
 assert.deepEqual(previousInstallerOptions(71),{maximum:545777945,timeout:120000});
 assert.throws(()=>verifyPreviousInstaller(71,Buffer.alloc(100)),/exact reviewed size/);
});
