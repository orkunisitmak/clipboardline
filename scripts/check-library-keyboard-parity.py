#!/usr/bin/env python3
"""Validate executed native-platform Library keyboard contract observations.

The reports prove executed adapter behavior, not authenticity. The publisher must
separately authenticate successful native CI runs/artifact digests for this exact
public source revision. Renderer tests run on macOS are not Windows acceptance.
"""
from pathlib import Path
import argparse
import hashlib
import json
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
KINDS = {'image', 'text', 'link'}
FIELDS = {'focused', 'selected', 'visible', 'scope', 'kind', 'search', 'list', 'trashed', 'pinned', 'pinnedOnly'}
PLATFORMS = {'macos': ('darwin', 'model'), 'windows': ('win32', 'renderer'), 'linux': ('linux', 'renderer')}
# Linux ships the Windows Electron renderer. Its report is verified when supplied;
# the Mac and Windows reports remain mandatory for every publication.
ADDITIONAL_PLATFORMS = ['linux']
KEYS = {'ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown', 'KeyA', 'KeyF', 'KeyJ', 'KeyP', 'KeyS', 'KeyZ',
        'Digit0', 'Digit1', 'Digit2', 'Digit3', 'Backspace', 'Delete', 'Enter', 'Space', 'Escape', 'F6', 'Tab'}
MODIFIERS = {'primary', 'control', 'alt', 'shift'}


class ParityError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise ParityError(message)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'Duplicate JSON property in Library parity input')
        result[key] = value
    return result


def reject_constant(_):
    raise ParityError('Non-finite JSON constant in Library parity input')


def read_json(path):
    path = Path(path)
    require(path.is_file() and not path.is_symlink(), 'Library parity input must be a regular file')
    require(0 < path.stat().st_size <= 8 * 1024 * 1024, 'Library parity input has an invalid size')
    try:
        data = path.read_bytes()
        return json.loads(data, object_pairs_hook=unique_object, parse_constant=reject_constant), data
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ParityError('Library parity input is not readable JSON') from error


def alias_list(value, aliases):
    return (isinstance(value, list) and all(isinstance(item, str) and item in aliases for item in value) and
            len(value) == len(set(value)))


def original_order(value, aliases):
    return alias_list(value, aliases) and value == [item for item in aliases if item in value]


def valid_snapshot(value, aliases):
    if not isinstance(value, dict) or set(value) != FIELDS:
        return False
    if (not isinstance(value['scope'], str) or value['scope'] not in {'saved', 'trash'} or
            not isinstance(value['kind'], str) or value['kind'] not in KINDS | {'all'}):
        return False
    if not isinstance(value['search'], str) or any(type(value[key]) is not bool for key in ['list', 'pinnedOnly']):
        return False
    visible, selected = value['visible'], value['selected']
    if not alias_list(visible, aliases) or not alias_list(selected, aliases):
        return False
    if selected != [item for item in visible if item in selected]:
        return False
    if not original_order(value['trashed'], aliases) or not original_order(value['pinned'], aliases):
        return False
    if value['kind'] != 'all' and any(aliases[item] != value['kind'] for item in visible):
        return False
    if any((item in value['trashed']) != (value['scope'] == 'trash') for item in visible):
        return False
    if value['pinnedOnly'] and any(item not in value['pinned'] for item in visible):
        return False
    focused = value['focused']
    return ((focused is None and selected == []) or
            (isinstance(focused, str) and focused in visible and focused in selected))


def valid_action(step, aliases):
    base = {'action', 'expect'}
    action = step.get('action')
    if action in {'open', 'close'}:
        return set(step) == base
    if action == 'key':
        modifiers = step.get('modifiers')
        return (set(step) == base | {'code', 'modifiers', 'editing'} and isinstance(step.get('code'), str) and
                step['code'] in KEYS and isinstance(modifiers, list) and
                all(isinstance(modifier, str) and modifier in MODIFIERS for modifier in modifiers) and
                len(modifiers) == len(set(modifiers)) and type(step.get('editing')) is bool)
    if action == 'remap':
        return (set(step) == base | {'binding', 'key'} and step.get('binding') == 'next' and
                (step['key'] is None or isinstance(step['key'], str) and step['key'] in {'', 'KeyJ'}))
    if action == 'mode':
        return set(step) == base | {'list'} and type(step.get('list')) is bool
    if action == 'select':
        return set(step) == base | {'id'} and isinstance(step.get('id'), str) and step['id'] in aliases
    if action == 'searchHandoff':
        return set(step) == base | {'value'} and isinstance(step.get('value'), str)
    if action == 'scope':
        return set(step) == base | {'scope'} and step.get('scope') == 'trash'
    return False


def load_contract(path):
    contract, data = read_json(path)
    require(isinstance(contract, dict) and type(contract.get('schemaVersion')) is int and
            contract['schemaVersion'] == 1 and contract.get('contractId') == 'clipboardline.library.keyboard.v1',
            'Unknown Library keyboard contract identity or schema')
    policy = contract.get('policy')
    require(isinstance(policy, dict) and policy.get('defaultPlatforms') == ['macos', 'windows'] and
            type(policy.get('pageSize')) is int and policy['pageSize'] == 9 and all(
                isinstance(policy.get(key), str) and policy[key].strip()
                for key in ['scope', 'selectionOrder', 'recordsOrder', 'searchHandoff', 'scopeAction', 'editingKeys']),
            'Library contract must retain both platforms, explicit scope/editor rules and nine-item pages')
    additional = policy.get('additionalPlatforms', [])
    require(additional in ([], ADDITIONAL_PLATFORMS), 'Unknown additional platform policy')
    exceptions = policy.get('nativeExceptions')
    require(isinstance(exceptions, list) and all(isinstance(item, dict) and all(
        isinstance(item.get(key), str) and item[key].strip() for key in ['id', 'macos', 'windows', *additional, 'reason'])
        for item in exceptions), 'OS-native exceptions require an explicit reason on every platform')
    require(len({item['id'] for item in exceptions}) == len(exceptions), 'Duplicate OS-native exception')
    records, views, scenarios = contract.get('records'), contract.get('views'), contract.get('scenarios')
    require(isinstance(records, list) and bool(records) and all(isinstance(item, dict) and
        set(item) == {'id', 'kind', 'title', 'text', 'pinned', 'onShelf'} and
        isinstance(item['id'], str) and re.fullmatch(r'[a-z0-9][a-z0-9-]*', item['id']) and
        isinstance(item['kind'], str) and item['kind'] in KINDS and isinstance(item['title'], str) and
        isinstance(item['text'], str) and type(item['pinned']) is bool and type(item['onShelf']) is bool
        for item in records), 'Malformed shared Library fixture')
    require(len({item['id'] for item in records}) == len(records), 'Duplicate Library fixture item alias')
    aliases = {item['id']: item['kind'] for item in records}
    require(isinstance(views, dict) and bool(views) and all(
        re.fullmatch(r'[a-z0-9][a-z0-9-]*', name) and alias_list(values, aliases) for name, values in views.items()),
        'Malformed shared Library view reference')
    require(isinstance(scenarios, list) and bool(scenarios), 'Shared Library scenarios are required')
    expected, identifiers = {}, set()
    for scenario in scenarios:
        require(isinstance(scenario, dict) and {'id', 'columns', 'steps'} <= set(scenario) <=
                {'id', 'columns', 'steps', 'searchMode'}, 'Malformed shared Library scenario')
        identifier = scenario['id']
        require(isinstance(identifier, str) and re.fullmatch(r'[a-z0-9][a-z0-9-]*', identifier) and
                identifier not in identifiers, 'Missing, invalid or duplicate Library scenario ID')
        identifiers.add(identifier)
        require(type(scenario['columns']) is int and 1 <= scenario['columns'] <= 1000 and
                isinstance(scenario.get('searchMode', 'all'), str) and scenario.get('searchMode', 'all') in {'all', 'text', 'visual'},
                'Invalid Library grid geometry or search mode')
        steps = scenario['steps']
        require(isinstance(steps, list) and bool(steps), 'Library scenario has no executed steps')
        for index, step in enumerate(steps):
            require(isinstance(step, dict) and isinstance(step.get('action'), str) and valid_action(step, aliases),
                    'Unknown or malformed shared Library action')
            state = step.get('expect')
            require(isinstance(state, dict) and isinstance(state.get('visible'), str) and state['visible'] in views,
                    'Unknown expected Library view reference')
            state = dict(state, visible=views[state['visible']])
            require(valid_snapshot(state, aliases), 'Malformed expected Library state')
            expected[(identifier, index)] = state
    return contract, hashlib.sha256(data).hexdigest(), expected, aliases


def validate_platform_report(path, platform, source_revision, contract, digest, expected, aliases):
    report, _ = read_json(path)
    host, mode = PLATFORMS[platform]
    require(isinstance(report, dict) and type(report.get('schemaVersion')) is int and report['schemaVersion'] == 1,
            'Unknown Library parity report schema')
    require(report.get('contractId') == contract['contractId'] and report.get('contractSHA256') == digest,
            'Library parity report belongs to another behavioral contract')
    require(report.get('platform') == platform and report.get('hostPlatform') == host and report.get('mode') == mode,
            'Library parity report has the wrong platform, native host or adapter mode')
    require(report.get('sourceRevision') == source_revision, 'Library parity report belongs to another source revision')
    require(report.get('errors') == [], 'Library adapter reported execution errors')
    observations = report.get('observations')
    require(isinstance(observations, list) and len(observations) == len(expected),
            'Library parity report omits or adds shared observations')
    observed = set()
    for observation in observations:
        require(isinstance(observation, dict) and isinstance(observation.get('scenarioId'), str) and
                type(observation.get('step')) is int, 'Malformed Library observation identity')
        key = (observation['scenarioId'], observation['step'])
        require(key in expected and key not in observed, 'Unknown or duplicate Library observation')
        observed.add(key)
        actual = observation.get('actual')
        require(valid_snapshot(actual, aliases) and actual == expected[key],
                'Executed Library behavior differs at ' + key[0] + ':' + str(key[1]))
    require(observed == set(expected), 'Library parity report is incomplete')
    return report


def verify(contract_path, macos_report, windows_report, source_revision, linux_report=None):
    require(isinstance(source_revision, str) and re.fullmatch(r'[0-9a-f]{40}', source_revision),
            'An exact full public source revision is required')
    contract, digest, expected, aliases = load_contract(contract_path)
    reports = [('macos', macos_report), ('windows', windows_report)]
    if linux_report is not None:
        require('linux' in contract['policy'].get('additionalPlatforms', []), 'Contract does not include the Linux adapter')
        reports.append(('linux', linux_report))
    for platform, path in reports:
        validate_platform_report(path, platform, source_revision, contract, digest, expected, aliases)
    return {'passed': True, 'sourceRevision': source_revision, 'contractId': contract['contractId'],
            'contractSHA256': digest, 'platforms': [platform for platform, _ in reports], 'scenarios': len(contract['scenarios']),
            'observationsPerPlatform': len(expected), 'scope': contract['policy']['scope']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--contract', type=Path, default=ROOT / 'contracts/library-keyboard.json')
    parser.add_argument('--macos-report', type=Path, required=True)
    parser.add_argument('--windows-report', type=Path, required=True)
    parser.add_argument('--linux-report', type=Path, help='Optional Linux renderer report from a Linux host')
    parser.add_argument('--source-revision', required=True)
    parser.add_argument('--report', type=Path)
    arguments = parser.parse_args()
    try:
        result = verify(arguments.contract, arguments.macos_report, arguments.windows_report, arguments.source_revision,
                        arguments.linux_report)
        if arguments.report:
            arguments.report.parent.mkdir(parents=True, exist_ok=True)
            arguments.report.write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result, indent=2)); return 0
    except (ParityError, OSError) as error:
        print('Library keyboard acceptance rejected: ' + str(error), file=sys.stderr); return 1


if __name__ == '__main__':
    raise SystemExit(main())
