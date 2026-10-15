#!/usr/bin/env python3
"""Execute pinned native ECMAScript fixtures in W; no Node or Test262 claims."""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MANIFEST = ROOT / 'tests/javascript/conformance/manifest.json'
PHASES = {'parse', 'early', 'lower', 'execute'}
OUTCOMES = {'normal', 'error', 'throw', 'unsupported', 'limit'}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate_expectation(value):
    require(isinstance(value, dict), 'expectation must be an object')
    require(set(value) <= {'phase', 'outcome', 'value', 'error_type', 'message'},
            'unknown expectation field')
    require(value.get('phase') in PHASES, 'invalid expectation phase')
    require(value.get('outcome') in OUTCOMES, 'invalid expectation outcome')
    require(value['outcome'] != 'normal' or value['phase'] == 'execute',
            'syntax-only acceptance is not execution success')
    if 'error_type' in value:
        require(isinstance(value['error_type'], str), 'invalid error_type')
    if 'message' in value:
        require(isinstance(value['message'], str), 'invalid message')
    if 'value' in value:
        item = value['value']
        require(isinstance(item, dict), 'invalid value')
        kind = item.get('type')
        require(kind in {'undefined', 'null', 'boolean', 'number', 'string', 'object'}, 'invalid value type')
        fields = {'type'}
        if kind in {'number', 'boolean'}:
            fields.add('value')
            require(type(item.get('value')) is (str if kind == 'number' else bool), 'invalid primitive value')
        if kind == 'string':
            fields.add('units')
            require(isinstance(item.get('units'), list) and all(type(u) is int and 0 <= u <= 65535 for u in item['units']), 'invalid UTF-16 units')
        require(set(item) == fields, 'invalid value fields')


def load_manifest(path):
    manifest = json.loads(path.read_text())
    require(isinstance(manifest, dict) and set(manifest) == {'version', 'kind', 'cases'}, 'invalid manifest fields')
    require(manifest['version'] == 1, 'unsupported manifest version')
    require(manifest['kind'] == 'native-ecmascript',
            'unsupported harness metadata: only native-ecmascript is implemented; Test262 requires its own adapter')
    require(isinstance(manifest['cases'], list) and manifest['cases'], 'empty or invalid cases')
    seen = set()
    for case in manifest['cases']:
        require(isinstance(case, dict), 'case must be an object')
        require(set(case) <= {'id', 'path', 'sha256', 'goal', 'budget', 'expected', 'xfail', 'spec'}, 'unknown case metadata')
        require({'id', 'path', 'sha256', 'goal', 'expected', 'spec'} <= set(case), 'missing case metadata')
        require(isinstance(case['id'], str) and case['id'] and case['id'] not in seen, 'invalid or duplicate case id')
        seen.add(case['id'])
        require(case['goal'] in {'script', 'module'}, 'unsupported goal')
        require(type(case.get('budget', 10000)) is int and 0 < case.get('budget', 10000) <= 10000000, 'invalid budget')
        require(isinstance(case['spec'], str) and case['spec'].startswith('https://tc39.es/ecma262/'), 'missing normative reference')
        require(isinstance(case['path'], str), 'invalid source path')
        source_path = (path.parent / case['path']).resolve()
        require(source_path.is_relative_to(path.parent.resolve()), 'source escapes fixture directory')
        data = source_path.read_bytes()
        require(0 < len(data) <= 1000000 and b'\0' not in data, 'invalid source size or embedded NUL')
        data.decode('utf-8')
        require(hashlib.sha256(data).hexdigest() == case['sha256'], 'source pin mismatch: ' + case['id'])
        validate_expectation(case['expected'])
        require(case['expected']['outcome'] != 'unsupported', 'unsupported cannot be a normative success')
        if 'xfail' in case:
            xfail = case['xfail']
            require(isinstance(xfail, dict) and set(xfail) == {'bug', 'reason', 'observed'}, 'invalid xfail metadata')
            require(all(isinstance(xfail[k], str) and xfail[k].strip() for k in ('bug', 'reason')), 'xfail needs bug and reason')
            validate_expectation(xfail['observed'])
            require(xfail['observed'] != case['expected'], 'xfail must differ from normative expectation')
    return manifest


def matches(actual, expected):
    return all(key in actual and actual[key] == value for key, value in expected.items())


def classify(case, actual):
    if actual['outcome'] in {'crash', 'timeout', 'harness_error'}:
        return 'ERROR'
    if matches(actual, case['expected']):
        return 'XPASS' if 'xfail' in case else 'PASS'
    if 'xfail' in case and matches(actual, case['xfail']['observed']):
        return 'XFAIL'
    return 'FAIL'


def execute(binary, path, case, timeout):
    try:
        proc = subprocess.run([str(binary), str(path), case['goal'], str(case.get('budget', 10000))],
                              capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return {'phase': 'process', 'outcome': 'timeout'}
    except OSError as error:
        return {'phase': 'process', 'outcome': 'harness_error', 'message': str(error)}
    if proc.returncode:
        return {'phase': 'process', 'outcome': 'crash' if proc.returncode < 0 else 'harness_error',
                'exit_code': proc.returncode, 'stderr': proc.stderr[-2000:]}
    try:
        actual = json.loads(proc.stdout)
        require(isinstance(actual, dict) and actual.get('protocol') == 1, 'invalid runner protocol')
        require(actual.get('phase') in PHASES and actual.get('outcome') in OUTCOMES, 'invalid runner result')
        if actual['outcome'] in {'normal', 'throw'}:
            require(actual['phase'] == 'execute' and 'value' in actual, 'missing execution evidence')
            validate_expectation({key: actual[key] for key in ('phase', 'outcome', 'value')})
        return actual
    except (ValueError, TypeError) as error:
        return {'phase': 'process', 'outcome': 'harness_error', 'message': str(error), 'stdout': proc.stdout[-2000:]}


def run(manifest_path, binary, timeout):
    manifest = load_manifest(manifest_path)
    results = []
    for case in manifest['cases']:
        actual = execute(binary, manifest_path.parent / case['path'], case, timeout)
        result = {'id': case['id'], 'status': classify(case, actual), 'actual': actual, 'expected': case['expected']}
        if 'xfail' in case:
            result['xfail'] = case['xfail']
        results.append(result)
    counts = Counter(item['status'] for item in results)
    report = {'protocol': 1, 'suite': 'native-ecmascript', 'results': results,
              'counts': dict(sorted(counts.items())),
              'outcomes': dict(sorted(Counter(item['actual']['phase'] + ':' + item['actual']['outcome'] for item in results).items())),
              'execution_passes': sum(item['status'] == 'PASS' and item['actual']['phase'] == 'execute' for item in results)}
    return report, int(any(counts[key] for key in ('FAIL', 'XPASS', 'ERROR')))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument('--runner', type=Path, default=ROOT / 'bin/javascript_runtime_runner')
    parser.add_argument('--timeout', type=float, default=10)
    parser.add_argument('--json', type=Path, help='write complete machine-readable results')
    args = parser.parse_args()
    try:
        require(args.timeout > 0, 'timeout must be positive')
        report, status = run(args.manifest.resolve(), args.runner.resolve(), args.timeout)
    except (OSError, ValueError, TypeError, KeyError) as error:
        report, status = {'protocol': 1, 'suite': 'native-ecmascript', 'harness_error': str(error)}, 2
    if args.json:
        args.json.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, sort_keys=True))
    return status


if __name__ == '__main__':
    sys.exit(main())
