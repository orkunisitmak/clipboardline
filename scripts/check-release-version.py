#!/usr/bin/env python3
"""Reject platform version drift and vulnerable Windows Electron before packaging.

release-version.json is the shared product version. Platform build counters
remain independent; they are monotonic updater identifiers, not product names.
The private Mac checkout can omit windows/, but the public CI requires it.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[1]
STABLE_VERSION = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\Z")
MINIMUM_SAFE_ELECTRON = (44, 9, 1)  # GHSA-jr5w-w6x2-84p9


class ReleaseVersionError(ValueError):
    pass


def _read_object(root: Path, relative: str) -> dict:
    try:
        value = json.loads((root / relative).read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ReleaseVersionError(f"Cannot read {relative}: {error}") from error
    if not isinstance(value, dict):
        raise ReleaseVersionError(f"{relative} must contain a JSON object")
    return value


def load_release_version(root: Path = ROOT) -> str:
    value = _read_object(Path(root), "release-version.json").get("version")
    if not isinstance(value, str) or not STABLE_VERSION.fullmatch(value):
        raise ReleaseVersionError("release-version.json version must be a stable major.minor.patch version")
    return value


def require_safe_electron(version: object, source: str) -> None:
    if not isinstance(version, str) or not STABLE_VERSION.fullmatch(version):
        raise ReleaseVersionError(f"{source} must pin a stable Electron version")
    if tuple(map(int, version.split("."))) < MINIMUM_SAFE_ELECTRON:
        raise ReleaseVersionError(f"{source} is {version}; Electron 44.9.1 or newer is required")


def check_release_version(root: Path = ROOT, *, require_windows: bool = False,
                          expected_version: str | None = None,
                          require_installed_electron: bool = False) -> str:
    root = Path(root)
    expected = load_release_version(root)

    def require(actual: object, source: str) -> None:
        if actual != expected:
            raise ReleaseVersionError(
                f"{source} is {actual!r}; shared release-version.json requires {expected!r}. "
                "Update both platform versions together; keep their build counters independent."
            )

    if expected_version is not None:
        require(expected_version, "Selected release version")
    require(_read_object(root, "upstream-state.json").get("forkVersion"), "upstream-state.json forkVersion")
    windows = root / "windows"
    if require_windows or require_installed_electron or windows.exists():
        package = _read_object(root, "windows/package.json")
        lock = _read_object(root, "windows/package-lock.json")
        require(package.get("version"), "windows/package.json version")
        require(lock.get("version"), "windows/package-lock.json version")
        packages = lock.get("packages")
        top_package = packages.get("") if isinstance(packages, dict) else None
        require(top_package.get("version") if isinstance(top_package, dict) else None,
                'windows/package-lock.json packages[""] version')
        package_dependencies = package.get("devDependencies")
        lock_dependencies = top_package.get("devDependencies")
        package_electron = package_dependencies.get("electron") if isinstance(package_dependencies, dict) else None
        lock_electron = lock_dependencies.get("electron") if isinstance(lock_dependencies, dict) else None
        installed_lock = packages.get("node_modules/electron")
        installed_lock_electron = installed_lock.get("version") if isinstance(installed_lock, dict) else None
        for version, source in (
            (package_electron, "windows/package.json Electron"),
            (lock_electron, 'windows/package-lock.json packages[""] Electron'),
            (installed_lock_electron, "windows/package-lock.json installed Electron"),
        ):
            require_safe_electron(version, source)
        if package_electron != lock_electron or package_electron != installed_lock_electron:
            raise ReleaseVersionError("Windows Electron versions differ between package.json and package-lock.json")
        if require_installed_electron:
            installed_electron = _read_object(root, "windows/node_modules/electron/package.json").get("version")
            require_safe_electron(installed_electron, "windows/node_modules/electron/package.json Electron")
            if installed_electron != package_electron:
                raise ReleaseVersionError("Installed Windows Electron differs from the pinned package version")
    return expected


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT, help="Checkout to validate (defaults to this script's checkout)")
    parser.add_argument("--require-windows", action="store_true", help="Require the Windows source tree as in the public checkout")
    parser.add_argument("--expected-version", help="Require the selected publisher/payload version to equal the shared version")
    parser.add_argument("--require-installed-electron", action="store_true", help="Check the installed Electron before packaging")
    arguments = parser.parse_args()
    try:
        version = check_release_version(arguments.root, require_windows=arguments.require_windows,
                                        expected_version=arguments.expected_version,
                                        require_installed_electron=arguments.require_installed_electron)
    except ReleaseVersionError as error:
        print(f"Release version check failed: {error}", file=sys.stderr)
        return 1
    print(f"Shared release version {version}: all present platform versions match (build counters are independent).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
