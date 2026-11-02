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

    def test_url_credentials_are_found_with_an_uppercase_scheme(self):
        (self.root / 'bad.txt').write_text('HTTPS://user:' + 'hunter2pass@host.example/')
        self.assertEqual([f['rule'] for f in scanner.audit(self.root)['findings']], ['url-userinfo'])

    def test_private_key_headers_of_every_type_are_flagged(self):
        for kind in ('', 'RSA ', 'DSA ', 'EC ', 'OPENSSH ', 'ENCRYPTED ', 'PGP ', 'ED25519 ', 'RSA-PSS '):
            block = ' BLOCK' if kind == 'PGP ' else ''
            (self.root / 'k.txt').write_text('-----BEGIN ' + kind + 'PRIVATE KEY' + block + '-----\n')
            self.assertEqual([f['rule'] for f in scanner.audit(self.root)['findings']], ['private-key-block'], kind)

    def test_secret_in_utf16_file_is_flagged_on_its_line(self):
        value = 'gh' + 'p_' + 'C' * 36
        for codec in ('utf-16', 'utf-16-le', 'utf-16-be'):
            (self.root / 'u.txt').write_bytes(('ok\n' + value + '\n').encode(codec))
            self.assertEqual(scanner.audit(self.root)['findings'], [{'file': 'u.txt', 'line': 2, 'rule': 'github-token'}], codec)
            self.assertNotIn(value, json.dumps(scanner.audit(self.root)))

    def test_utf16_file_with_a_byte_order_mark_is_not_read_in_the_other_byte_order(self):
        (self.root / 'b.txt').write_bytes(b'\xff\xfe' + ('xhttps://user\u013aassword@example.com\n').encode('utf-16-le'))
        self.assertEqual(scanner.audit(self.root)['findings'], [])
        value = 'gh' + 'p_' + 'F' * 36
        for codec in ('utf-16-le', 'utf-16-be'):
            (self.root / 'b.txt').write_bytes((b'\xff\xfe' if codec.endswith('le') else b'\xfe\xff') + value.encode(codec))
            self.assertEqual(scanner.audit(self.root)['findings'], [{'file': 'b.txt', 'line': 1, 'rule': 'github-token'}], codec)

    def test_secret_in_utf16_text_after_an_odd_byte_is_flagged(self):
        value = 'gh' + 'p_' + 'D' * 36
        for codec in ('utf-16-le', 'utf-16-be'):
            (self.root / 'o.bin').write_bytes(b'\x01' + value.encode(codec))
            self.assertEqual(scanner.audit(self.root)['findings'], [{'file': 'o.bin', 'line': 1, 'rule': 'github-token'}], codec)

    def test_secret_in_utf16_text_after_a_leading_newline_is_flagged_once_on_its_line(self):
        value = 'gh' + 'p_' + 'E' * 36
        for codec in ('utf-16-le', 'utf-16-be'):
            (self.root / 'n.txt').write_bytes(('\n' + value).encode(codec))
            self.assertEqual(scanner.audit(self.root)['findings'], [{'file': 'n.txt', 'line': 2, 'rule': 'github-token'}], codec)

    def test_utf16_character_ending_in_a_line_feed_byte_keeps_its_own_line(self):
        value = 'gh' + 'p_' + 'G' * 36
        (self.root / 'c.txt').write_bytes(('\u010a ' + value).encode('utf-16-le'))
        self.assertEqual(scanner.audit(self.root)['findings'], [{'file': 'c.txt', 'line': 1, 'rule': 'github-token'}])

    def test_utf16_character_ending_in_a_line_feed_byte_after_an_ascii_character_keeps_its_own_line(self):
        value = 'gh' + 'p_' + 'H' * 36
        (self.root / 'a.txt').write_bytes(('a\u010a ' + value).encode('utf-16-le'))
        self.assertEqual(scanner.audit(self.root)['findings'], [{'file': 'a.txt', 'line': 1, 'rule': 'github-token'}])

    def test_utf16_secret_after_a_wide_character_and_line_feed_is_reported_once_on_its_line(self):
        value = 'gh' + 'p_' + 'C' * 36
        for codec in ('utf-16-le', 'utf-16-be'):
            (self.root / 'u.txt').write_bytes(('\u0100\n' + value).encode(codec))
            self.assertEqual(scanner.audit(self.root)['findings'], [{'file': 'u.txt', 'line': 2, 'rule': 'github-token'}], codec)

    def test_private_artifact_and_symlink_are_rejected(self):
        (self.root / 'credential.p12').write_bytes(b'not a real key')
        (self.root / 'source.txt').write_text('ordinary source')
        (self.root / 'alias.txt').symlink_to(self.root / 'source.txt')
        self.assertEqual({f['rule'] for f in scanner.audit(self.root)['findings']}, {'private-artifact', 'source-symlink'})

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
