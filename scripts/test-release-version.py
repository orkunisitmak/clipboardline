#!/usr/bin/env python3
"""Exercise the shared version guard with isolated Mac and public checkout fixtures."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("check-release-version.py")
SPEC = importlib.util.spec_from_file_location("release_version", SCRIPT)
guard = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(guard)


class ReleaseVersionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="clipboardline-shared-version-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.write("release-version.json", {"version": "1.7.2"})
        self.write("upstream-state.json", {"forkVersion": "1.7.2", "buildNumber": "66"})

    def write(self, name, value):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value), encoding="utf-8")

    def windows(self):
        self.write("windows/package.json", {"version": "1.7.2", "clipboardLineBuild": 64,
                                            "devDependencies": {"electron": "44.9.1"}})
        self.write("windows/package-lock.json", {"version": "1.7.2", "packages": {
            "": {"version": "1.7.2", "devDependencies": {"electron": "44.9.1"}},
            "node_modules/electron": {"version": "44.9.1"}}})

    def test_private_mac_checkout_can_omit_windows(self):
        self.assertEqual(guard.check_release_version(self.root), "1.7.2")

    def test_both_platforms_match_with_independent_build_counters(self):
        self.windows()
        self.assertEqual(guard.check_release_version(self.root, require_windows=True), "1.7.2")

    def test_selected_publisher_version_must_match(self):
        self.assertEqual(guard.check_release_version(self.root, expected_version="1.7.2"), "1.7.2")
        with self.assertRaisesRegex(guard.ReleaseVersionError, "Selected release version"):
            guard.check_release_version(self.root, expected_version="1.7.1")

    def test_mac_drift_is_rejected(self):
        self.write("upstream-state.json", {"forkVersion": "1.7.1", "buildNumber": "65"})
        with self.assertRaisesRegex(guard.ReleaseVersionError, "upstream-state.json forkVersion"):
            guard.check_release_version(self.root)

    def test_windows_package_drift_is_rejected(self):
        self.windows()
        self.write("windows/package.json", {"version": "1.7.1"})
        with self.assertRaisesRegex(guard.ReleaseVersionError, "windows/package.json version"):
            guard.check_release_version(self.root)

    def test_lock_top_version_drift_is_rejected(self):
        self.windows()
        lock = json.loads((self.root / "windows/package-lock.json").read_text())
        lock["version"] = "1.7.1"
        self.write("windows/package-lock.json", lock)
        with self.assertRaisesRegex(guard.ReleaseVersionError, "windows/package-lock.json version"):
            guard.check_release_version(self.root)

    def test_lock_root_package_drift_is_rejected(self):
        self.windows()
        lock = json.loads((self.root / "windows/package-lock.json").read_text())
        lock["packages"][""]["version"] = "1.7.1"
        self.write("windows/package-lock.json", lock)
        with self.assertRaisesRegex(guard.ReleaseVersionError, r'packages\[""\] version'):
            guard.check_release_version(self.root)

    def test_missing_lock_root_package_is_rejected(self):
        self.windows()
        self.write("windows/package-lock.json", {"version": "1.7.2", "packages": []})
        with self.assertRaisesRegex(guard.ReleaseVersionError, r'packages\[""\] version'):
            guard.check_release_version(self.root)

    def test_public_checkout_must_include_windows(self):
        with self.assertRaisesRegex(guard.ReleaseVersionError, "Cannot read windows/package.json"):
            guard.check_release_version(self.root, require_windows=True)

    def test_present_but_incomplete_windows_checkout_is_rejected(self):
        self.write("windows/package.json", {"version": "1.7.2"})
        with self.assertRaisesRegex(guard.ReleaseVersionError, "Cannot read windows/package-lock.json"):
            guard.check_release_version(self.root)

    def test_vulnerable_or_unpinned_electron_is_rejected(self):
        for version in ["44.9.0", "44.8.9", "44.9.1-beta.1", "^44.9.1"]:
            with self.subTest(version=version):
                self.windows()
                package = json.loads((self.root / "windows/package.json").read_text())
                package["devDependencies"]["electron"] = version
                self.write("windows/package.json", package)
                with self.assertRaisesRegex(guard.ReleaseVersionError, "Electron"):
                    guard.check_release_version(self.root, require_windows=True)

    def test_lockfile_and_installed_electron_must_match_the_pin(self):
        self.windows()
        lock = json.loads((self.root / "windows/package-lock.json").read_text())
        lock["packages"]["node_modules/electron"]["version"] = "44.9.0"
        self.write("windows/package-lock.json", lock)
        with self.assertRaisesRegex(guard.ReleaseVersionError, "Electron 44.9.1"):
            guard.check_release_version(self.root, require_windows=True)
        self.windows()
        self.write("windows/node_modules/electron/package.json", {"version": "44.9.0"})
        with self.assertRaisesRegex(guard.ReleaseVersionError, "Electron 44.9.1"):
            guard.check_release_version(self.root, require_windows=True, require_installed_electron=True)
        self.write("windows/node_modules/electron/package.json", {"version": "44.9.2"})
        with self.assertRaisesRegex(guard.ReleaseVersionError, "Installed Windows Electron differs"):
            guard.check_release_version(self.root, require_installed_electron=True)
        self.write("windows/node_modules/electron/package.json", {"version": "44.9.1"})
        self.assertEqual(guard.check_release_version(self.root, require_installed_electron=True), "1.7.2")
        lock = json.loads((self.root / "windows/package-lock.json").read_text())
        lock["packages"]["node_modules/electron"]["version"] = "44.9.2"
        self.write("windows/package-lock.json", lock)
        with self.assertRaisesRegex(guard.ReleaseVersionError, "versions differ"):
            guard.check_release_version(self.root, require_windows=True)

    def test_missing_mac_version_is_rejected(self):
        self.write("upstream-state.json", {})
        with self.assertRaises(guard.ReleaseVersionError):
            guard.check_release_version(self.root)

    def test_product_version_requires_stable_semver(self):
        for version in [None, 172, "1.7", "1.7.2-review", "01.7.2", "1.7.2\n"]:
            with self.subTest(version=version):
                self.write("release-version.json", {"version": version})
                with self.assertRaises(guard.ReleaseVersionError):
                    guard.check_release_version(self.root)

    def test_malformed_and_non_object_json_are_rejected(self):
        for contents in ["not JSON", "[]"]:
            with self.subTest(contents=contents):
                (self.root / "release-version.json").write_text(contents)
                with self.assertRaises(guard.ReleaseVersionError):
                    guard.check_release_version(self.root)

    def test_cli_success_and_actionable_drift_error(self):
        command = [sys.executable, str(SCRIPT), "--root", str(self.root)]
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("1.7.2", result.stdout)
        self.windows()
        self.write("windows/package.json", {"version": "2.0.0"})
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("windows/package.json version", result.stderr)
        self.assertIn("Update both platform versions together", result.stderr)

    def test_cli_require_windows_rejects_mac_only_checkout(self):
        result = subprocess.run([sys.executable, str(SCRIPT), "--root", str(self.root), "--require-windows"],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("windows/package.json", result.stderr)

    def test_cli_require_installed_electron_rejects_safe_mismatch(self):
        self.windows()
        self.write("windows/node_modules/electron/package.json", {"version": "44.9.2"})
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--root", str(self.root),
             "--require-windows", "--require-installed-electron"],
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("Installed Windows Electron differs", result.stderr)

    def test_cli_selected_publisher_version_cannot_bypass_shared_version(self):
        command = [sys.executable, str(SCRIPT), "--root", str(self.root), "--expected-version"]
        self.assertEqual(subprocess.run(command + ["1.7.2"], capture_output=True).returncode, 0)
        result = subprocess.run(command + ["1.7.1"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("Selected release version", result.stderr)


if __name__ == "__main__":
    unittest.main()
