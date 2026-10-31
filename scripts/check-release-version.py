#!/usr/bin/env python3
"""Reject platform marketing-version drift before building or publishing.

release-version.json is the shared product version. Platform build counters
remain independent; they are monotonic updater identifiers, not product names.
The private Mac checkout can omit windows/, but the public CI requires it.
The Arch PKGBUILD, when present, carries the same version.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[1]
STABLE_VERSION = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\Z")
PKGVER = re.compile(r"^pkgver=(\S*)$", re.MULTILINE)


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


def check_release_version(root: Path = ROOT, *, require_windows: bool = False,
                          expected_version: str | None = None) -> str:
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
    if require_windows or windows.exists():
        package = _read_object(root, "windows/package.json")
        lock = _read_object(root, "windows/package-lock.json")
        require(package.get("version"), "windows/package.json version")
        require(lock.get("version"), "windows/package-lock.json version")
        packages = lock.get("packages")
        top_package = packages.get("") if isinstance(packages, dict) else None
        require(top_package.get("version") if isinstance(top_package, dict) else None,
                'windows/package-lock.json packages[""] version')
    pkgbuild = root / "packaging/arch/PKGBUILD"
    if pkgbuild.exists():
        try:
            versions = PKGVER.findall(pkgbuild.read_text(encoding="utf-8"))
        except (OSError, UnicodeError) as error:
            raise ReleaseVersionError(f"Cannot read packaging/arch/PKGBUILD: {error}") from error
        require(versions[0] if len(versions) == 1 else None, "packaging/arch/PKGBUILD pkgver")
    return expected


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT, help="Checkout to validate (defaults to this script's checkout)")
    parser.add_argument("--require-windows", action="store_true", help="Require the Windows source tree as in the public checkout")
    parser.add_argument("--expected-version", help="Require the selected publisher/payload version to equal the shared version")
    arguments = parser.parse_args()
    try:
        version = check_release_version(arguments.root, require_windows=arguments.require_windows,
                                        expected_version=arguments.expected_version)
    except ReleaseVersionError as error:
        print(f"Release version check failed: {error}", file=sys.stderr)
        return 1
    print(f"Shared release version {version}: all present platform versions match (build counters are independent).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
