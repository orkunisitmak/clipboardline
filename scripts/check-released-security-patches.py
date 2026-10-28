#!/usr/bin/env python3
"""Fail closed when a commit that patches a published advisory never reaches a release tag.

A fix that only exists on `main` protects nobody: the shipped builds are what users run. The
exception file is what keeps an honest, currently unreleased fix visible instead of forcing the
gate to be ignored, and it fails once the release actually ships so the entry cannot rot.
"""
from pathlib import Path
import argparse
import json
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
EXCEPTIONS = ROOT / 'scripts' / 'security-patch-release-exceptions.json'
ADVISORY = re.compile(r'\b(?:GHSA-[0-9a-z]{4}-[0-9a-z]{4}-[0-9a-z]{4}|CVE-\d{4}-\d{4,7})\b')
RELEASE_TAG = re.compile(r'^(windows|clipboardline)-\d')


def git(*arguments, cwd):
    return subprocess.run(['git', *arguments], cwd=cwd, capture_output=True, check=True).stdout.decode()


def channels_for(paths):
    """Which release channels ship the files a commit touched."""
    channels = set()
    for path in paths:
        if path.startswith('windows/'):
            channels.add('windows')
        elif path.startswith(('Sources/', 'Tests/')):
            channels.add('clipboardline')
    return sorted(channels) or ['clipboardline', 'windows']


def advisory_commits(cwd):
    commits = []
    for record in git('log', '--format=%x00%H%n%s%n%b', cwd=cwd).split('\0'):
        record = record.strip('\n')
        if not record:
            continue
        lines = record.splitlines()
        advisories = sorted(set(ADVISORY.findall('\n'.join(lines[1:]))))
        if not advisories:
            continue
        paths = [line for line in git('show', '--name-only', '--format=', lines[0], cwd=cwd).splitlines() if line]
        commits.append({'sha': lines[0], 'subject': lines[1], 'advisories': advisories,
                        'paths': paths, 'channels': channels_for(paths)})
    return commits


def release_tags(sha, channels, cwd):
    return [tag for tag in git('tag', '--contains', sha, cwd=cwd).split()
            if RELEASE_TAG.match(tag) and RELEASE_TAG.match(tag).group(1) in channels]


def audit(cwd=ROOT, exceptions_path=EXCEPTIONS):
    excepted = {}
    if Path(exceptions_path).exists():
        excepted = {entry['advisory']: entry for entry in json.loads(Path(exceptions_path).read_text())['excepted']}
    commits = advisory_commits(cwd)
    findings, tracked, shipped = [], [], []
    for commit in commits:
        for advisory in commit['advisories']:
            tags = release_tags(commit['sha'], commit['channels'], cwd)
            entry = excepted.get(advisory)
            if tags:
                shipped.append({'sha': commit['sha'], 'advisory': advisory, 'tags': tags})
                if entry:
                    findings.append({'sha': commit['sha'], 'advisory': advisory,
                                     'rule': 'stale-release-exception'})
            elif entry and entry.get('sha') == commit['sha']:
                tracked.append({'sha': commit['sha'], 'advisory': advisory, 'issue': entry.get('issue', ''),
                                'reviewed': entry.get('reviewed', ''), 'channels': commit['channels']})
            elif entry:
                findings.append({'sha': commit['sha'], 'advisory': advisory, 'rule': 'release-exception-sha-mismatch'})
            else:
                findings.append({'sha': commit['sha'], 'advisory': advisory,
                                 'rule': 'advisory-fix-not-in-any-release', 'channels': commit['channels']})
    return {'advisoryCommits': len(commits), 'findings': findings, 'excepted': tracked, 'shipped': shipped}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report', help='write the redacted JSON summary to this path')
    arguments = parser.parse_args()
    report = audit()
    if arguments.report:
        Path(arguments.report).write_text(json.dumps(report, indent=2) + '\n')
    for item in report['shipped']:
        print('%-32s %s %s in %s' % ('advisory-fix-released', item['sha'][:9], item['advisory'], ','.join(item['tags'])))
    for entry in report['excepted']:
        print('%-32s %s %s tracked by %s' % ('advisory-fix-unreleased-tracked', entry['sha'][:9], entry['advisory'],
                                             entry['issue'] or 'no issue link'))
    for item in report['findings']:
        print('%-32s %s %s %s' % (item['rule'], item['sha'][:9], item['advisory'],
                                  ','.join(item.get('channels', []))))
    if report['findings']:
        print('%d advisory fix(es) have not reached a release tag' % len(report['findings']))
        return 1
    print('%d advisory fix(es) are released or tracked' % (len(report['shipped']) + len(report['excepted'])))
    return 0


if __name__ == '__main__':
    sys.exit(main())
