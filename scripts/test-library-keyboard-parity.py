#!/usr/bin/env python3
"""Fail-closed verifier tests using intentionally synthetic acceptance reports."""
from pathlib import Path
import copy
import hashlib
import importlib.util
import json
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('library_keyboard_parity', ROOT / 'scripts/check-library-keyboard-parity.py')
CHECKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKER)
REVISION = 'a' * 40


class LibraryKeyboardParityTests(unittest.TestCase):
    def setUp(self):
        validation = ROOT / 'local/validation'; validation.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix='library-parity-test-', dir=validation)
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.contract_path = self.directory / 'contract.json'
        self.contract_path.write_bytes((ROOT / 'contracts/library-keyboard.json').read_bytes())
        self.contract, self.digest, self.expected, self.aliases = CHECKER.load_contract(self.contract_path)
        self.reports = {}
        # These fixtures test validator rejection rules. They are not executed
        # platform evidence and are never copied into release acceptance paths.
        for platform, (host, mode) in CHECKER.PLATFORMS.items():
            self.reports[platform] = {'schemaVersion': 1, 'contractId': self.contract['contractId'],
                'contractSHA256': self.digest, 'platform': platform, 'hostPlatform': host, 'mode': mode,
                'sourceRevision': REVISION, 'errors': [], 'observations': [
                    {'scenarioId': scenario, 'step': step, 'actual': copy.deepcopy(state)}
                    for (scenario, step), state in self.expected.items()]}

    def save(self):
        for platform, report in self.reports.items():
            (self.directory / (platform + '.json')).write_text(json.dumps(report))

    def verify(self):
        self.save()
        return CHECKER.verify(self.contract_path, self.directory / 'macos.json', self.directory / 'windows.json', REVISION)

    def rejected(self):
        with self.assertRaises(CHECKER.ParityError):
            self.verify()

    def rejected_contract(self):
        self.contract_path.write_text(json.dumps(self.contract)); self.rejected()

    def test_complete_observation_shape_and_literal_contract_count(self):
        result = self.verify()
        self.assertTrue(result['passed']); self.assertEqual(result['sourceRevision'], REVISION)
        self.assertEqual(result['contractSHA256'], hashlib.sha256(self.contract_path.read_bytes()).hexdigest())
        self.assertEqual(result['platforms'], ['macos', 'windows'])
        self.assertEqual(result['scenarios'], 11); self.assertEqual(result['observationsPerPlatform'], 92)

    def test_full_exact_source_revision_is_required_for_both_platforms(self):
        self.reports['windows']['sourceRevision'] = 'b' * 40; self.rejected()
        self.save()
        for revision in ['aaaaaaa', 'A' * 40, '', True, None]:
            with self.assertRaises(CHECKER.ParityError):
                CHECKER.verify(self.contract_path, self.directory / 'macos.json', self.directory / 'windows.json', revision)

    def test_windows_renderer_running_on_mac_cannot_count_as_windows_acceptance(self):
        self.reports['windows']['hostPlatform'] = 'darwin'; self.rejected()

    def test_mismatched_platform_or_adapter_mode_is_rejected(self):
        for platform in ['macos', 'windows']:
            original = copy.deepcopy(self.reports[platform])
            for key, value in [('mode', 'source-text-comparison'), ('platform', 'linux'), ('hostPlatform', 'linux')]:
                self.reports[platform] = dict(original, **{key: value}); self.rejected()
            self.reports[platform] = original

    def verify_linux(self):
        self.save()
        return CHECKER.verify(self.contract_path, self.directory / 'macos.json', self.directory / 'windows.json', REVISION,
                              self.directory / 'linux.json')

    def test_linux_renderer_report_is_verified_when_supplied(self):
        result = self.verify_linux()
        self.assertEqual(result['platforms'], ['macos', 'windows', 'linux'])
        for key, value in [('hostPlatform', 'win32'), ('platform', 'windows'), ('mode', 'model')]:
            original = copy.deepcopy(self.reports['linux']); self.reports['linux'][key] = value
            with self.assertRaises(CHECKER.ParityError): self.verify_linux()
            self.reports['linux'] = original
        self.reports['linux']['observations'].pop()
        with self.assertRaises(CHECKER.ParityError): self.verify_linux()

    def test_linux_policy_requires_linux_exception_text_and_is_closed(self):
        del self.contract['policy']['nativeExceptions'][0]['linux']; self.rejected_contract()
        self.contract['policy']['nativeExceptions'][0]['linux'] = 'primary=Control'
        self.contract['policy']['additionalPlatforms'] = ['freebsd']; self.rejected_contract()
        del self.contract['policy']['additionalPlatforms']; self.contract_path.write_text(json.dumps(self.contract))
        self.reports = {platform: dict(report, contractSHA256=hashlib.sha256(self.contract_path.read_bytes()).hexdigest())
                        for platform, report in self.reports.items()}
        self.assertEqual(self.verify()['platforms'], ['macos', 'windows'])
        with self.assertRaises(CHECKER.ParityError): self.verify_linux()

    def test_other_contract_or_hash_is_rejected(self):
        for key, value in [('contractSHA256', '0' * 64), ('contractId', 'clipboardline.shelves.v1')]:
            original = self.reports['windows'][key]; self.reports['windows'][key] = value
            self.rejected(); self.reports['windows'][key] = original

    def test_schema_is_exact_integer_one(self):
        for value in [True, None, 0, 2, '1']:
            self.reports['macos']['schemaVersion'] = value; self.rejected()

    def test_adapter_errors_or_missing_errors_are_rejected(self):
        for errors in [None, False, ['failure'], '']:
            self.reports['windows']['errors'] = errors; self.rejected()
        del self.reports['windows']['errors']; self.rejected()

    def test_missing_and_added_observations_are_rejected(self):
        original = copy.deepcopy(self.reports['windows']['observations'])
        self.reports['windows']['observations'].pop(); self.rejected()
        self.reports['windows']['observations'] = original + [original[0]]; self.rejected()

    def test_duplicate_observation_cannot_replace_missing_step(self):
        observations = self.reports['windows']['observations']
        observations[-1] = copy.deepcopy(observations[0]); self.rejected()

    def test_unknown_scenario_or_step_is_rejected(self):
        observation = self.reports['macos']['observations'][0]
        for key, value in [('scenarioId', 'unknown'), ('step', -1), ('step', 10000), ('step', True), ('step', '0')]:
            original = observation[key]; observation[key] = value; self.rejected(); observation[key] = original

    def test_different_executed_navigation_is_rejected(self):
        self.reports['windows']['observations'][0]['actual'].update(focused='t1', selected=['t1']); self.rejected()

    def test_range_selection_is_allowed_but_visible_order_and_uniqueness_are_required(self):
        observation = next(item for item in self.reports['macos']['observations'] if len(item['actual']['selected']) > 1)
        original = copy.deepcopy(observation['actual']['selected'])
        observation['actual']['selected'] = list(reversed(original)); self.rejected()
        observation['actual']['selected'] = original + [original[0]]; self.rejected()

    def test_unknown_or_hidden_focus_is_rejected(self):
        observation = next(item for item in self.reports['macos']['observations'] if item['actual']['kind'] == 'text')
        for focused in ['unknown', 'i1', None, {}, []]:
            observation['actual']['focused'] = focused; self.rejected()

    def test_wrong_search_kind_scope_and_list_flags_are_rejected(self):
        observation = self.reports['windows']['observations'][0]
        original = copy.deepcopy(observation['actual'])
        for key, value in [('search', 'unexpected query'), ('kind', 'text'), ('scope', 'trash'),
                           ('kind', {}), ('scope', []), ('list', 0), ('pinnedOnly', 0)]:
            observation['actual'] = dict(original, **{key: value}); self.rejected()

    def test_stale_trash_or_pin_state_is_rejected(self):
        observation = self.reports['windows']['observations'][0]
        original = copy.deepcopy(observation['actual'])
        for key, value in [('trashed', ['i1']), ('pinned', []), ('pinned', ['t2', 'i1']), ('trashed', ['unknown'])]:
            observation['actual'] = dict(original, **{key: value}); self.rejected()

    def test_missing_and_extra_snapshot_fields_are_rejected(self):
        state = self.reports['macos']['observations'][0]['actual']
        state['assumedFocusSuccess'] = True; self.rejected(); del state['assumedFocusSuccess']
        del state['selected']; self.rejected()

    def test_both_default_platforms_and_page_size_must_remain_explicit(self):
        original = copy.deepcopy(self.contract)
        for key, value in [('defaultPlatforms', ['macos']), ('pageSize', 8), ('pageSize', True), ('editingKeys', '')]:
            self.contract = copy.deepcopy(original); self.contract['policy'][key] = value; self.rejected_contract()

    def test_native_exception_requires_both_platforms_and_reason(self):
        del self.contract['policy']['nativeExceptions'][0]['reason']; self.rejected_contract()

    def test_duplicate_native_exception_is_rejected(self):
        values = self.contract['policy']['nativeExceptions']; values.append(copy.deepcopy(values[0])); self.rejected_contract()

    def test_duplicate_scenario_or_record_alias_is_rejected(self):
        original = copy.deepcopy(self.contract)
        self.contract['scenarios'].append(copy.deepcopy(self.contract['scenarios'][0])); self.rejected_contract()
        self.contract = original; self.contract['records'].append(copy.deepcopy(self.contract['records'][0])); self.rejected_contract()

    def test_unknown_actions_cannot_skip_execution(self):
        self.contract['scenarios'][0]['steps'][0]['action'] = 'pretend-open'; self.rejected_contract()

    def test_action_extra_fields_cannot_silently_change_inputs(self):
        self.contract['scenarios'][0]['steps'][0]['disabled'] = True; self.rejected_contract()

    def test_malformed_key_inputs_are_rejected(self):
        original = copy.deepcopy(self.contract)
        for values in [{'code': 'KeyQ'}, {'modifiers': ['super']}, {'modifiers': ['shift', 'shift']},
                       {'modifiers': [{}]}, {'editing': 1}, {'code': []}]:
            self.contract = copy.deepcopy(original)
            self.contract['scenarios'][0]['steps'][1].update(values); self.rejected_contract()

    def test_malformed_remap_inputs_are_rejected(self):
        original = copy.deepcopy(self.contract)
        for values in [{'binding': 'up'}, {'key': []}, {'key': 'KeyQ'}]:
            self.contract = copy.deepcopy(original)
            scenario = next(item for item in self.contract['scenarios'] if 'remap-disable' in item['id'])
            scenario['steps'][1].update(values); self.rejected_contract()

    def test_grid_columns_and_search_mode_fail_closed(self):
        original = copy.deepcopy(self.contract)
        for key, value in [('columns', True), ('columns', 0), ('columns', -1), ('searchMode', 'unknown'), ('searchMode', {})]:
            self.contract = copy.deepcopy(original); self.contract['scenarios'][0][key] = value; self.rejected_contract()

    def test_unknown_view_alias_or_duplicate_visible_record_is_rejected(self):
        original = copy.deepcopy(self.contract)
        self.contract['scenarios'][0]['steps'][0]['expect']['visible'] = 'missing-view'; self.rejected_contract()
        self.contract = original; self.contract['views']['all'].append('i1'); self.rejected_contract()

    def test_unknown_record_in_named_view_is_rejected(self):
        self.contract['views']['all'].append('missing-item'); self.rejected_contract()

    def test_fixture_flags_must_be_booleans_and_kind_valid(self):
        original = copy.deepcopy(self.contract)
        for key, value in [('onShelf', 1), ('pinned', 0), ('kind', []), ('kind', 'video')]:
            self.contract = copy.deepcopy(original); self.contract['records'][0][key] = value; self.rejected_contract()

    def test_contract_schema_and_identity_are_validated(self):
        original = copy.deepcopy(self.contract)
        for key, value in [('schemaVersion', True), ('schemaVersion', 2), ('contractId', 'clipboardline.shelves.v1')]:
            self.contract = copy.deepcopy(original); self.contract[key] = value; self.rejected_contract()

    def test_duplicate_json_property_is_rejected(self):
        self.save(); path = self.directory / 'macos.json'
        path.write_text(path.read_text().replace('"errors": []', '"errors": [], "errors": []'))
        with self.assertRaises(CHECKER.ParityError):
            CHECKER.verify(self.contract_path, path, self.directory / 'windows.json', REVISION)

    def test_nonfinite_json_constant_is_rejected(self):
        self.save(); path = self.directory / 'windows.json'
        path.write_text(path.read_text().replace('"errors": []', '"errors": NaN'))
        with self.assertRaises(CHECKER.ParityError):
            CHECKER.verify(self.contract_path, self.directory / 'macos.json', path, REVISION)

    def test_missing_empty_and_symlinked_reports_are_rejected(self):
        self.save(); path = self.directory / 'windows.json'; path.unlink()
        for action in ['missing', 'empty', 'symlink']:
            if action == 'empty': path.touch()
            if action == 'symlink': path.unlink(); path.symlink_to(self.directory / 'macos.json')
            with self.assertRaises(CHECKER.ParityError):
                CHECKER.verify(self.contract_path, self.directory / 'macos.json', path, REVISION)


if __name__ == '__main__':
    unittest.main()
