#!/usr/bin/env python3
"""Reproduce current Wave 0 guard findings without changing historical observations.

Only --refresh writes the committed report/hash. Ordinary runs compare current
findings and assert atomic output preservation on all 21 original refusals.
"""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import sys
sys.dont_write_bytecode = True
import antlr_left_recursion_oracle as oracle

REPORT = oracle.FIXTURES / 'current_refusals.json'


def normalize(value):
    if isinstance(value, dict):
        return {key: normalize(item) for key, item in value.items()}
    if isinstance(value, list):
        return [normalize(item) for item in value]
    if isinstance(value, str):
        return value.replace(str(oracle.FIXTURES/'upstream')+'/', '')
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tool', type=Path, default=oracle.ROOT/'bin/antlr_to_pg')
    parser.add_argument('--refresh', action='store_true')
    args = parser.parse_args()
    data = oracle.load_manifest()
    tool = args.tool.resolve()
    before = oracle.digest(tool)
    rows = []
    with tempfile.TemporaryDirectory(prefix='antlr-lr-refusals-') as work:
        work = Path(work)
        for case in data['cases']:
            output, audit = work/'grammar.pg', work/'audit.json'
            output.write_text('unchanged sentinel\n')
            audit.unlink(missing_ok=True)
            result = oracle.command([tool, *(oracle.FIXTURES/'upstream'/entry['path'] for entry in case['inputs']),
                '--exact-lexer', '--prediction', '-o', output, '--audit-json', audit], oracle.ROOT, 90)
            if result['exit_code'] != 1 or output.read_text() != 'unchanged sentinel\n':
                raise ValueError(case['name'] + ': expected atomic translation refusal')
            report = normalize(json.loads(audit.read_text()))
            findings = report['findings']
            recursion = [f for f in findings if f['code']=='AT_LEFT_RECURSION']
            if {f['rule'] for f in recursion} != {r['name'] for r in case['rules']}:
                raise ValueError(case['name'] + ': original rule inventory changed')
            for finding in recursion:
                details = finding['details']
                if not details['normalization_guards'] or not details['source']['plan']['complete']:
                    raise ValueError(case['name'] + ': missing observed guards or complete source plan')
            rows.append({'name':case['name'], 'exit_code':result['exit_code'], 'output_preserved':True,
                         'findings':findings})
    if oracle.digest(tool) != before:
        raise ValueError('translator changed during measurement')
    if args.refresh:
        tool_root = tool.parent.parent
        revision = subprocess.check_output(['git','-C',str(tool_root),'rev-parse','HEAD'],text=True).strip()
        dirty = bool(subprocess.check_output(['git','-C',str(tool_root),'status','--porcelain'],text=True))
        result = {'schema':1, 'provenance':{'translator_sha256':before,'source_base':revision,
            'source_dirty':dirty,'configuration':['--exact-lexer','--prediction'],
            'interpretation':'Current instrumented guard exits, separate from historical generic findings. No acceptance promotion.'},
            'cases':rows}
        REPORT.write_text(json.dumps(result,indent=2)+'\n')
        data['files'] = [f for f in data['files'] if f['path']!='current_refusals.json']
        data['files'].append({'path':'current_refusals.json','sha256':oracle.digest(REPORT)})
        data['files'].sort(key=lambda f:f['path'])
        oracle.MANIFEST.write_text(json.dumps(data,indent=2)+'\n')
    elif rows != json.loads(REPORT.read_text())['cases']:
        raise ValueError('current refusal evidence differs from pinned Wave 0 findings')
    print('Observed normalization guards: 21 roots / 25 rules; every refusal preserved output')


if __name__ == '__main__':
    main()
