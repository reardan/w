#!/usr/bin/env python3
"""Run a pinned, bounded upstream Test262 profile in the native W interpreter."""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / 'tests/javascript/test262/manifest.json'
STATUSES = ('PASS', 'FAIL', 'UNSUPPORTED', 'ERROR')
FLAGS = {'onlyStrict', 'noStrict', 'raw', 'module', 'async', 'generated', 'CanBlockIsFalse', 'CanBlockIsTrue', 'non-deterministic'}
FEATURES = {'coalesce-expression'}
DOC_FIELDS = {'description', 'info', 'esid', 'es5id', 'es6id', 'author'}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def scalar(value):
    value = value.strip()
    require(bool(value) and not any(c in value for c in '{}&*!|>'), 'unsupported YAML scalar')
    if value.startswith('"'):
        return json.loads(value)
    if value.startswith("'"):
        require(value.endswith("'"), 'unterminated YAML scalar')
        return value[1:-1].replace("''", "'")
    require(not any(c in value for c in '[]#'), 'unsupported YAML scalar')
    return value


def metadata(source):
    """Deliberately restricted YAML: reject unfamiliar executable metadata."""
    blocks = re.findall(r'/\*---(.*?)---\*/', source, re.S)
    require(len(blocks) == 1, 'exactly one Test262 metadata block required')
    result = {}
    key = None
    for line in blocks[0].splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        match = re.match(r'^([A-Za-z][A-Za-z0-9]*):(?:\s*(.*))?$', line)
        if match:
            key, value = match.groups()
            require(key not in result, 'duplicate metadata key: ' + key)
            if key in DOC_FIELDS:
                result[key] = value
            elif key in {'flags', 'features', 'includes'}:
                value = value.strip()
                if not value:
                    result[key] = []
                else:
                    require(value.startswith('[') and value.endswith(']'), 'unsupported YAML sequence: ' + key)
                    result[key] = [scalar(x) for x in value[1:-1].split(',') if x.strip()]
            elif key == 'negative':
                require(not value.strip(), 'negative requires a block mapping')
                result[key] = {}
            else:
                raise ValueError('unsupported Test262 metadata key: ' + key)
        else:
            require(line[0].isspace() and key is not None, 'invalid YAML continuation')
            if key in DOC_FIELDS:
                continue
            if key in {'flags', 'features', 'includes'}:
                match = re.fullmatch(r'\s+-\s+(.+)', line)
                require(match is not None, 'invalid YAML list item')
                result[key].append(scalar(match[1]))
            elif key == 'negative':
                match = re.fullmatch(r'\s+(phase|type):\s*(\S+)\s*', line)
                require(match is not None and match[1] not in result[key], 'invalid negative metadata')
                result[key][match[1]] = scalar(match[2])
    for key in ('flags', 'features', 'includes'):
        result.setdefault(key, [])
        require(len(result[key]) == len(set(result[key])), 'duplicate ' + key)
    flags = set(result['flags'])
    require(not {'onlyStrict', 'noStrict'} <= flags, 'conflicting strict flags')
    require(not ('raw' in flags and flags & {'onlyStrict', 'noStrict', 'module', 'async'}), 'conflicting raw flags')
    require(not ('module' in flags and 'noStrict' in flags), 'conflicting module flags')
    if 'negative' in result:
        require(set(result['negative']) == {'phase', 'type'}, 'incomplete negative metadata')
        require(result['negative']['phase'] in {'parse', 'resolution', 'runtime'}, 'invalid negative phase')
        require(re.fullmatch(r'(?:Error|[A-Za-z][A-Za-z0-9]*Error)', result['negative']['type']) is not None, 'invalid negative type')
    return result


def variants(meta):
    flags = set(meta['flags'])
    if 'module' in flags:
        return ['module']
    if 'raw' in flags:
        return ['raw']
    if 'onlyStrict' in flags:
        return ['strict']
    if 'noStrict' in flags:
        return ['sloppy']
    return ['sloppy', 'strict']


def unsupported(meta):
    flags = set(meta['flags'])
    if flags - FLAGS:
        return 'unknown flags: ' + ', '.join(sorted(flags - FLAGS))
    if flags & {'module', 'async', 'CanBlockIsFalse', 'CanBlockIsTrue', 'non-deterministic'}:
        return 'unsupported flags: ' + ', '.join(sorted(flags & {'module', 'async', 'CanBlockIsFalse', 'CanBlockIsTrue', 'non-deterministic'}))
    if meta['includes']:
        return 'unsupported harness includes: ' + ', '.join(meta['includes'])
    if set(meta['features']) - FEATURES:
        return 'unsupported features: ' + ', '.join(sorted(set(meta['features']) - FEATURES))
    if meta.get('negative', {}).get('phase') == 'resolution':
        return 'module resolution is unsupported'
    return None


def load_manifest(path):
    data = json.loads(path.read_text())
    require(set(data) == {'version', 'suite', 'upstream', 'files', 'cases', 'baseline'}, 'invalid manifest fields')
    require(data['version'] == 1 and data['suite'] == 'test262-bounded-runtime', 'invalid manifest version/suite')
    require(set(data['upstream']) == {'repository', 'commit'}, 'invalid provenance')
    require(data['upstream']['repository'] == 'https://github.com/tc39/test262', 'invalid upstream repository')
    require(re.fullmatch('[0-9a-f]{40}', data['upstream']['commit']) is not None, 'unpinned revision')
    require(isinstance(data['files'], list) and isinstance(data['cases'], list) and data['cases'], 'invalid files/cases')
    sources = {}
    for item in data['files']:
        require(set(item) == {'path', 'upstream_path', 'sha256'}, 'invalid source entry')
        require(isinstance(item['upstream_path'], str) and item['path'] == 'upstream/' + item['upstream_path'], 'invalid source mapping')
        file = (path.parent / item['path']).resolve()
        require(file.is_relative_to((path.parent / 'upstream').resolve()), 'source escapes corpus')
        require(item['path'] not in sources, 'duplicate source')
        content = file.read_bytes()
        require(len(content) <= 1000000 and b'\0' not in content, 'invalid source bytes')
        require(hashlib.sha256(content).hexdigest() == item['sha256'], 'source pin mismatch: ' + item['path'])
        sources[item['path']] = content.decode('utf-8')
    require({'upstream/LICENSE', 'upstream/INTERPRETING.md', 'upstream/harness/assert.js', 'upstream/harness/sta.js'} <= sources.keys(), 'missing pinned license/harness contract')
    require(len(set(data['cases'])) == len(data['cases']), 'duplicate cases')
    for case in data['cases']:
        require(case in sources and case.startswith('upstream/test/') and case.endswith('.js') and '_FIXTURE' not in case, 'invalid test source')
    baseline = data['baseline']
    require(isinstance(baseline, dict), 'invalid status baseline')
    expected_ids = {case + '#' + mode for case in data['cases'] for mode in variants(metadata(sources[case]))}
    require(set(baseline) == expected_ids, 'baseline must cover every variant exactly')
    for case_id, expected in baseline.items():
        require(isinstance(expected, dict) and expected.get('status') in {'PASS', 'UNSUPPORTED'}, 'invalid baseline status: ' + case_id)
        fields = {'status', 'reason'} if expected['status'] == 'UNSUPPORTED' else {'status'}
        require(set(expected) == fields, 'invalid baseline fields: ' + case_id)
        if expected['status'] == 'UNSUPPORTED':
            require(isinstance(expected['reason'], str) and bool(expected['reason'].strip()), 'unsupported baseline requires a reason: ' + case_id)
    return data, sources


def execute(binary, path, mode, timeout, budget):
    try:
        proc = subprocess.run([str(binary), str(path), 'module' if mode == 'module' else 'script', str(budget), 'raw' if mode == 'raw' else 'harness'],
                              capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return {'phase': 'process', 'outcome': 'timeout'}
    except OSError as error:
        return {'phase': 'process', 'outcome': 'harness_error', 'message': str(error)}
    if proc.returncode:
        return {'phase': 'process', 'outcome': 'crash' if proc.returncode < 0 else 'harness_error', 'exit_code': proc.returncode, 'stderr': proc.stderr[-2000:]}
    try:
        actual = json.loads(proc.stdout)
        require(isinstance(actual, dict) and actual.get('protocol') == 1, 'invalid runner protocol')
        require(actual.get('phase') in {'parse', 'early', 'lower', 'execute'} and actual.get('outcome') in {'normal', 'error', 'throw', 'unsupported', 'limit'}, 'invalid result')
        if actual['outcome'] in {'normal', 'throw'}:
            require(actual['phase'] == 'execute' and type(actual.get('steps')) is int and actual['steps'] > 0 and type(actual.get('assertions')) is int and actual['assertions'] >= 0, 'missing execution evidence')
        if actual['outcome'] == 'error':
            require(actual['phase'] in {'parse', 'early'} and actual.get('error_type') == 'SyntaxError', 'invalid parser error')
        require('error_type' not in actual or isinstance(actual['error_type'], str), 'invalid error identity')
        return actual
    except (ValueError, TypeError) as error:
        return {'phase': 'process', 'outcome': 'harness_error', 'message': str(error), 'stdout': proc.stdout[-2000:]}


def classify(meta, actual):
    if actual['outcome'] in {'crash', 'timeout', 'harness_error', 'limit'}:
        return 'ERROR'
    if actual['outcome'] == 'unsupported':
        return 'UNSUPPORTED'
    negative = meta.get('negative')
    if negative:
        phase = 'parse' if actual['phase'] in {'parse', 'early'} else 'runtime' if actual['phase'] == 'execute' else actual['phase']
        return 'PASS' if actual['outcome'] in {'error', 'throw'} and phase == negative['phase'] and actual.get('error_type') == negative['type'] else 'FAIL'
    return 'PASS' if actual['phase'] == 'execute' and actual['outcome'] == 'normal' else 'FAIL'


def run(manifest_path, binary, timeout=10, budget=100000):
    manifest, sources = load_manifest(manifest_path)
    results = []
    with tempfile.TemporaryDirectory(prefix='w-test262-') as directory:
        for case in manifest['cases']:
            source = sources[case]
            try:
                meta = metadata(source)
            except ValueError as error:
                results.append({'id': case, 'status': 'ERROR', 'actual': {'phase': 'metadata', 'outcome': 'harness_error', 'message': str(error)}})
                continue
            reason = unsupported(meta)
            for mode in variants(meta):
                if reason:
                    actual = {'phase': 'metadata', 'outcome': 'unsupported', 'message': reason}
                else:
                    file = Path(directory) / 'case.js'
                    file.write_text(('"use strict";\n' if mode == 'strict' else '') + source, encoding='utf-8')
                    actual = execute(binary, file, mode, timeout, budget)
                results.append({'id': case + '#' + mode, 'status': classify(meta, actual), 'mode': mode, 'negative': meta.get('negative'), 'actual': actual})
    baseline_changes = []
    for item in results:
        expected = manifest['baseline'].get(item['id'])
        item['baseline'] = expected
        if expected is None or item['status'] != expected['status']:
            baseline_changes.append({'id': item['id'], 'expected': expected['status'] if expected else None, 'actual': item['status']})
    observed = Counter(item['status'] for item in results)
    counts = {status: observed[status] for status in STATUSES}
    report = {'protocol': 1, 'suite': manifest['suite'], 'upstream': manifest['upstream'], 'profile': 'native-boolean-samevalue-v1',
              'files': len(manifest['cases']), 'variants': len(results), 'counts': counts, 'baseline_changes': baseline_changes,
              'execution_passes': sum(item['status'] == 'PASS' and item['actual']['phase'] == 'execute' for item in results),
              'assertions': sum(item['actual'].get('assertions', 0) for item in results), 'results': results}
    return report, int(bool(counts['FAIL'] or counts['ERROR'] or baseline_changes))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, default=MANIFEST)
    parser.add_argument('--runner', type=Path, default=ROOT / 'bin/test262_runtime_runner')
    parser.add_argument('--json', type=Path)
    parser.add_argument('--timeout', type=float, default=10)
    parser.add_argument('--budget', type=int, default=100000)
    parser.add_argument('--require-all', action='store_true', help='also fail if any case is unsupported')
    args = parser.parse_args()
    try:
        require(0 < args.timeout <= 300 and 0 < args.budget <= 10000000, 'invalid time/step budget')
        report, status = run(args.manifest.resolve(), args.runner.resolve(), args.timeout, args.budget)
        if args.require_all and report['counts']['UNSUPPORTED']:
            status = 1
    except (OSError, ValueError, TypeError, KeyError) as error:
        report, status = {'protocol': 1, 'suite': 'test262-bounded-runtime', 'harness_error': str(error)}, 2
    if args.json:
        args.json.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, sort_keys=True))
    return status


if __name__ == '__main__':
    sys.exit(main())
