'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  BACKGROUND_ARG,
  shouldStartHidden,
  shouldShowOnSecondInstance,
  loginItemSettings,
  applyLoginItemSetting,
  migrateLoginItemSetting
} = require('../lib/login-launch.cjs');

test('shouldStartHidden activates only when --background is present outside test mode', () => {
  assert.equal(shouldStartHidden({ argv: ['ClipBoardLine.exe'], testMode: false }), false);
  assert.equal(shouldStartHidden({ argv: ['ClipBoardLine.exe', BACKGROUND_ARG], testMode: false }), true);
  assert.equal(shouldStartHidden({ argv: ['ClipBoardLine.exe', BACKGROUND_ARG], testMode: true }), false);
  assert.equal(shouldStartHidden(), false);
});

test('shouldShowOnSecondInstance suppresses duplicate --background launches but opens normal launches', () => {
  assert.equal(shouldShowOnSecondInstance({ commandLine: ['ClipBoardLine.exe'] }), true);
  assert.equal(shouldShowOnSecondInstance({ commandLine: ['ClipBoardLine.exe', '--second'] }), true);
  assert.equal(shouldShowOnSecondInstance({ commandLine: ['ClipBoardLine.exe', BACKGROUND_ARG] }), false);
  assert.equal(shouldShowOnSecondInstance(), true);
});

test('loginItemSettings attaches --background when enabled and omits args when disabled', () => {
  assert.deepEqual(loginItemSettings(true), { openAtLogin: true, args: ['--background'] });
  assert.deepEqual(loginItemSettings(false), { openAtLogin: false });
});

test('applyLoginItemSetting updates Electron login settings and skips test mode', () => {
  const calls = [];
  const appApi = { setLoginItemSettings: (value) => calls.push(value) };

  assert.equal(applyLoginItemSetting(appApi, true, { testMode: true }), false);
  assert.equal(calls.length, 0);

  assert.equal(applyLoginItemSetting(appApi, true, { testMode: false }), true);
  assert.equal(applyLoginItemSetting(appApi, false, { testMode: false }), true);
  assert.deepEqual(calls, [
    { openAtLogin: true, args: ['--background'] },
    { openAtLogin: false }
  ]);
});

test('migrateLoginItemSetting adds --background to active legacy Run entries and respects disabled ones', () => {
  // Already has --background
  let setCalls = [];
  assert.equal(migrateLoginItemSetting({
    getLoginItemSettings: (opts) => ({ openAtLogin: Boolean(opts?.args?.includes(BACKGROUND_ARG)), executableWillLaunchAtLogin: true }),
    setLoginItemSettings: (v) => setCalls.push(v)
  }, true), false);
  assert.equal(setCalls.length, 0);

  // Disabled in Task Manager / not registered
  assert.equal(migrateLoginItemSetting({
    getLoginItemSettings: () => ({ openAtLogin: false, executableWillLaunchAtLogin: false }),
    setLoginItemSettings: (v) => setCalls.push(v)
  }, true), false);
  assert.equal(setCalls.length, 0);

  // Active legacy entry without --background -> migrates once
  assert.equal(migrateLoginItemSetting({
    getLoginItemSettings: (opts) => opts?.args?.includes(BACKGROUND_ARG)
      ? { openAtLogin: false, executableWillLaunchAtLogin: true }
      : { openAtLogin: true, executableWillLaunchAtLogin: true },
    setLoginItemSettings: (v) => setCalls.push(v)
  }, true), true);
  assert.deepEqual(setCalls, [{ openAtLogin: true, args: ['--background'] }]);
});
