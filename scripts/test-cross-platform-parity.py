#!/usr/bin/env python3
"""Exercise the fail-closed parity verifier with synthetic report mutations."""
from pathlib import Path
import copy
import hashlib
import importlib.util
import json
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('cross_platform_parity', ROOT / 'scripts/check-cross-platform-parity.py')
CHECKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKER)
REVISION = 'a' * 40


class CrossPlatformParityTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='clipboardline-parity-test-')
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.contract_path = self.directory / 'contract.json'
        self.contract_path.write_bytes((ROOT / 'contracts/shelf-behavior.json').read_bytes())
        self.contract, self.digest, self.expected, self.aliases = CHECKER.load_contract(self.contract_path)
        self.reports = {}
        for platform, (host, mode) in CHECKER.PLATFORMS.items():
            self.reports[platform] = {'schemaVersion': 1, 'contractId': self.contract['contractId'],
                'contractSHA256': self.digest, 'platform': platform, 'hostPlatform': host, 'mode': mode,
                'sourceRevision': REVISION, 'errors': [], 'observations': [
                    {'scenarioId': scenario, 'step': step, 'actual': copy.deepcopy(expected)}
                    for (scenario, step), expected in self.expected.items()]}
        self.save()

    def save(self):
        for platform, report in self.reports.items():
            (self.directory / (platform + '.json')).write_text(json.dumps(report))

    def verify(self):
        self.save()
        return CHECKER.verify(self.contract_path, self.directory / 'macos.json',
                              self.directory / 'windows.json', REVISION)

    def rejected(self):
        with self.assertRaises(CHECKER.ParityError):
            self.verify()

    def test_complete_actual_observation_shape_accepts_both_platforms(self):
        result = self.verify()
        self.assertTrue(result['passed'])
        self.assertEqual(result['sourceRevision'], REVISION)
        self.assertEqual(result['contractSHA256'], hashlib.sha256(self.contract_path.read_bytes()).hexdigest())
        self.assertEqual(result['platforms'], ['macos', 'windows'])
        self.assertEqual(result['observationsPerPlatform'], len(self.expected))

    def test_wrong_source_revision_is_rejected(self):
        self.reports['windows']['sourceRevision'] = 'b' * 40
        self.rejected()

    def test_abbreviated_expected_source_is_rejected(self):
        self.save()
        with self.assertRaises(CHECKER.ParityError):
            CHECKER.verify(self.contract_path, self.directory / 'macos.json', self.directory / 'windows.json', 'aaaaaaa')

    def test_windows_renderer_on_mac_is_not_windows_acceptance(self):
        self.reports['windows']['hostPlatform'] = 'darwin'
        self.rejected()

    def test_wrong_adapter_mode_is_rejected(self):
        self.reports['macos']['mode'] = 'source-text-comparison'
        self.rejected()

    def test_wrong_contract_bytes_are_rejected(self):
        self.reports['windows']['contractSHA256'] = '0' * 64
        self.rejected()

    def test_wrong_report_schema_is_rejected_including_boolean(self):
        for value in [0, 2, True, '1', None]:
            self.reports['macos']['schemaVersion'] = value
            self.rejected()

    def test_execution_error_is_rejected(self):
        self.reports['windows']['errors'] = ['synthetic execution failure']
        self.rejected()

    def test_missing_errors_array_is_rejected(self):
        del self.reports['windows']['errors']
        self.rejected()

    def test_missing_observation_is_rejected(self):
        self.reports['windows']['observations'].pop()
        self.rejected()

    def test_extra_observation_is_rejected(self):
        self.reports['windows']['observations'].append(copy.deepcopy(self.reports['windows']['observations'][0]))
        self.rejected()

    def test_duplicate_observation_cannot_replace_a_missing_step(self):
        self.reports['windows']['observations'][-1] = copy.deepcopy(self.reports['windows']['observations'][0])
        self.rejected()

    def test_unknown_scenario_is_rejected(self):
        self.reports['macos']['observations'][0]['scenarioId'] = 'not-in-contract'
        self.rejected()

    def test_boolean_step_index_is_not_integer_step_one(self):
        self.reports['macos']['observations'][1]['step'] = True
        self.rejected()

    def test_different_executed_selection_is_rejected(self):
        self.reports['windows']['observations'][0]['actual'].update({'focused': 't1', 'selected': ['t1'], 'activeKind': 'text'})
        self.rejected()

    def test_multiple_selected_rows_are_rejected(self):
        self.reports['windows']['observations'][0]['actual']['selected'] = ['i1', 't1']
        self.rejected()

    def test_hidden_or_unknown_focus_is_rejected(self):
        self.reports['macos']['observations'][0]['actual']['focused'] = 'not-an-item'
        self.rejected()

    def test_missing_snapshot_field_is_rejected(self):
        del self.reports['macos']['observations'][0]['actual']['searchEditing']
        self.rejected()

    def test_extra_snapshot_field_is_rejected(self):
        self.reports['macos']['observations'][0]['actual']['assumedSuccess'] = True
        self.rejected()

    def test_malformed_uploaded_snapshot_is_rejected(self):
        for bad in [['not-an-item'], ['t1', 'i1'], ['i1', 'i1'], 'i1']:
            self.reports['windows']['observations'][0]['actual']['uploaded'] = bad
            self.rejected()

    def test_missing_both_platform_default_is_rejected(self):
        self.contract['policy']['defaultPlatforms'] = ['macos']
        self.contract_path.write_text(json.dumps(self.contract))
        self.rejected()

    def test_undocumented_native_exception_is_rejected(self):
        del self.contract['policy']['nativeExceptions'][0]['reason']
        self.contract_path.write_text(json.dumps(self.contract))
        self.rejected()

    def test_duplicate_scenario_or_item_alias_is_rejected(self):
        original = copy.deepcopy(self.contract)
        self.contract['scenarios'].append(copy.deepcopy(self.contract['scenarios'][0]))
        self.contract_path.write_text(json.dumps(self.contract)); self.rejected()
        self.contract = original
        values = self.contract['itemSets']['standard']; values.append(copy.deepcopy(values[0]))
        self.contract_path.write_text(json.dumps(self.contract)); self.rejected()

    def test_unknown_actions_cannot_silently_skip_execution(self):
        self.contract['scenarios'][0]['steps'][0]['action'] = 'pretend-open'
        self.contract_path.write_text(json.dumps(self.contract)); self.rejected()

    def test_malformed_shortcut_steps_cannot_skip_or_change_executed_input(self):
        original = copy.deepcopy(self.contract)
        for step in [{'action':'remap','binding':'down'}, {'action':'remap','binding':'up','key':'KeyX'},
                     {'action':'remap','binding':'down','key':[]}, {'action':'key','code':'KeyY'}]:
            self.contract = copy.deepcopy(original)
            self.contract['scenarios'][0]['steps'][0].update(step)
            self.contract_path.write_text(json.dumps(self.contract)); self.rejected()

    def test_malformed_contract_collections_fail_closed(self):
        for key, value in [('itemSet', {}), ('pinnedOnlyKinds', [{}])]:
            contract = copy.deepcopy(self.contract); contract['scenarios'][0][key] = value
            self.contract_path.write_text(json.dumps(contract)); self.rejected()

    def test_duplicate_json_properties_are_rejected(self):
        self.save()
        path = self.directory / 'macos.json'
        path.write_text(path.read_text().replace('"errors": []', '"errors": [], "errors": []'))
        with self.assertRaises(CHECKER.ParityError):
            CHECKER.verify(self.contract_path, path, self.directory / 'windows.json', REVISION)

    def test_nonfinite_json_constants_are_rejected(self):
        self.save()
        path = self.directory / 'macos.json'
        path.write_text(path.read_text().replace('"errors": []', '"errors": NaN'))
        with self.assertRaises(CHECKER.ParityError):
            CHECKER.verify(self.contract_path, path, self.directory / 'windows.json', REVISION)

    def test_missing_input_file_is_rejected(self):
        self.save(); (self.directory / 'windows.json').unlink()
        with self.assertRaises(CHECKER.ParityError):
            CHECKER.verify(self.contract_path, self.directory / 'macos.json', self.directory / 'windows.json', REVISION)


if __name__ == '__main__':
    unittest.main()
