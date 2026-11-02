#!/usr/bin/env python3
"""Fail closed on private artifacts and high-confidence secrets; never print values."""
from pathlib import Path
import argparse
import hashlib
import json
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
IGNORED = {'.git', '.build', 'build', 'dist', 'node_modules', 'local', '.cache', '__pycache__'}
PRIVATE_NAMES = {'.env', 'profile.json', 'keychain-password', 'recovery-password',
                 'preferences.plist', 'history.json', 'text-history.json', 'install-job.json'}
PRIVATE_PARTS = {'signing', 'rollback', 'backups', 'attachments', 'legacy-2026-10-09'}
PRIVATE_SUFFIXES = {'.p12', '.pfx', '.key', '.pem', '.keychain', '.keychain-db', '.sqlite', '.sqlite3', '.db'}
PATTERNS = {
    'github-token': rb'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{45,})\b',
    'openai-token': rb'\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{35,}\b',
    'anthropic-token': rb'\bsk-ant-[A-Za-z0-9_-]{35,}\b',
    'aws-access-id': rb'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b',
    'private-key-block': rb'-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----',
    'url-userinfo': rb'(?i:https?)://[^\s/\x22\x27:]+:[^\s/@\x22\x27]+@',
    'personal-build-path': rb'/Use' rb'rs/(?!example/|synthetic/|Shared/)[^/\s\x22\x27]+/',
}


def paths(root):
    if (root / '.git').exists():
        result = subprocess.run(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=root, capture_output=True, check=True)
        return [root / name for name in result.stdout.decode().split('\0') if name]
    return [p for p in root.rglob('*') if p.is_file() and not any(part in IGNORED for part in p.relative_to(root).parts)]


def audit(root):
    findings = []
    manifest = []
    for path in sorted(paths(root)):
        name = path.relative_to(root).as_posix()
        parts = set(path.relative_to(root).parts)
        if path.is_symlink():
            findings.append({'file': name, 'rule': 'source-symlink'})
            continue
        if (path.name.lower() in PRIVATE_NAMES or parts & (PRIVATE_PARTS | IGNORED) or
            path.suffix.lower() in PRIVATE_SUFFIXES or path.name.startswith('.env.')):
            findings.append({'file': name, 'rule': 'private-artifact'})
            continue
        data = path.read_bytes()
        manifest.append({'file': name, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()})
        # This scanner's own expressions are patterns, not real credentials.
        # Runtime-generated test keys remain in ignored temporary directories.
        for rule, pattern in PATTERNS.items():
            for match in re.finditer(pattern, data):
                if (rule == 'url-userinfo' and name == 'Tests/ImageHistoryTests/AppUpdateControllerTests.swift' and
                    match.group() == b'https://user' + b':password@'):
                    continue  # Exact synthetic credential-rejection test, never a real credential.
                findings.append({'file': name, 'line': data[:match.start()].count(b'\n') + 1, 'rule': rule})
    return {'filesScanned': len(manifest), 'findings': findings, 'files': manifest}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=ROOT)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    result = audit(args.root.resolve())
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({'filesScanned': result['filesScanned'], 'findings': result['findings']}, indent=2))
    raise SystemExit(1 if result['findings'] or result['filesScanned'] == 0 else 0)


if __name__ == '__main__':
    main()
