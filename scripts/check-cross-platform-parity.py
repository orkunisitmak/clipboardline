#!/usr/bin/env python3
"""Verify executed Mac/Windows observations against the same behavioral contract.

Reports are evidence, not signatures. Release tooling must separately authenticate
successful CI runs and artifact digests for the exact public source revision.
No source-text matching or implementation-shaped assertions are used here.
"""
from pathlib import Path
import argparse
import hashlib
import json
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
KINDS = ['image', 'text', 'link']
FIELDS = {'activeKind', 'focused', 'selected', 'visibleKinds', 'searchEditing', 'uploaded'}
ACTIONS = {'open', 'close', 'up', 'down', 'left', 'right', 'toggle', 'openSearch', 'finishSearch', 'remap', 'key'}
PLATFORMS = {'macos': ('darwin', 'model'), 'windows': ('win32', 'renderer')}


class ParityError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise ParityError(message)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'Duplicate JSON property in parity input')
        result[key] = value
    return result


def reject_constant(_):
    raise ParityError('Non-finite JSON constant in parity input')


def read_json(path):
    path = Path(path)
    require(path.is_file() and not path.is_symlink(), 'Parity input must be a regular file')
    require(0 < path.stat().st_size <= 8 * 1024 * 1024, 'Parity input has an invalid size')
    try:
        data = path.read_bytes()
        return json.loads(data, object_pairs_hook=unique_object, parse_constant=reject_constant), data
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ParityError('Parity input is not readable JSON') from error


def valid_ordered_kinds(values):
    return isinstance(values, list) and bool(values) and values == [kind for kind in KINDS if kind in values]


def valid_snapshot(value, aliases):
    if not isinstance(value, dict) or set(value) != FIELDS:
        return False
    if not valid_ordered_kinds(value['visibleKinds']) or value['activeKind'] not in value['visibleKinds']:
        return False
    if type(value['searchEditing']) is not bool:
        return False
    selected = value['selected']
    if not isinstance(selected, list) or not all(isinstance(item, str) and item in aliases for item in selected):
        return False
    if selected != sorted(set(selected)):
        return False
    uploaded = value['uploaded']
    if not isinstance(uploaded, list) or not all(isinstance(item, str) and item in aliases for item in uploaded):
        return False
    if uploaded != sorted(set(uploaded)):
        return False
    focused = value['focused']
    return ((focused is None and selected == []) or
            (isinstance(focused, str) and focused in aliases and selected == [focused] and
             aliases[focused] == value['activeKind']))


def load_contract(path):
    contract, data = read_json(path)
    require(isinstance(contract, dict) and type(contract.get('schemaVersion')) is int and
            contract['schemaVersion'] == 1 and contract.get('contractId') == 'clipboardline.shelves.v1',
            'Unknown cross-platform contract identity or schema')
    policy = contract.get('policy')
    require(isinstance(policy, dict) and policy.get('defaultPlatforms') == ['macos', 'windows'] and
            isinstance(policy.get('futureUserVisibleChanges'), str) and policy['futureUserVisibleChanges'].strip() and
            isinstance(policy.get('scope'), str) and policy['scope'].strip(),
            'Contract must retain both default platforms and the extension policy')
    exceptions = policy.get('nativeExceptions')
    require(isinstance(exceptions, list) and all(isinstance(item, dict) and all(
        isinstance(item.get(key), str) and item[key].strip() for key in ['id', 'macos', 'windows', 'reason'])
        for item in exceptions), 'OS-native exceptions require an explicit reason on both platforms')
    require(len({item['id'] for item in exceptions}) == len(exceptions), 'Duplicate OS-native exception')
    item_sets, scenarios = contract.get('itemSets'), contract.get('scenarios')
    require(isinstance(item_sets, dict) and bool(item_sets) and isinstance(scenarios, list) and bool(scenarios),
            'Shared fixtures and scenarios are required')
    for values in item_sets.values():
        require(isinstance(values, list) and all(isinstance(item, dict) and
            isinstance(item.get('id'), str) and re.fullmatch(r'[a-z0-9][a-z0-9-]*', item['id']) and
            item.get('kind') in KINDS and isinstance(item.get('text'), str) for item in values),
            'Malformed shared item fixture')
        require(len({item['id'] for item in values}) == len(values), 'Duplicate fixture item alias')
    expected, aliases_by_scenario = {}, {}
    scenario_ids = set()
    for scenario in scenarios:
        require(isinstance(scenario, dict), 'Malformed shared scenario')
        identifier = scenario.get('id')
        require(isinstance(identifier, str) and re.fullmatch(r'[a-z0-9][a-z0-9-]*', identifier) and
                identifier not in scenario_ids, 'Missing, invalid or duplicate shared scenario ID')
        scenario_ids.add(identifier)
        require(isinstance(scenario.get('itemSet'), str) and scenario['itemSet'] in item_sets and valid_ordered_kinds(scenario.get('visibleKinds')),
                'Scenario fixture or visible shelf scope is invalid')
        pinned = scenario.get('pinnedOnlyKinds')
        require(isinstance(pinned, list) and all(isinstance(kind, str) and kind in KINDS for kind in pinned) and
                len(set(pinned)) == len(pinned), 'Scenario pinned filter scope is invalid')
        aliases = {item['id']: item['kind'] for item in item_sets[scenario['itemSet']]}
        aliases_by_scenario[identifier] = aliases
        steps = scenario.get('steps')
        require(isinstance(steps, list) and bool(steps), 'Scenario has no executed steps')
        for index, step in enumerate(steps):
            require(isinstance(step, dict) and isinstance(step.get('action'), str) and step['action'] in ACTIONS and
                    (step['action'] != 'toggle' or step.get('kind') in KINDS), 'Unknown shared fixture action')
            if step['action'] == 'remap':
                require(step.get('binding') in {'down', 'upload'} and 'key' in step and
                        (step['key'] is None or isinstance(step['key'], str) and step['key'] in {'', 'KeyX'}),
                        'Unsupported shared shortcut mapping')
            if step['action'] == 'key':
                require(step.get('code') in {'KeyX', 'KeyU'}, 'Unsupported shared keyboard input')
            require(valid_snapshot(step.get('expect'), aliases), 'Malformed expected shared state')
            expected[(identifier, index)] = step['expect']
    return contract, hashlib.sha256(data).hexdigest(), expected, aliases_by_scenario


def validate_platform_report(path, platform, source_revision, contract, contract_hash, expected, aliases):
    report, _ = read_json(path)
    host, mode = PLATFORMS[platform]
    require(isinstance(report, dict) and type(report.get('schemaVersion')) is int and report['schemaVersion'] == 1,
            'Unknown parity report schema')
    require(report.get('contractId') == contract['contractId'] and report.get('contractSHA256') == contract_hash,
            'Parity report belongs to another behavioral contract')
    require(report.get('platform') == platform and report.get('hostPlatform') == host and report.get('mode') == mode,
            'Parity report has the wrong platform, native host or adapter mode')
    require(report.get('sourceRevision') == source_revision, 'Parity report belongs to another source revision')
    require(report.get('errors') == [], 'Parity adapter reported execution errors')
    observations = report.get('observations')
    require(isinstance(observations, list) and len(observations) == len(expected),
            'Parity report omits or adds shared observations')
    observed = set()
    for observation in observations:
        require(isinstance(observation, dict) and isinstance(observation.get('scenarioId'), str) and
                type(observation.get('step')) is int, 'Malformed parity observation identity')
        key = (observation['scenarioId'], observation['step'])
        require(key in expected and key not in observed, 'Unknown or duplicate parity observation')
        observed.add(key)
        actual = observation.get('actual')
        require(valid_snapshot(actual, aliases[key[0]]) and actual == expected[key],
                'Executed behavior differs from the shared contract at ' + key[0] + ':' + str(key[1]))
    require(observed == set(expected), 'Parity report is incomplete')
    return report


def verify(contract_path, macos_report, windows_report, source_revision):
    require(isinstance(source_revision, str) and re.fullmatch(r'[0-9a-f]{40}', source_revision),
            'An exact full public source revision is required')
    contract, digest, expected, aliases = load_contract(contract_path)
    for platform, path in [('macos', macos_report), ('windows', windows_report)]:
        validate_platform_report(path, platform, source_revision, contract, digest, expected, aliases)
    return {'passed': True, 'sourceRevision': source_revision, 'contractId': contract['contractId'],
            'contractSHA256': digest, 'platforms': ['macos', 'windows'],
            'scenarios': len(contract['scenarios']), 'observationsPerPlatform': len(expected),
            'scope': contract['policy']['scope']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--contract', type=Path, default=ROOT / 'contracts/shelf-behavior.json')
    parser.add_argument('--macos-report', type=Path, required=True)
    parser.add_argument('--windows-report', type=Path, required=True)
    parser.add_argument('--source-revision', required=True)
    parser.add_argument('--report', type=Path)
    arguments = parser.parse_args()
    try:
        result = verify(arguments.contract, arguments.macos_report, arguments.windows_report, arguments.source_revision)
        if arguments.report:
            arguments.report.parent.mkdir(parents=True, exist_ok=True)
            arguments.report.write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result, indent=2))
        return 0
    except (ParityError, OSError) as error:
        print('Cross-platform acceptance rejected: ' + str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
