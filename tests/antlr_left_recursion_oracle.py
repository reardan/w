#!/usr/bin/env python3
"""Pinned Wave 0 evidence. Default is offline; refreshing requires an explicit flag.

Live runs need a local checksum-pinned ANTLR jar and java AND javac 17 on PATH.
No downloads, W acceptance changes, or upstream runtime claims are made here.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / 'tests/grammars/antlr_left_recursion'
MANIFEST = FIXTURES / 'manifest.json'
SNAPSHOTS = FIXTURES / 'snapshots.json'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_manifest():
    data = json.loads(MANIFEST.read_text())
    if data['schema'] != 1:
        raise ValueError('unsupported manifest schema')
    pairs = {(case['name'], rule['name']) for case in data['cases'] for rule in case['rules']}
    if len(data['cases']) != 21 or len(pairs) != 25:
        raise ValueError('inventory must retain 21 grammars and 25 distinct rules')
    for entry in data['files']:
        path = (FIXTURES / entry['path']).resolve()
        if not path.is_relative_to(FIXTURES.resolve()) or digest(path) != entry['sha256']:
            raise ValueError('fixture hash/path mismatch: ' + entry['path'])
    for case in data['cases']:
        for entry in case['inputs']:
            if digest(FIXTURES / 'upstream' / entry['path']) != entry['sha256']:
                raise ValueError('original upstream hash mismatch')
    graph = json.loads((FIXTURES / 'original_graph.json').read_text())
    if graph['corpus_commit'] != data['corpus']['commit'] or [c['name'] for c in graph['cases']] != [c['name'] for c in data['cases']]:
        raise ValueError('original graph corpus mismatch')
    for case, evidence in zip(data['cases'], graph['cases']):
        analysis = evidence['analysis']
        if evidence['inputs'] != case['inputs'] or not analysis['complete'] or analysis['exhausted']:
            raise ValueError('original graph evidence incomplete')
        if any(r['mutual_cycle'] for r in analysis['rules']):
            raise ValueError('original graph contradicts no-mutual-SCC observation')
    return data


def versions():
    result = {}
    for name in ('java', 'javac'):
        value = subprocess.check_output([name, '-version'], stderr=subprocess.STDOUT, text=True)
        match = re.search(r'(?:version\s+"|javac\s+)(\d+)', value)
        if not match or int(match[1]) != 17:
            raise ValueError(name + ' must resolve to major 17 on PATH')
        result[name] = value
    return result


def command(argv, cwd, timeout):
    try:
        p = subprocess.run([str(arg) for arg in argv], cwd=cwd, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        raise ValueError('reference infrastructure timeout: ' + str(argv[0])) from error
    return {'status': 'pass' if p.returncode == 0 else 'fail', 'exit_code': p.returncode,
            'stdout': p.stdout, 'stderr': p.stderr}


def run_case(case, jar, work, probe, timeout, minimal=False):
    directory = work / case['name']
    directory.mkdir()
    paths = [FIXTURES / case['grammar']] if minimal else [FIXTURES / 'upstream' / entry['path'] for entry in case['inputs']]
    for source in paths:
        shutil.copyfile(source, directory / source.name)
    names = case['rules'] if minimal else [r['name'] for r in case['rules']]
    # Inspect subclasses the pinned ANTLR Tool and emits actual original/rewritten alternatives.
    generation = command(['java', '-cp', str(probe)+os.pathsep+str(jar), 'Inspect', ','.join(names),
                          '-Dlanguage=Java', '-o', '.', *(p.name for p in paths)], directory, timeout)
    if generation['exit_code'] not in (0, 1) or re.search(r'Exception in thread|Could not create the Java Virtual Machine|OutOfMemoryError|Could not find or load', generation['stderr']):
        raise ValueError(case['name'] + ': ANTLR infrastructure failure')
    if generation['status']=='fail' and not re.search(r'^error\(\d+\):', generation['stderr'], re.MULTILINE):
        raise ValueError(case['name'] + ': generation failure lacks ANTLR refusal diagnostic')
    rules = [json.loads(line) for line in generation.pop('stdout').splitlines() if line.strip()]
    row = {'name': case['name'], 'generation': generation, 'rules': rules}
    if generation['status'] == 'pass':
        generated = sorted(directory.glob('*.java'))
        row['generated_java'] = [{'path': p.name, 'sha256': digest(p)} for p in generated]
        compilation = command(['javac', '-encoding', 'UTF-8', '-cp', str(probe)+os.pathsep+str(jar),
                               *(p.name for p in generated)], directory, timeout)
        if compilation['status']=='fail' and (compilation['exit_code'] != 1 or 'error: cannot find symbol' not in compilation['stderr']):
            raise ValueError(case['name'] + ': unexpected Java compilation infrastructure/source failure')
        row['java_compilation'] = compilation
        if minimal and compilation['status'] != 'pass':
            raise ValueError(case['name'] + ': minimal Java compilation failed: ' + compilation['stderr'])
        if minimal:
            row['runtime'] = []
            for index, text in enumerate(case['inputs']):
                source = directory / 'input.txt'
                source.write_text(text)
                result = command(['java', '-cp', str(directory)+os.pathsep+str(probe)+os.pathsep+str(jar),
                                  'TreeOracle', case['name'], case['start'], source], directory, timeout)
                if result['status'] != 'pass':
                    raise ValueError(case['name'] + ': runtime infrastructure failure: ' + result['stderr'])
                row['runtime'].append({'input': text, **json.loads(result['stdout'])})
        else:
            row['runtime'] = {'status': 'not_run' if compilation['status']=='pass' else 'blocked',
                              'reason': 'No upstream runtime witness executed.' if compilation['status']=='pass'
                              else 'Unmodified generated Java does not compile without host support; see java_compilation.'}
    else:
        row['java_compilation'] = {'status': 'not_run'}
        row['runtime'] = {'status': 'not_run', 'reason': 'ANTLR generation refused.'}
    if minimal and generation['status'] != case['generation_expected']:
        raise ValueError(case['name'] + ': unexpected ANTLR generation outcome')
    if not minimal and (generation['status'] != 'pass' or {r['rule'] for r in rules} != set(names)):
        raise ValueError(case['name'] + ': missing successful original-rule evidence')
    return row


def validate_snapshots(data, snapshots):
    if snapshots['schema'] != 1 or snapshots['oracle'] != data['oracle']:
        raise ValueError('snapshot reference version mismatch')
    cases = snapshots['cases']
    if [c['name'] for c in cases] != [c['name'] for c in data['cases']]:
        raise ValueError('snapshot inventory changed')
    for case, row in zip(data['cases'], cases):
        if row['generation']['status'] != 'pass' or row['java_compilation']['status'] != case['java_compilation_expected']:
            raise ValueError('original generation/compilation evidence changed')
        if {r['rule'] for r in row['rules']} != {r['name'] for r in case['rules']}:
            raise ValueError('missing rule snapshot')
        for rule in row['rules']:
            alts = rule['alternatives']
            inventory = next(r for r in case['rules'] if r['name']==rule['rule'])
            if len(alts) != inventory['source_alternative_count']:
                raise ValueError('source alternative inventory incomplete')
            if sorted(a['source_alt'] for a in alts) != list(range(1, len(alts)+1)):
                raise ValueError('source alternative inventory incomplete')
            if any(a['class'] not in ('binary', 'prefix', 'suffix', 'other') for a in alts):
                raise ValueError('unclassified reference alternative')
    if [c['name'] for c in snapshots['minimal']] != [c['name'] for c in data['minimal']]:
        raise ValueError('minimal fixture inventory changed')
    for case, row in zip(data['minimal'], snapshots['minimal']):
        if row['generation']['status'] != case['generation_expected']:
            raise ValueError('minimal generation evidence changed')
        if case['generation_expected']=='pass':
            if row['java_compilation']['status'] != 'pass' or not isinstance(row.get('runtime'), list):
                raise ValueError('minimal runtime evidence missing')
            if [item['input'] for item in row['runtime']] != case['inputs']:
                raise ValueError('minimal runtime input inventory incomplete')
            for item in row['runtime']:
                if not isinstance(item['accepted'], bool) or not isinstance(item['complete'], bool):
                    raise ValueError('invalid minimal acceptance observation')
                if item['accepted'] and (not item['complete'] or not isinstance(item['tree'], dict)):
                    raise ValueError('accepted minimal input lacks complete operand tree')
        elif row['generation']['exit_code'] != 1 or not re.search(r'^error\(\d+\):', row['generation']['stderr'], re.MULTILINE):
            raise ValueError('minimal negative lacks ANTLR refusal diagnostic')
    return snapshots


def compare_plans(data, snapshots, tool, timeout):
    """Compare W's read-only descriptors to independently extracted ANTLR facts."""
    count = 0
    pairs = list(zip(data['cases'], snapshots['cases']))
    pairs += [(case, row) for case, row in zip(data['minimal'], snapshots['minimal']) if case['generation_expected']=='pass']
    rule_count = 0
    for case, evidence in pairs:
        for rule in evidence['rules']:
            source = FIXTURES/case['grammar'] if 'grammar' in case else next(
                FIXTURES/'upstream'/entry['path'] for entry in case['inputs'] if Path(entry['path']).name == rule['file'])
            rule_count += 1
            result = command([tool.resolve(), '--inspect', source, rule['rule']], ROOT, timeout)
            if result['status'] != 'pass':
                raise ValueError('plan probe failed: ' + case['name'] + '/' + rule['rule'])
            actual = json.loads(result['stdout'])
            expected = []
            primary, operator = 0, 0
            for alt in rule['alternatives']:
                if alt['class'] in ('prefix', 'other'):
                    primary += 1
                    decision = primary
                else:
                    operator += 1
                    decision = operator
                expected.append({'source_alt': alt['source_alt'], 'class': alt['class'],
                    'precedence': alt['precedence'], 'decision_index': decision,
                    'right_associative': int(alt['assoc']=='right'),
                    'bindings': [-1 if r['removed_left_operand'] else r['binding'] for r in alt['owner_references']]})
            if not actual['complete'] or actual['alternatives'] != sorted(expected, key=lambda a:a['source_alt']):
                raise ValueError('plan differs from reference: ' + case['name'] + '/' + rule['rule'])
            count += len(expected)
    print(f'W read-only plans match ANTLR: {rule_count} original/minimal rules, {count} alternatives, including decision priority and occurrence bindings')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--jar', type=Path)
    parser.add_argument('--refresh-snapshots', action='store_true')
    parser.add_argument('--work', type=Path)
    parser.add_argument('--plan-tool', type=Path, help='compare W read-only plan descriptors with pinned ANTLR alternatives')
    parser.add_argument('--progress-tool', type=Path, help='reproduce original graph with the maintained W diagnostic tool')
    parser.add_argument('--timeout', type=float, default=90)
    parser.add_argument('--jobs', type=int, default=3)
    args = parser.parse_args(argv)
    if args.refresh_snapshots and not args.jar:
        parser.error('--refresh-snapshots requires --jar')
    if args.timeout <= 0 or args.jobs < 1:
        parser.error('timeout and jobs must be positive')
    data = load_manifest()
    if args.progress_tool:
        graph = json.loads((FIXTURES / 'original_graph.json').read_text())
        for case, expected in zip(data['cases'], graph['cases']):
            observed = command([args.progress_tool.resolve(), *(FIXTURES / 'upstream' / entry['path'] for entry in case['inputs'])], ROOT, args.timeout)
            if observed['status'] != 'pass' or json.loads(observed['stdout']) != expected['analysis']:
                raise ValueError('original graph differs: ' + case['name'])
        print('Original graph reproduced: 21 roots, no mutual nullable-prefix SCC')
    if not args.refresh_snapshots and digest(SNAPSHOTS) != data['snapshots_sha256']:
        raise ValueError('reference snapshot hash mismatch')
    if args.plan_tool:
        compare_plans(data, validate_snapshots(data, json.loads(SNAPSHOTS.read_text())), args.plan_tool, args.timeout)
    if not args.jar:
        validate_snapshots(data, json.loads(SNAPSHOTS.read_text()))
        print('Wave 0 offline evidence: 21 grammars, 25 rules; pinned source and reference snapshots verified')
        return 0
    jar = args.jar.resolve()
    if digest(jar) != data['oracle']['jar_sha256']:
        raise ValueError('ANTLR jar hash mismatch')
    version = versions()
    runner_hash = digest(Path(__file__))
    manifest_hash = digest(MANIFEST)
    work = args.work.resolve() if args.work else Path(tempfile.mkdtemp(prefix='antlr-lr-oracle-'))
    work.mkdir(exist_ok=True, parents=True)
    if any(work.iterdir()):
        raise ValueError('work directory must be empty')
    probe = work / 'probe'
    probe.mkdir()
    compile_probe = command(['javac', '-cp', jar, '-d', probe, FIXTURES/'Inspect.java', FIXTURES/'TreeOracle.java'], work, args.timeout)
    if compile_probe['status'] != 'pass':
        raise ValueError(compile_probe['stderr'])
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        cases = list(pool.map(lambda c: run_case(c, jar, work, probe, args.timeout), data['cases']))
        minimal = list(pool.map(lambda c: run_case(c, jar, work, probe, args.timeout, True), data['minimal']))
    result = {'schema': 1, 'oracle': data['oracle'], 'cases': cases, 'minimal': minimal}
    validate_snapshots(data, result)
    if runner_hash != digest(Path(__file__)) or manifest_hash != digest(MANIFEST):
        raise ValueError('runner or manifest changed during reference measurement')
    load_manifest()  # recheck source/probe hashes after execution
    (work/'provenance.json').write_text(json.dumps({'versions': version, 'jar_sha256':digest(jar),
        'manifest_sha256':manifest_hash, 'runner_sha256':runner_hash, 'result':result}, indent=2)+'\n')
    if args.refresh_snapshots:
        SNAPSHOTS.write_text(json.dumps(result, indent=2)+'\n')
        data['snapshots_sha256'] = digest(SNAPSHOTS)
        MANIFEST.write_text(json.dumps(data, indent=2)+'\n')
    elif result != json.loads(SNAPSHOTS.read_text()):
        raise ValueError('live reference differs from snapshot; inspect ' + str(work/'provenance.json'))
    print('Wave 0 live ANTLR generation, Java compilation, minimal runtime trees verified; artifacts: ' + str(work))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
