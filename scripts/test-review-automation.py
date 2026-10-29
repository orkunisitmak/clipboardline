#!/usr/bin/env python3
"""Offline phase-one safety tests, not a replacement for Mergify's simulator.

Requires requirements-review-automation.txt. Optional --schema-dir points to
separately downloaded official schemas; this script never downloads or executes
PR code, calls GitHub, or activates either service.
"""
from pathlib import Path
import argparse
import copy
import json
import re
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
COMMANDS = {'backport', 'copy', 'dequeue', 'queue', 'rebase', 'refresh', 'requeue', 'squash', 'update'}
LABELS = {'triage/needs-maintainer', 'triage/dependencies', 'triage/sensitive',
          'triage/conflict', 'triage/ci-attention', 'triage/localization'}


class UniqueLoader(yaml.SafeLoader):
    pass


def unique_mapping(loader, node, deep=False):
    result = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in result:
            raise ValueError('Duplicate YAML key: ' + str(key))
        result[key] = loader.construct_object(value_node, deep=deep)
    return result


UniqueLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, unique_mapping)


def read_config(path):
    data = path.read_text(encoding='utf-8')
    if len(data.encode()) > 256 * 1024:
        raise ValueError('Unexpected configuration size')
    if any(isinstance(t, (yaml.tokens.AnchorToken, yaml.tokens.AliasToken)) for t in yaml.scan(data)):
        raise ValueError('Aliases and anchors are outside this reviewed policy')
    return yaml.load(data, Loader=UniqueLoader)


def condition_matches(condition, facts):
    """Evaluate only the documented condition subset actually used in this file."""
    if isinstance(condition, dict):
        if set(condition) != {'or'} or not isinstance(condition['or'], list):
            raise ValueError('Unsupported condition group')
        values = [condition_matches(c, facts) for c in condition['or']]
        return any(values)
    if condition == 'base = main':
        return facts.get('base') == 'main'
    if condition == '-closed':
        return facts.get('closed') is False
    if condition == 'conflict':
        return facts.get('conflict') is True
    if condition == 'author = dependabot[bot]':
        return facts.get('author') == 'dependabot[bot]'
    sender = re.fullmatch(r'sender (!=|=) orkunisitmak', condition)
    if sender:
        equals = facts.get('sender') == 'orkunisitmak'
        return equals if sender[1] == '=' else not equals
    if condition.startswith('files ~= '):
        pattern = re.compile(condition[len('files ~= '):])
        return any(pattern.search(p) for p in facts.get('files', []))
    match = re.fullmatch(r'#(check-failure|check-pending|check-stale) > 0', condition)
    if match:
        return len(facts.get(match[1], [])) > 0
    raise ValueError('Unsupported condition: ' + str(condition))


def assert_observation_only(coderabbit, mergify):
    # Allow only categorization. Reject future action-bearing top-level sections,
    # including auto_merge_conditions: [] / false, imports and inherited defaults.
    assert set(mergify) == {'commands_restrictions', 'pull_request_rules'}
    assert set(mergify['commands_restrictions']) == COMMANDS
    for restrictions in mergify['commands_restrictions'].values():
        assert restrictions == {'conditions': ['sender = orkunisitmak', 'sender != orkunisitmak']}
    rules = mergify['pull_request_rules']
    assert len(rules) == 6
    assert len({r['name'] for r in rules}) == len(rules)
    seen_labels = set()
    for rule in rules:
        assert set(rule) == {'name', 'conditions', 'actions'}
        assert 'base = main' in rule['conditions'] and '-closed' in rule['conditions']
        assert set(rule['actions']) == {'label'}
        action = rule['actions']['label']
        assert set(action) == {'toggle'}
        assert len(action['toggle']) == 1 and action['toggle'][0] in LABELS
        seen_labels.update(action['toggle'])
        # Validate every condition, even a branch that would short-circuit.
        for condition in rule['conditions']:
            condition_matches(condition, {})
    assert seen_labels == LABELS
    assert coderabbit['language'] == 'tr' and coderabbit['inheritance'] is False
    reviews = coderabbit['reviews']
    assert reviews['auto_approvals'] == {'enabled': False, 'allow_author_approval': False}
    assert 'request_changes_workflow' not in reviews
    assert reviews.get('path_filters', []) == []  # Do not hide lockfiles/generated catalogs.
    assert reviews['auto_apply_labels'] is False and reviews['auto_assign_reviewers'] is False
    assert reviews['slop_detection']['enabled'] is False
    assert reviews['auto_review']['drafts'] is False
    assert reviews['auto_review']['auto_incremental_review'] is True
    finishing = reviews['finishing_touches']
    assert set(finishing) == {'docstrings', 'unit_tests', 'simplify', 'autofix',
                             'fix_ci', 'resolve_merge_conflict', 'custom'}
    assert all(v == {'enabled': False} for k, v in finishing.items() if k != 'custom')
    assert finishing['custom'] == [] and reviews['post_merge_actions'] == []
    assert coderabbit['chat']['auto_reply'] is False
    assert all(v['usage'] == 'disabled' for v in coderabbit['chat']['integrations'].values())
    assert coderabbit['knowledge_base']['linked_repositories'] == []
    assert coderabbit['knowledge_base']['web_search']['enabled'] is False
    issue = coderabbit['issue_enrichment']
    assert issue['labeling']['auto_apply_labels'] is False
    assert issue['planning']['enabled'] is False
    assert issue['planning']['auto_planning']['enabled'] is False


def labels_for(config, **facts):
    facts = {'base': 'main', 'closed': False, 'conflict': False,
             'author': 'external-contributor', 'files': [], **facts}
    result = set()
    for rule in config['pull_request_rules']:
        if all(condition_matches(c, facts) for c in rule['conditions']):
            result.update(rule['actions']['label']['toggle'])
    return result


class ObservationPolicyTests(unittest.TestCase):
    def setUp(self):
        self.cr = read_config(ROOT / '.coderabbit.yaml')
        self.m = read_config(ROOT / '.mergify.yml')

    def test_actual_configuration_has_no_merge_or_code_writing_lane(self):
        assert_observation_only(self.cr, self.m)

    def test_docs_only_still_needs_maintainer(self):
        self.assertEqual(labels_for(self.m, files=['docs/library-keyboard.md']), {'triage/needs-maintainer'})

    def test_external_code_cannot_become_merge_authorized_by_labels_or_ai(self):
        labels = labels_for(self.m, files=['windows/main.cjs'], labels=['bug', 'safe-to-merge'],
                            ai_approved=True, additions=1, human_approved=True, current_ci=True)
        self.assertEqual(labels, {'triage/needs-maintainer', 'triage/sensitive'})
        assert_observation_only(self.cr, self.m)

    def test_dependencies_are_informational_even_for_the_real_bot(self):
        self.assertEqual(labels_for(self.m, author='dependabot[bot]', files=['windows/package-lock.json']),
                         {'triage/needs-maintainer', 'triage/dependencies', 'triage/sensitive'})

    def test_dependency_file_is_classified_without_trusting_author(self):
        self.assertIn('triage/dependencies', labels_for(self.m, files=['windows/package.json']))

    def test_conflicted_localization_keeps_human_decision(self):
        self.assertEqual(labels_for(self.m, conflict=True,
                         files=['Sources/Tendedero/Resources/tr.lproj/Localizable.strings', 'windows/locales.js']),
                         {'triage/needs-maintainer', 'triage/sensitive', 'triage/localization', 'triage/conflict'})

    def test_missing_checks_never_produce_a_ready_label(self):
        self.assertEqual(labels_for(self.m, files=['README.md']), {'triage/needs-maintainer'})

    def test_failed_pending_and_stale_checks_need_attention(self):
        for key in ['check-failure', 'check-pending', 'check-stale']:
            with self.subTest(key=key):
                self.assertIn('triage/ci-attention', labels_for(self.m, **{key: ['windows']}))

    def test_sensitive_rename_matches_both_paths(self):
        self.assertIn('triage/sensitive', labels_for(self.m, files=['.github/workflows/security.yml', 'docs/old.txt']))

    def test_policy_workflows_native_code_and_identity_files_are_sensitive(self):
        for path in ['.coderabbit.yaml', '.mergify.yml', '.github/CODEOWNERS', 'AGENTS.md',
                     'Sources/Tendedero/PublicLinkNetwork.swift', 'Sources/UpdateInstaller/main.swift',
                     'windows/preload.cjs', 'windows/lib/network.cjs', 'windows/native/windows-bridge.ps1',
                     'scripts/check-secrets.py', 'contracts/shelf-behavior.json', 'Package.swift',
                     'update-config.json', 'credential-broker-config.json']:
            with self.subTest(path=path):
                self.assertIn('triage/sensitive', labels_for(self.m, files=[path]))

    def test_closed_and_other_base_prs_do_not_match(self):
        self.assertEqual(labels_for(self.m, closed=True), set())
        self.assertEqual(labels_for(self.m, base='release/1.7'), set())

    def test_draft_pr_has_only_informational_labels(self):
        self.assertEqual(labels_for(self.m, draft=True), {'triage/needs-maintainer'})

    def test_all_commands_are_denied_even_for_owner(self):
        for name, rule in self.m['commands_restrictions'].items():
            for sender in ['orkunisitmak', 'external-contributor', 'dependabot[bot]']:
                with self.subTest(command=name, sender=sender):
                    self.assertFalse(all(condition_matches(c, {'sender': sender}) for c in rule['conditions']))
                    self.assertEqual(rule['conditions'], ['sender = orkunisitmak', 'sender != orkunisitmak'])

    def test_injected_merge_action_is_rejected(self):
        self.m['pull_request_rules'][0]['actions']['merge'] = {}
        with self.assertRaises(AssertionError):
            assert_observation_only(self.cr, self.m)

    def test_auto_merge_queue_or_import_settings_are_rejected(self):
        for key, value in [('merge_protections_settings', {'auto_merge_conditions': []}),
                           ('merge_protections_settings', {'auto_merge_conditions': False}),
                           ('queue_rules', []), ('merge_queue', {}), ('defaults', {}), ('extends', 'other/repo')]:
            with self.subTest(key=key, value=value):
                altered = copy.deepcopy(self.m); altered[key] = value
                with self.assertRaises(AssertionError):
                    assert_observation_only(self.cr, altered)

    def test_ai_approval_and_fix_features_cannot_be_enabled(self):
        for key in ['autofix', 'fix_ci', 'resolve_merge_conflict', 'unit_tests', 'docstrings', 'simplify']:
            altered = copy.deepcopy(self.cr); altered['reviews']['finishing_touches'][key]['enabled'] = True
            with self.subTest(feature=key), self.assertRaises(AssertionError):
                assert_observation_only(altered, self.m)
        self.cr['reviews']['auto_approvals']['enabled'] = True
        with self.assertRaises(AssertionError):
            assert_observation_only(self.cr, self.m)

    def test_ready_label_and_review_action_are_rejected(self):
        altered = copy.deepcopy(self.m)
        altered['pull_request_rules'][0]['actions']['label']['toggle'] = ['safe-to-merge']
        with self.assertRaises(AssertionError):
            assert_observation_only(self.cr, altered)
        self.m['pull_request_rules'][0]['actions'] = {'review': {'type': 'APPROVE'}}
        with self.assertRaises(AssertionError):
            assert_observation_only(self.cr, self.m)

    def test_unknown_condition_and_duplicate_yaml_keys_are_rejected(self):
        with self.assertRaises(ValueError):
            condition_matches('label = safe-to-merge', {})
        with self.assertRaises(ValueError):
            yaml.load('enabled: false\nenabled: true\n', Loader=UniqueLoader)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--schema-dir', type=Path)
    args = parser.parse_args()
    if args.schema_dir:
        import jsonschema
        for config, schema in [('.coderabbit.yaml', 'coderabbit-schema.json'), ('.mergify.yml', 'mergify-schema.json')]:
            definition = json.loads((args.schema_dir / schema).read_text())
            validator = jsonschema.validators.validator_for(definition)
            validator.check_schema(definition)
            validator(definition).validate(read_config(ROOT / config))
            print('PASS official JSON schema: ' + config, flush=True)
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(ObservationPolicyTests))
    print('Scope: offline observation-policy tests; live service/condition simulation requires an approved App installation.')
    return 0 if result.wasSuccessful() else 1


if __name__ == '__main__':
    raise SystemExit(main())
