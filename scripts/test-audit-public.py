#!/usr/bin/env python3
"""Synthetic negative cases for the publication guard; no user data or credentials."""
from pathlib import Path
import importlib.util
import json
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('audit_public', Path(__file__).with_name('audit-public.py'))
scanner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scanner)


class PublicationGuardTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='synthetic-public-guard-')
        self.root = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def test_secret_and_personal_path_values_never_appear_in_report(self):
        value = 'gh' + 'p_' + 'A' * 36
        personal = '/Use' + 'rs/synthetic-person/checkout'
        (self.root / 'bad.txt').write_text(value + '\n' + personal)
        report = scanner.audit(self.root)
        self.assertEqual({f['rule'] for f in report['findings']}, {'github-token', 'personal-build-path'})
        self.assertNotIn(value, json.dumps(report))
        self.assertNotIn(personal, json.dumps(report))

    def test_private_artifact_is_rejected(self):
        (self.root / 'credential.p12').write_bytes(b'not a real key')
        self.assertEqual({f['rule'] for f in scanner.audit(self.root)['findings']}, {'private-artifact'})

    def test_source_symlink_is_rejected(self):
        (self.root / 'source.txt').write_text('ordinary source')
        try: (self.root / 'alias.txt').symlink_to(self.root / 'source.txt')
        except OSError as error:
            if getattr(error, 'winerror', None) != 1314: raise
            self.skipTest('Creating symlinks on Windows requires Developer Mode or administrator rights')
        self.assertEqual({f['rule'] for f in scanner.audit(self.root)['findings']}, {'source-symlink'})

    def test_untracked_source_is_scanned_in_fresh_repository(self):
        subprocess.run(['git', 'init', '--quiet', str(self.root)], check=True)
        (self.root / 'new.txt').write_text('gh' + 'p_' + 'B' * 36)
        report = scanner.audit(self.root)
        self.assertEqual(report['filesScanned'], 1)
        self.assertEqual(report['findings'][0]['rule'], 'github-token')

    def test_force_tracked_ignored_artifacts_are_not_hidden(self):
        subprocess.run(['git', 'init', '--quiet', str(self.root)], check=True)
        (self.root / '.gitignore').write_text('build/\n')
        (self.root / 'build').mkdir()
        (self.root / 'build' / 'private.txt').write_text('synthetic build data')
        subprocess.run(['git', 'add', '--force', 'build/private.txt'], cwd=self.root, check=True)
        self.assertIn({'file': 'build/private.txt', 'rule': 'private-artifact'}, scanner.audit(self.root)['findings'])


if __name__ == '__main__':
    unittest.main()
