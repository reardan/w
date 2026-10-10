#!/usr/bin/env python3
"""Contract tests for the native conformance gate, including failure paths."""
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / 'tools'))
import javascript_conformance as runner


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.source = self.directory / 'case.js'
        self.source.write_text('let x=42; x;\n')
        self.expected = {'phase': 'execute', 'outcome': 'normal', 'value': {'type': 'number', 'value': '42.0'}}
        self.case = {'id': 'case', 'path': 'case.js', 'sha256': hashlib.sha256(self.source.read_bytes()).hexdigest(),
                     'goal': 'script', 'spec': 'https://tc39.es/ecma262/multipage/', 'expected': self.expected}
        self.manifest = self.directory / 'manifest.json'
        self.data = {'version': 1, 'kind': 'native-ecmascript', 'cases': [self.case]}
        self.binary = ROOT / 'bin/javascript_runtime_runner'

    def save(self):
        self.manifest.write_text(json.dumps(self.data))

    def test_actual_execution_and_fresh_realms(self):
        for _ in range(2):
            actual = runner.execute(self.binary, self.source, self.case, 10)
            self.assertEqual(runner.classify(self.case, actual), 'PASS')
        self.save()
        report, status = runner.run(self.manifest, self.binary, 10)
        self.assertEqual(status, 0)
        self.assertEqual(report['execution_passes'], 1)

    def test_phase_boundaries_and_limit(self):
        for source, phase, outcome in [('let = ;', 'parse', 'error'),
                                        ('let x; let x;', 'early', 'error'),
                                        ('class C {}', 'lower', 'unsupported'),
                                        ('while(true) {}', 'execute', 'limit')]:
            self.source.write_text(source)
            actual = runner.execute(self.binary, self.source, dict(self.case, budget=20), 10)
            self.assertEqual((actual['phase'], actual['outcome']), (phase, outcome))

    def test_expected_failures_are_exact_and_xpass_fails(self):
        wrong = {'phase': 'execute', 'outcome': 'normal', 'value': {'type': 'undefined'}}
        self.case['xfail'] = {'bug': 'JS-TEST', 'reason': 'test', 'observed': wrong}
        self.assertEqual(runner.classify(self.case, wrong), 'XFAIL')
        self.assertEqual(runner.classify(self.case, self.expected), 'XPASS')
        changed = dict(wrong, outcome='throw')
        self.assertEqual(runner.classify(self.case, changed), 'FAIL')
        self.save()
        report, status = runner.run(self.manifest, self.binary, 10)
        self.assertEqual(status, 1)
        self.assertEqual(report['counts'], {'XPASS': 1})

    def test_unexpected_failure_has_nonzero_exit(self):
        self.case['expected'] = {'phase': 'execute', 'outcome': 'normal', 'value': {'type': 'undefined'}}
        self.save()
        report, status = runner.run(self.manifest, self.binary, 10)
        self.assertEqual(status, 1)
        self.assertEqual(report['counts'], {'FAIL': 1})

    def test_malformed_metadata_and_pins(self):
        original = copy.deepcopy(self.data)
        mutations = [lambda d: d.update(kind='test262'),
                     lambda d: d['cases'][0].update(flags=['async']),
                     lambda d: d['cases'][0].update(budget=True),
                     lambda d: d['cases'][0].update(sha256='bad'),
                     lambda d: d['cases'][0].update(expected={'phase': 'parse', 'outcome': 'normal'}),
                     lambda d: d['cases'][0].update(xfail={'bug': '', 'reason': 'test', 'observed': self.expected}),
                     lambda d: d['cases'][0].update(path='../escape.js'),
                     lambda d: d['cases'].append(copy.deepcopy(d['cases'][0]))]
        for mutate in mutations:
            self.data = copy.deepcopy(original)
            mutate(self.data)
            self.save()
            with self.assertRaises(ValueError):
                runner.load_manifest(self.manifest)

    def test_harness_errors_and_crashes_cannot_be_expected_failures(self):
        for outcome in ('crash', 'timeout', 'harness_error'):
            actual = {'phase': 'process', 'outcome': outcome}
            case = dict(self.case, xfail={'observed': actual})
            self.assertEqual(runner.classify(case, actual), 'ERROR')
        for code, stdout, outcome in [(-11, '', 'crash'), (2, '', 'harness_error'),
                                       (0, '{}', 'harness_error'), (0, 'not json', 'harness_error'),
                                       (0, '{"protocol":1,"phase":"parse","outcome":"normal"}', 'harness_error')]:
            result = subprocess.CompletedProcess([], code, stdout, '')
            with patch.object(runner.subprocess, 'run', return_value=result):
                self.assertEqual(runner.execute(self.binary, self.source, self.case, 1)['outcome'], outcome)
        with patch.object(runner.subprocess, 'run', side_effect=subprocess.TimeoutExpired([], 1)):
            self.assertEqual(runner.execute(self.binary, self.source, self.case, 1)['outcome'], 'timeout')

    def test_cli_reports_invalid_manifest_as_json(self):
        self.manifest.write_text('{broken')
        proc = subprocess.run([sys.executable, str(ROOT / 'tools/javascript_conformance.py'),
                               '--manifest', str(self.manifest)], capture_output=True, text=True)
        self.assertEqual(proc.returncode, 2)
        self.assertIn('harness_error', json.loads(proc.stdout))


if __name__ == '__main__':
    unittest.main()
