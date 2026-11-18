'use strict';

const BACKGROUND_ARG = '--background';

/**
 * Returns whether the app should start silently in the system tray without
 * revealing the shelf overlay on initial launch.
 */
function shouldStartHidden({ argv = [], testMode = false } = {}) {
  return Boolean(!testMode && Array.isArray(argv) && argv.includes(BACKGROUND_ARG));
}

/**
 * Returns whether a secondary launch should reveal the shelf window.
 * Duplicate background login launches stay silent.
 */
function shouldShowOnSecondInstance({ commandLine = [] } = {}) {
  return !Array.isArray(commandLine) || !commandLine.includes(BACKGROUND_ARG);
}

/** Builds Electron login item settings so Windows login launches pass --background. */
function loginItemSettings(enabled) {
  return enabled ? { openAtLogin: true, args: [BACKGROUND_ARG] } : { openAtLogin: false };
}

/** Applies the launch-at-login preference outside isolated test runs. */
function applyLoginItemSetting(appApi, enabled, { testMode = false } = {}) {
  if (testMode || !appApi || typeof appApi.setLoginItemSettings !== 'function') return false;
  appApi.setLoginItemSettings(loginItemSettings(Boolean(enabled)));
  return true;
}

/**
 * Upgrades an active legacy login entry created without --background while
 * respecting entries explicitly disabled in Windows Task Manager.
 */
function migrateLoginItemSetting(appApi, enabled, { testMode = false, development = false } = {}) {
  if (testMode || development || !enabled || !appApi) return false;
  if (typeof appApi.getLoginItemSettings !== 'function' || typeof appApi.setLoginItemSettings !== 'function') return false;
  const current = appApi.getLoginItemSettings({ args: [BACKGROUND_ARG] });
  if (current?.openAtLogin) return false;
  const legacy = appApi.getLoginItemSettings();
  if (!legacy?.openAtLogin && !legacy?.executableWillLaunchAtLogin) return false;
  appApi.setLoginItemSettings(loginItemSettings(true));
  return true;
}

module.exports = {
  BACKGROUND_ARG,
  shouldStartHidden,
  shouldShowOnSecondInstance,
  loginItemSettings,
  applyLoginItemSetting,
  migrateLoginItemSetting
};
