#!/usr/bin/env python3
"""Infrastructure regression tests for the Wave 0 evidence gate (no Java required)."""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('lr_oracle', Path(__file__).with_name('antlr_left_recursion_oracle.py'))
oracle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(oracle)


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.data = oracle.load_manifest()
        self.snapshots = json.loads(oracle.SNAPSHOTS.read_text())

    def test_original_inventory_and_graph(self):
        pairs = {(c['name'], r['name']) for c in self.data['cases'] for r in c['rules']}
        baseline = json.loads((oracle.ROOT/'libs/extras/grammars/antlr_to_pg/sweep_remaining.json').read_text())
        expected = {(c['name'], f['rule']) for c in baseline['cases']
                    for f in c.get('exact_permissive', {}).get('findings', []) if f['code']=='AT_LEFT_RECURSION'}
        self.assertEqual(pairs, expected)
        self.assertEqual(sum(bool(c['host_findings']) for c in self.data['cases']), 8)
        self.assertEqual(sum(c['java_compilation']['status']=='pass' for c in self.snapshots['cases']), 15)
        self.assertTrue(all(c['runtime']['status'] in ('not_run','blocked') for c in self.snapshots['cases']))

    def test_no_default_snapshot_mutation(self):
        before = oracle.SNAPSHOTS.read_bytes(), oracle.MANIFEST.read_bytes()
        subprocess.run([sys.executable, oracle.__file__], check=True, stdout=subprocess.PIPE)
        self.assertEqual(before, (oracle.SNAPSHOTS.read_bytes(), oracle.MANIFEST.read_bytes()))

    def test_fixture_tampering_rejected(self):
        with patch.object(oracle, 'digest', return_value='wrong'):
            with self.assertRaisesRegex(ValueError, 'hash/path mismatch'):
                oracle.load_manifest()

    def test_missing_rule_or_alternative_rejected(self):
        changed = copy.deepcopy(self.snapshots)
        changed['cases'][0]['rules'].pop()
        with self.assertRaisesRegex(ValueError, 'missing rule'):
            oracle.validate_snapshots(self.data, changed)
        changed = copy.deepcopy(self.snapshots)
        changed['cases'][0]['rules'][0]['alternatives'].pop(0)
        with self.assertRaisesRegex(ValueError, 'alternative inventory'):
            oracle.validate_snapshots(self.data, changed)

    def test_refresh_cannot_bless_missing_runtime_or_final_alternative(self):
        for mutate in (
                lambda s: s['minimal'][0].pop('runtime'),
                lambda s: s['minimal'][0]['runtime'].pop(),
                lambda s: s['cases'][0]['rules'][0]['alternatives'].pop(),
                lambda s: s['cases'][0]['generation'].update(status='fail'),
                lambda s: s['minimal'][0]['runtime'][0].update(complete=False)):
            changed = copy.deepcopy(self.snapshots)
            mutate(changed)
            with self.assertRaises(ValueError):
                oracle.validate_snapshots(self.data, changed)

    def test_negative_fixture_cannot_bless_jvm_failure(self):
        case = next(c for c in self.data['minimal'] if c['name']=='MutualCycle')
        for code, diagnostic in ((-9, ''), (1, 'Could not create the Java Virtual Machine'),
                                 (1, 'Exception in thread "main" java.lang.RuntimeException'),
                                 (1, 'unexplained process failure')):
            with tempfile.TemporaryDirectory() as directory:
                with patch.object(oracle, 'command', return_value={'status':'fail', 'exit_code':code,
                        'stdout':'', 'stderr':diagnostic}):
                    with self.assertRaises(ValueError):
                        oracle.run_case(case, Path('jar'), Path(directory), Path('probe'), 90, True)

    def test_both_java_tools_must_be_17(self):
        for values in [('openjdk version "21.0.1"', 'javac 17.0.1'),
                       ('openjdk version "17.0.1"', 'javac 21.0.1')]:
            with patch.object(oracle.subprocess, 'check_output', side_effect=values):
                with self.assertRaisesRegex(ValueError, 'major 17'):
                    oracle.versions()

    def test_oracle_distinguishes_grouping_and_option_locations(self):
        fixtures = {c['name']:c for c in self.snapshots['minimal']}
        left = fixtures['NestedAssoc']['runtime'][0]
        right = fixtures['RightAssoc']['runtime'][0]
        self.assertTrue(left['accepted'] and right['accepted'])
        # Left-associative nested option is ignored; the first operand is itself an assignment.
        self.assertEqual(left['tree']['children'][0]['children'][0]['context'], 'AssignContext')
        # Proper outer option makes the right operand a power context.
        self.assertEqual(right['tree']['children'][0]['children'][2]['context'], 'PowerContext')
        self.assertEqual(fixtures['NestedAssoc']['generation']['stderr'], '')
        self.assertIn('warning(157)', fixtures['MisplacedAssoc']['generation']['stderr'])
        self.assertIn('error(169)', fixtures['AttachedAssoc']['generation']['stderr'])
        self.assertIn('error(119)', fixtures['MutualCycle']['generation']['stderr'])


if __name__ == '__main__':
    unittest.main()
