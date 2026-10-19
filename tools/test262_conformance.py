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
import tarfile
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / 'tests/javascript/test262/manifest.json'
STATUSES = ('PASS', 'FAIL', 'UNSUPPORTED', 'ERROR')
FLAGS = {'onlyStrict', 'noStrict', 'raw', 'module', 'async', 'generated', 'CanBlockIsFalse', 'CanBlockIsTrue', 'non-deterministic'}
FEATURES = {'coalesce-expression'}
# Explicit capability inventory for requirements declared by hash-pinned cases.
# Promote only alongside runtime implementation and executable contract checks.
KNOWN_BUILTINS = {'eval', 'Number', 'isNaN', 'Object'}
BUILTINS = {'Object'}
DOC_FIELDS = {'description', 'info', 'esid', 'es5id', 'es6id', 'author'}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def strict_json(text):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, 'duplicate JSON field: ' + key)
            result[key] = value
        return result
    def constant(value):
        raise ValueError('non-finite JSON value: ' + value)
    return json.loads(text, object_pairs_hook=pairs, parse_constant=constant)


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


def metadata(source, harness=False):
    """Deliberately restricted YAML: reject unfamiliar executable metadata."""
    blocks = re.findall(r'/\*---(.*?)---\*/', source, re.S)
    require(len(blocks) == 1, 'exactly one Test262 metadata block required')
    result = {}
    sequence_fields = {'flags', 'features', 'includes'}
    doc_fields = DOC_FIELDS | ({'defines'} if harness else set())
    key = None
    for line in blocks[0].splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        match = re.match(r'^([A-Za-z][A-Za-z0-9]*):(?:\s*(.*))?$', line)
        if match:
            key, value = match.groups()
            require(key not in result, 'duplicate metadata key: ' + key)
            if key in doc_fields:
                result[key] = value
            elif key in sequence_fields:
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
            if key in doc_fields:
                continue
            if key in sequence_fields:
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


def unsupported(meta, upstream_harness=False):
    flags = set(meta['flags'])
    if flags - FLAGS:
        return 'unknown flags: ' + ', '.join(sorted(flags - FLAGS))
    if flags & {'module', 'CanBlockIsFalse', 'CanBlockIsTrue', 'non-deterministic'}:
        return 'unsupported flags: ' + ', '.join(sorted(flags & {'module', 'CanBlockIsFalse', 'CanBlockIsTrue', 'non-deterministic'}))
    if meta['includes'] and not upstream_harness:
        return 'unsupported harness includes: ' + ', '.join(meta['includes'])
    if set(meta['features']) - FEATURES:
        return 'unsupported features: ' + ', '.join(sorted(set(meta['features']) - FEATURES))
    if meta.get('negative', {}).get('phase') == 'resolution':
        return 'module resolution is unsupported'
    return None


def load_manifest(path):
    data = strict_json(path.read_text())
    require(set(data) == {'version', 'suite', 'upstream', 'files', 'cases', 'baseline', 'builtins_required'}, 'invalid manifest fields')
    require(data['version'] == 2 and data['suite'] == 'test262-bounded-runtime', 'invalid manifest version/suite')
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
    requirements = data['builtins_required']
    require(isinstance(requirements, dict), 'invalid built-in requirements')
    for case, names in requirements.items():
        require(case in data['cases'], 'built-in requirements must name a pinned case')
        require(isinstance(names, list) and names and all(isinstance(name, str) for name in names), 'invalid required built-ins')
        require(len(set(names)) == len(names) and set(names) <= KNOWN_BUILTINS, 'unknown or duplicate required built-ins')
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


def execute(binary, path, mode, timeout, budget, asynchronous=False, harness_path=None):
    try:
        proc = subprocess.run([str(binary), str(path), 'module' if mode == 'module' else 'script', str(budget), 'raw' if mode == 'raw' else 'async' if asynchronous else 'harness'] + ([str(harness_path)] if harness_path else []),
                              capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return {'phase': 'process', 'outcome': 'timeout'}
    except OSError as error:
        return {'phase': 'process', 'outcome': 'harness_error', 'message': str(error)}
    if proc.returncode:
        return {'phase': 'process', 'outcome': 'crash' if proc.returncode < 0 else 'harness_error', 'exit_code': proc.returncode, 'stderr': proc.stderr[-2000:]}
    try:
        actual = strict_json(proc.stdout)
        require(isinstance(actual, dict) and type(actual.get('protocol')) is int and actual['protocol'] == 1, 'invalid runner protocol')
        require(actual.get('phase') in {'parse', 'early', 'lower', 'execute', 'harness'} and actual.get('outcome') in {'normal', 'error', 'throw', 'unsupported', 'limit', 'incomplete'}, 'invalid result')
        if actual['outcome'] in {'normal', 'throw', 'incomplete'}:
            require(actual['phase'] in {'execute', 'harness'} and type(actual.get('steps')) is int and actual['steps'] > 0 and type(actual.get('assertions')) is int and actual['assertions'] >= 0, 'missing execution evidence')
        if asynchronous and actual['phase'] == 'execute' and actual['outcome'] in {'normal', 'throw', 'incomplete'}:
            require(type(actual.get('done_calls')) is int and actual['done_calls'] >= 0, 'missing async completion evidence')
            require(actual['outcome'] != 'normal' or actual['done_calls'] == 1, 'async normal completion requires exactly one $DONE')
        if actual['outcome'] == 'error':
            require(actual['phase'] in {'parse', 'early'} and actual.get('error_type') == 'SyntaxError', 'invalid parser error')
        require('error_type' not in actual or isinstance(actual['error_type'], str), 'invalid error identity')
        return actual
    except (ValueError, TypeError) as error:
        return {'phase': 'process', 'outcome': 'harness_error', 'message': str(error), 'stdout': proc.stdout[-2000:]}


def classify(meta, actual):
    if actual['outcome'] in {'crash', 'timeout', 'harness_error', 'limit', 'incomplete'}:
        return 'ERROR'
    if actual['outcome'] == 'unsupported':
        return 'UNSUPPORTED'
    if actual['phase'] == 'harness':
        return 'ERROR'
    negative = meta.get('negative')
    if negative:
        phase = 'parse' if actual['phase'] in {'parse', 'early'} else 'runtime' if actual['phase'] == 'execute' else actual['phase']
        return 'PASS' if actual['outcome'] in {'error', 'throw'} and phase == negative['phase'] and actual.get('error_type') == negative['type'] else 'FAIL'
    return 'PASS' if actual['phase'] == 'execute' and actual['outcome'] == 'normal' else 'FAIL'


def prepare_harness(sources, includes):
    """Resolve unchanged includes dependency-first; reject gaps and cycles.

    Harness metadata features are capability requirements too. In particular,
    isConstructor must not quietly return false because Reflect.construct is
    absent and its original try/catch swallowed that missing capability.
    """
    ordered, visiting, visited = [], set(), set()
    blockers = []
    def visit(name):
        require(isinstance(name, str) and re.fullmatch(r'[A-Za-z0-9_.-]+\.js', name), 'invalid harness include path')
        require(name not in visiting, 'cyclic harness include: ' + name)
        if name in visited:
            return
        key = 'upstream/harness/' + name
        require(key in sources, 'missing pinned harness include: ' + name)
        visiting.add(name)
        meta = metadata(sources[key], harness=True)
        reason = unsupported(meta, upstream_harness=True)
        if reason:
            blockers.append(name + ': ' + reason)
        for dependency in meta['includes']:
            visit(dependency)
        visiting.remove(name)
        visited.add(name)
        ordered.append(sources[key])
    for name in ['sta.js', 'assert.js', *includes]:
        visit(name)
    return '\n'.join(ordered), '; '.join(blockers) if blockers else None


def provenance(binary):
    def revision(directory):
        result = subprocess.run(['git', '-C', str(directory), 'rev-parse', 'HEAD'], capture_output=True, text=True)
        return result.stdout.strip() if result.returncode == 0 else None
    return {'recorded_at_utc': datetime.now(timezone.utc).isoformat(), 'w_revision': revision(ROOT),
            'application_revision': revision(ROOT.parent), 'runner_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
            'kind': 'fresh-execution',
            'adapter_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            'runner_source_sha256': hashlib.sha256((ROOT / 'tools/test262_runtime_runner.w').read_bytes()).hexdigest()}


def suite_inventory(manifest_path, manifest):
    path = manifest_path.parent / 'inventory.json'
    if not path.exists():
        return {'complete_archive_inventory': False, 'candidate_test_files': None, 'unselected_files': None}
    inventory = strict_json(path.read_text())
    require(inventory['revision'] == manifest['upstream']['commit'], 'suite inventory revision mismatch')
    total = inventory['counts']['candidate_test_files_excluding_fixtures']
    require(type(total) is int and total >= len(manifest['cases']), 'invalid complete suite count')
    return {**inventory, 'selected_files': len(manifest['cases']), 'unselected_files': total - len(manifest['cases'])}


def run(manifest_path, binary, timeout=10, budget=100000, loaded=None, upstream_harness=False):
    manifest, sources = load_manifest(manifest_path) if loaded is None else loaded
    results = []
    profile = {'name': 'upstream-harness-experimental-v1' if upstream_harness else 'native-assertions-async-v2',
               'features': sorted(FEATURES), 'builtins': sorted(BUILTINS), 'step_budget': budget, 'wall_timeout_seconds': timeout}
    source_index = {name: hashlib.sha256(source.encode('utf-8')).hexdigest() for name, source in sorted(sources.items())}
    source_index_hash = hashlib.sha256(json.dumps(source_index, sort_keys=True).encode()).hexdigest()
    with tempfile.TemporaryDirectory(prefix='w-test262-') as directory:
        for case in manifest['cases']:
            source = sources[case]
            try:
                meta = metadata(source)
            except ValueError as error:
                results.append({'id': case, 'status': 'ERROR', 'actual': {'phase': 'metadata', 'outcome': 'harness_error', 'message': str(error)}})
                continue
            reason = unsupported(meta, upstream_harness)
            harness_path = None
            if upstream_harness and not reason and 'raw' not in meta['flags']:
                try:
                    harness_source, harness_reason = prepare_harness(sources, meta['includes'])
                    reason = harness_reason
                    if not reason:
                        harness_path = Path(directory) / 'harness.js'
                        harness_path.write_text(harness_source, encoding='utf-8')
                except ValueError as error:
                    for mode in variants(meta):
                        results.append({'id': case + '#' + mode, 'mode': mode, 'negative': meta.get('negative'), 'status': 'ERROR', 'actual': {'phase': 'harness', 'outcome': 'harness_error', 'message': str(error)}})
                    continue
            missing = sorted(set(manifest['builtins_required'].get(case, [])) - BUILTINS)
            if not reason and missing:
                reason = 'unsupported required built-ins: ' + ', '.join(missing)
            for mode in variants(meta):
                if reason:
                    actual = {'phase': 'metadata', 'outcome': 'unsupported', 'message': reason}
                else:
                    file = Path(directory) / 'case.js'
                    file.write_text(('"use strict";\n' if mode == 'strict' else '') + source, encoding='utf-8')
                    actual = execute(binary, file, mode, timeout, budget, asynchronous='async' in meta['flags'], harness_path=harness_path)
                results.append({'id': case + '#' + mode, 'status': classify(meta, actual), 'mode': mode, 'negative': meta.get('negative'), 'actual': actual})
    baseline_changes = []
    for item in results:
        expected = manifest['baseline'].get(item['id']) if manifest['baseline'] is not None and not upstream_harness else None
        item['baseline'] = expected
        if manifest['baseline'] is not None and not upstream_harness and (expected is None or item['status'] != expected['status']):
            baseline_changes.append({'id': item['id'], 'expected': expected['status'] if expected else None, 'actual': item['status']})
    observed = Counter(item['status'] for item in results)
    counts = {status: observed[status] for status in STATUSES}
    report = {'protocol': 1, 'suite': manifest['suite'], 'upstream': manifest['upstream'], 'profile': 'upstream-harness-experimental-v1' if upstream_harness else 'native-assertions-async-v2',
              'evidence': provenance(binary), 'profile_contract': profile,
              'profile_sha256': hashlib.sha256(json.dumps(profile, sort_keys=True).encode()).hexdigest(),
              'source_index_sha256': source_index_hash,
              'harness_sources': {name: digest for name, digest in source_index.items() if name.startswith('upstream/harness/')}, 'inventory': suite_inventory(manifest_path, manifest), 'baseline_reviewed': manifest['baseline'] is not None and not upstream_harness,
              'selected_files': len(manifest['cases']), 'executed_variants': sum(item['actual']['phase'] not in {'metadata', 'process'} for item in results),
              'unsupported_by_reason': dict(sorted(Counter(item['actual'].get('message', item['actual']['phase']) for item in results if item['status'] == 'UNSUPPORTED').items())),
              'files': len(manifest['cases']), 'variants': None if any(item['actual']['phase'] == 'metadata' and item['status'] == 'ERROR' for item in results) else len(results), 'result_records': len(results), 'unexpanded_files': sum(item['actual']['phase'] == 'metadata' and item['status'] == 'ERROR' for item in results), 'counts': counts, 'baseline_changes': baseline_changes,
              'execution_passes': sum(item['status'] == 'PASS' and item['actual']['phase'] == 'execute' for item in results),
              'assertions': None if upstream_harness else sum(item['actual'].get('assertions', 0) for item in results), 'results': results}
    return report, int(bool(counts['FAIL'] or counts['ERROR'] or baseline_changes))


def archive_cases(archive, families):
    """Enumerate whole directories from the immutable complete upstream archive.

    This diagnostic expansion has no expected-status mask. All FAIL/ERROR and
    UNSUPPORTED remain nonzero in --require-all mode, with the full inventory
    retained. Source selection is directories only, never favorable test names.
    """
    inventory = json.loads((MANIFEST.parent / 'inventory.json').read_text())
    require(hashlib.sha256(archive.read_bytes()).hexdigest() == inventory['archive_sha256'], 'upstream archive pin mismatch')
    require(families and len(families) == len(set(families)), 'missing or duplicate families')
    for family in families:
        require(family.startswith('test/') and family.endswith('/') and '..' not in family.split('/'), 'families must be complete test/ directories with trailing slash')
    sources = {}
    prefix = 'test262-' + inventory['revision'] + '/'
    with tarfile.open(archive) as upstream:
        for item in upstream:
            if not item.isfile() or not item.name.startswith(prefix):
                continue
            name = item.name[len(prefix):]
            if not name.endswith('.js') or '_FIXTURE' in name or not (name.startswith('harness/') or any(name.startswith(family) for family in families)):
                continue
            sources['upstream/' + name] = upstream.extractfile(item).read().decode('utf-8')
    for family in families:
        require(any(case.startswith('upstream/' + family) for case in sources), 'empty family: ' + family)
    manifest = {'suite': 'test262-complete-family-audit', 'upstream': {'repository': inventory['repository'], 'commit': inventory['revision']},
                'cases': sorted(case for case in sources if case.startswith('upstream/test/')), 'builtins_required': {}, 'baseline': None}
    return manifest, sources


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, default=MANIFEST)
    parser.add_argument('--runner', type=Path, default=ROOT / 'bin/test262_runtime_runner')
    parser.add_argument('--json', type=Path)
    parser.add_argument('--timeout', type=float, default=10)
    parser.add_argument('--budget', type=int, default=100000)
    parser.add_argument('--harness', choices=('native', 'upstream'), default='native', help='explicit experimental original upstream harness execution')
    parser.add_argument('--archive', type=Path, help='hash-pinned complete upstream archive for family audit')
    parser.add_argument('--family', action='append', default=[], help='complete test/ directory prefix, ending in /; repeatable')
    parser.add_argument('--require-all', action='store_true', help='also fail if any case is unsupported')
    args = parser.parse_args()
    try:
        require(0 < args.timeout <= 300 and 0 < args.budget <= 10000000, 'invalid time/step budget')
        require(bool(args.archive) == bool(args.family), '--archive and --family must be used together')
        loaded = archive_cases(args.archive, args.family) if args.archive else None
        report, status = run(args.manifest.resolve(), args.runner.resolve(), args.timeout, args.budget, loaded=loaded, upstream_harness=args.harness == 'upstream')
        if args.archive:
            report['families'] = args.family
            report['archive_sha256'] = hashlib.sha256(args.archive.read_bytes()).hexdigest()
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
