'use strict';
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const repository = 'orkunisitmak/clipboardline-desktop';
// Immutable previous installers. Never infer these from mutable current package
// metadata or Latest; genuine old releases are part of the native upgrade gate.
const profiles = Object.freeze({
  63: Object.freeze({version:'1.7.0',build:62,sha256:'0f6f1aa59a406b5d7d2e2a64eb1dc1797fde4fc205e8781eb381645137923541'}),
  64: Object.freeze({version:'1.7.1',build:63,sha256:'f8e45afd1ce3ae4d5bbe1c6f355697cbe9f258e5297685a49d94cd05644631b1'}),
  65: Object.freeze({version:'1.7.2',build:64,sha256:'6bd6d9cb53efbb343e35e59206ee220166fc0c8838811cd03c241a340c3e583b'}),
  66: Object.freeze({version:'1.7.2',build:65,sha256:'62cebf204958ca8729c8fd569d7c5a6f83c73aeced6d1f63760500a6b2cf5a8f'}),
  67: Object.freeze({version:'1.7.3',build:66,size:545768617,sha256:'191731aa02077ac975dee65566640c62a23430b49fed54915a2e75f99e84d100',sourceRevision:'8bb1543507ba79854f654c63dfb074c38a40fb9d'}),
  68: Object.freeze({version:'1.7.4',build:67,size:545769370,sha256:'d6b9b2b066f4172c55ccf75bf38118430ab22a761306ef40ba0890e4ea18223f',sourceRevision:'ee7878362a8f740b36bb9a17114bc2aad3cfd0f3'}),
  69: Object.freeze({version:'1.7.5',build:68,size:545769250,sha256:'d37f86b5e355a58e3303899aa6917efb495a7f1d2a02732fd7e843cc1ef442e7',sourceRevision:'0d71154257aef8042a53ee6ff169079eddbb42bd'}),
  70: Object.freeze({version:'1.7.6',build:69,size:545771823,sha256:'76af8435fca09d076ae7eb17c396399fc4dfdfd5099b8ce9b5ad67ddc7e9d531',sourceRevision:'9517b92eb83deb619a4a8f0ab1fbc288e87747e5'}),
  71: Object.freeze({version:'1.7.7',build:70,size:545777945,sha256:'89b9d3d3ddc91d1ddddfb6b07ee73930686d9d2cbbc80a4785746befc9ad9768',sourceRevision:'1c93c163e7e45d102d13c1077dd8baa969eab8ba'})
});
function reviewedPrevious(build) {
  assert.ok(Number.isInteger(build) && Object.hasOwn(profiles, build), 'The candidate needs a reviewed, pinned previous-installation profile.');
  return profiles[build];
}
function previousInstallerURL(build) {
  const previous = reviewedPrevious(build);
  return `https://github.com/${repository}/releases/download/windows-${previous.version}-build${previous.build}/ClipBoardLine-Setup-${previous.version}-x64.exe`;
}
function previousInstallerOptions(build) {
  const previous = reviewedPrevious(build);
  // The original profiles retain their original 200MiB limit. The genuine
  // model-bearing baselines have their own exact reviewed byte limits.
  return {maximum: previous.size ?? 200 * 1024 * 1024, timeout: 120000};
}
function verifyPreviousInstaller(build, bytes) {
  const previous = reviewedPrevious(build);
  assert.ok(Buffer.isBuffer(bytes), 'The previous installer must be downloaded as bytes.');
  if (previous.size !== undefined) assert.equal(bytes.length, previous.size, 'Previous installer differs from its exact reviewed size.');
  assert.equal(crypto.createHash('sha256').update(bytes).digest('hex'), previous.sha256, 'Previous installer differs from its pinned release SHA256.');
}
module.exports = {reviewedPrevious, previousInstallerURL, previousInstallerOptions, verifyPreviousInstaller};
