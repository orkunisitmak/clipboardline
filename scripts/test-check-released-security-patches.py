#!/usr/bin/env python3
"""Synthetic release-containment cases for the advisory gate; synthetic SHAs and advisories only."""
from pathlib import Path
import importlib.util
import json
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('released_patches', Path(__file__).with_name('check-released-security-patches.py'))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

ADVISORY = 'GHSA-synt-heti-c999'


class ReleasedSecurityPatchTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='synthetic-release-gate-')
        self.root = Path(self.temporary.name)
        self.exceptions = self.root / 'exceptions.json'
        subprocess.run(['git', 'init', '--quiet', str(self.root)], check=True)
        subprocess.run(['git', 'config', 'user.email', 'synthetic@example.invalid'], cwd=self.root, check=True)
        subprocess.run(['git', 'config', 'user.name', 'Synthetic Fixture'], cwd=self.root, check=True)

    def tearDown(self):
        self.temporary.cleanup()

    def commit(self, path, subject):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text('synthetic content\n')
        subprocess.run(['git', 'add', '--', path], cwd=self.root, check=True)
        # core.hooksPath is global on some machines, so the fixture opts out of any commit-msg hook.
        subprocess.run(['git', '-c', 'core.hooksPath=', 'commit', '--quiet', '-m', subject], cwd=self.root, check=True)
        return subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=self.root, capture_output=True,
                              text=True, check=True).stdout.strip()

    def tag(self, name):
        subprocess.run(['git', 'tag', name], cwd=self.root, check=True)

    def excepted(self, sha):
        self.exceptions.write_text(json.dumps({'excepted': [{'advisory': ADVISORY, 'sha': sha,
                                                            'issue': 'https://example.invalid/issue/1'}]}) + '\n')

    def audit(self):
        return gate.audit(cwd=self.root, exceptions_path=self.exceptions)

    def rules(self):
        return {finding['rule'] for finding in self.audit()['findings']}

    def test_unreleased_advisory_fix_is_reported_with_its_channel(self):
        self.commit('windows/package.json', f'Patch Electron certificate trust for {ADVISORY}')
        report = self.audit()
        self.assertEqual({finding['rule'] for finding in report['findings']}, {'advisory-fix-not-in-any-release'})
        self.assertEqual(report['findings'][0]['channels'], ['windows'])

    def test_a_release_tag_containing_the_commit_clears_the_finding(self):
        self.commit('windows/package.json', f'Patch Electron certificate trust for {ADVISORY}')
        self.tag('windows-1.7.9-build72')
        self.assertEqual(self.rules(), set())
        self.assertEqual(self.audit()['shipped'][0]['tags'], ['windows-1.7.9-build72'])

    def test_a_release_of_the_other_channel_does_not_cover_this_commit(self):
        self.commit('windows/package.json', f'Patch Electron certificate trust for {ADVISORY}')
        self.tag('clipboardline-1.7.9-build79')
        self.assertEqual(self.rules(), {'advisory-fix-not-in-any-release'})

    def test_mac_source_commit_expects_the_mac_release(self):
        self.commit('Sources/Tendedero/PublicLinkNetwork.swift', f'Bound link metadata work for {ADVISORY}')
        self.assertEqual(self.audit()['findings'][0]['channels'], ['clipboardline'])
        self.tag('clipboardline-1.7.9-build79')
        self.assertEqual(self.rules(), set())

    def test_tracked_exception_hides_an_unreleased_fix(self):
        sha = self.commit('windows/package.json', f'Patch Electron certificate trust for {ADVISORY}')
        self.excepted(sha)
        report = self.audit()
        self.assertEqual(report['findings'], [])
        self.assertEqual(report['excepted'][0]['issue'], 'https://example.invalid/issue/1')

    def test_exception_becomes_a_finding_once_the_release_ships(self):
        sha = self.commit('windows/package.json', f'Patch Electron certificate trust for {ADVISORY}')
        self.excepted(sha)
        self.tag('windows-1.7.9-build72')
        self.assertEqual(self.rules(), {'stale-release-exception'})

    def test_exception_for_a_different_commit_does_not_hide_the_finding(self):
        self.commit('windows/package.json', f'Patch Electron certificate trust for {ADVISORY}')
        self.excepted('f' * 40)
        self.assertEqual(self.rules(), {'release-exception-sha-mismatch'})

    def test_commit_without_an_advisory_identifier_is_ignored(self):
        self.commit('windows/package.json', 'Bump Electron to the next patch release')
        self.assertEqual(self.audit()['advisoryCommits'], 0)


if __name__ == '__main__':
    unittest.main()
