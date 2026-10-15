#!/usr/bin/env python3
"""Contract regressions for the bounded Test262 adapter (real W execution)."""
import copy
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('test262', ROOT / 'tools/test262_conformance.py')
adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter)
BINARY = ROOT / 'bin/test262_runtime_runner'


class AdapterContract(unittest.TestCase):
    def execute(self, source, mode='sloppy', budget=10000):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'test.js'
            path.write_text(('"use strict";\n' if mode == 'strict' else '') + source)
            return adapter.execute(BINARY, path, mode, 5, budget)

    def test_actual_upstream_execution(self):
        report, status = adapter.run(adapter.MANIFEST, BINARY)
        self.assertEqual(status, 0)
        self.assertEqual(report['counts'], {'PASS': 41, 'FAIL': 0, 'UNSUPPORTED': 12, 'ERROR': 0})
        self.assertEqual(report['execution_passes'], 32)
        self.assertEqual(report['assertions'], 194)
        self.assertEqual(report['variants'], 53)
        self.assertEqual(report['baseline_changes'], [])

    def test_pass_regressing_to_unsupported_fails_gate(self):
        execute = adapter.execute
        first = True

        def regress(*args, **kwargs):
            nonlocal first
            if first:
                first = False
                return {'phase': 'lower', 'outcome': 'unsupported'}
            return execute(*args, **kwargs)

        with patch.object(adapter, 'execute', side_effect=regress):
            report, status = adapter.run(adapter.MANIFEST, BINARY)
        self.assertEqual(status, 1)
        self.assertEqual(report['counts'], {'PASS': 40, 'FAIL': 0, 'UNSUPPORTED': 13, 'ERROR': 0})
        self.assertEqual(len(report['baseline_changes']), 1)
        self.assertEqual(report['baseline_changes'][0]['expected'], 'PASS')
        self.assertEqual(report['baseline_changes'][0]['actual'], 'UNSUPPORTED')

    def test_new_support_requires_baseline_review(self):
        execute = adapter.execute
        changed = False

        def improve(*args, **kwargs):
            nonlocal changed
            actual = execute(*args, **kwargs)
            if not changed and actual['outcome'] == 'unsupported':
                changed = True
                return {'phase': 'execute', 'outcome': 'normal', 'steps': 1, 'assertions': 1}
            return actual

        with patch.object(adapter, 'execute', side_effect=improve):
            report, status = adapter.run(adapter.MANIFEST, BINARY)
        self.assertEqual(status, 1)
        self.assertEqual(report['counts'], {'PASS': 42, 'FAIL': 0, 'UNSUPPORTED': 11, 'ERROR': 0})
        self.assertEqual(len(report['baseline_changes']), 1)
        self.assertEqual(report['baseline_changes'][0]['expected'], 'UNSUPPORTED')
        self.assertEqual(report['baseline_changes'][0]['actual'], 'PASS')

    def test_pinned_builtin_requirements_do_not_mask_runtime_failures(self):
        manifest, _ = adapter.load_manifest(adapter.MANIFEST)
        requirements = manifest['builtins_required']
        self.assertEqual(len(requirements), 3)
        report, status = adapter.run(adapter.MANIFEST, BINARY)
        self.assertEqual(status, 0)
        for result in report['results']:
            case = result['id'].split('#')[0]
            if case in requirements:
                self.assertEqual(result['status'], 'UNSUPPORTED')
                self.assertEqual(result['actual']['phase'], 'metadata')
                self.assertEqual(result['actual']['message'],
                                 'unsupported required built-ins: ' + ', '.join(requirements[case]))
        # Direct execution retains genuine ReferenceError, including the
        # unavailable eval/isNaN built-ins. No runtime exception is relabelled by classify.
        for source in ['unknownUserVariable;', 'eval("1 + 1");', 'isNaN(0);']:
            actual = self.execute(source)
            self.assertEqual(actual['error_type'], 'ReferenceError')
            self.assertEqual(adapter.classify({}, actual), 'FAIL')
        self.assertEqual(self.execute("assert.sameValue(Number.isFinite(1), true);")['outcome'], 'normal')
        # Claiming availability actually runs the pinned cases; it must expose
        # failures until the runtime implements the advertised capability.
        with patch.object(adapter, 'BUILTINS', adapter.KNOWN_BUILTINS):
            promoted, status = adapter.run(adapter.MANIFEST, BINARY)
        self.assertEqual(status, 1)
        self.assertEqual(promoted['counts']['FAIL'], 6)
        self.assertEqual(len(promoted['baseline_changes']), 6)

    def test_assertions_execute_and_reject_truthy_values(self):
        for source in ['assert(true);', 'assert.sameValue(NaN, NaN);', 'assert.notSameValue(0, -0);', 'assert.sameValue();']:
            actual = self.execute(source)
            self.assertEqual(actual['outcome'], 'normal', actual)
            self.assertEqual(actual['assertions'], 1)
        for source in ['assert(false);', 'assert(1);', 'assert.sameValue(1, 2);', 'assert.sameValue(0, -0);', 'assert.notSameValue(NaN, NaN);']:
            actual = self.execute(source)
            self.assertEqual(actual['outcome'], 'throw', actual)
            self.assertEqual(actual['error_type'], 'Test262Error')
            self.assertEqual(adapter.classify({}, actual), 'FAIL')

    def test_error_identity_cannot_be_spoofed(self):
        meta = {'negative': {'phase': 'runtime', 'type': 'ReferenceError'}}
        actual = self.execute('missingVariable;')
        self.assertEqual(adapter.classify(meta, actual), 'PASS')
        self.assertEqual(actual['error_type'], 'ReferenceError')
        for source in ['throw {name: "ReferenceError"};', 'throw "ReferenceError";', 'throw 3;', 'null.x;']:
            self.assertEqual(adapter.classify(meta, self.execute(source)), 'FAIL')
        wrong_phase = {'negative': {'phase': 'parse', 'type': 'ReferenceError'}}
        self.assertEqual(adapter.classify(wrong_phase, actual), 'FAIL')

    def test_parse_negative_must_not_run(self):
        meta = {'negative': {'phase': 'parse', 'type': 'SyntaxError'}}
        actual = self.execute('$DONOTEVALUATE(); var = ;')
        self.assertEqual(adapter.classify(meta, actual), 'PASS')
        self.assertEqual(actual['phase'], 'parse')
        self.assertEqual(adapter.classify(meta, self.execute('$DONOTEVALUATE();')), 'FAIL')
        self.assertEqual(adapter.classify(meta, self.execute('throw {name: "SyntaxError"};')), 'FAIL')
        actual = self.execute('let x; let x;')
        self.assertEqual(actual['phase'], 'early')
        self.assertEqual(adapter.classify(meta, actual), 'PASS')

    def test_strict_sloppy_and_fresh_realms(self):
        self.assertEqual(self.execute('(eval) = 20;', 'strict')['phase'], 'early')
        for mode in ('sloppy', 'strict'):
            actual = self.execute('assert.sameValue(typeof previous, "undefined"); var previous = 1;', mode)
            self.assertEqual(actual['outcome'], 'normal', actual)
        actual = self.execute('assert.sameValue(typeof assert, "undefined");', 'raw')
        self.assertEqual(actual['error_type'], 'ReferenceError')
        self.assertEqual(self.execute('if (typeof assert !== "undefined") throw 1;', 'raw')['outcome'], 'normal')

    def test_unsupported_helpers_are_never_passes(self):
        for source in ['assert.throws(1, function() {});', 'assert.compareArray([], []);', '$262.createRealm();', '$DONE();']:
            actual = self.execute(source)
            self.assertEqual(adapter.classify({}, actual), 'UNSUPPORTED', actual)
        self.assertEqual(adapter.classify({}, self.execute('while (true) {}', budget=10)), 'ERROR')

    def test_metadata_and_variants(self):
        def meta(fields):
            return adapter.metadata('/*---\ndescription: test\n' + fields + '\n---*/\n')
        self.assertEqual(adapter.variants(meta('')), ['sloppy', 'strict'])
        for flag, expected in [('onlyStrict', 'strict'), ('noStrict', 'sloppy'), ('raw', 'raw'), ('module', 'module')]:
            self.assertEqual(adapter.variants(meta('flags: [' + flag + ']')), [expected])
        for fields in ['flags: [module]', 'flags: [async]', 'flags: [unknownFlag]', 'includes:\n  - compareArray.js', 'features: [BigInt]']:
            self.assertIsNotNone(adapter.unsupported(meta(fields)))
        for fields in ['flags: [onlyStrict, noStrict]', 'flags: [raw, onlyStrict]', 'negative:\n  phase: runtime', 'negative:\n  phase: unknown\n  type: Error', 'flags: []\nflags: []', 'unexpected: value', 'includes: &anchor []']:
            with self.assertRaises(ValueError, msg=fields):
                meta(fields)
        parsed = meta('flags:\n  - onlyStrict\nnegative:\n  phase: runtime\n  type: ReferenceError')
        self.assertEqual(parsed['negative'], {'phase': 'runtime', 'type': 'ReferenceError'})

    def test_wrong_phase_type_and_process_errors(self):
        meta = {'negative': {'phase': 'runtime', 'type': 'ReferenceError'}}
        for actual in [
            {'phase': 'parse', 'outcome': 'error', 'error_type': 'ReferenceError'},
            {'phase': 'execute', 'outcome': 'throw', 'error_type': 'TypeError'},
            {'phase': 'execute', 'outcome': 'normal'},
        ]:
            self.assertEqual(adapter.classify(meta, actual), 'FAIL')
        for outcome in ('crash', 'timeout', 'harness_error', 'limit'):
            self.assertEqual(adapter.classify(meta, {'phase': 'process', 'outcome': outcome}), 'ERROR')
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'runner'
            path.write_text('#!/usr/bin/env python3\nprint(\'{"protocol": 1, "phase": "execute", "outcome": "normal"}\')\n')
            path.chmod(0o755)
            actual = adapter.execute(path, path, 'sloppy', 5, 100)
            self.assertEqual(actual['outcome'], 'harness_error')
            path.write_text('#!/usr/bin/env python3\nimport time\ntime.sleep(1)\n')
            self.assertEqual(adapter.execute(path, path, 'sloppy', .01, 100)['outcome'], 'timeout')
            path.write_text('#!/usr/bin/env python3\nimport os,signal\nos.kill(os.getpid(),signal.SIGKILL)\n')
            self.assertEqual(adapter.execute(path, path, 'sloppy', 5, 100)['outcome'], 'crash')

    def test_manifest_pins_and_paths(self):
        original = json.loads(adapter.MANIFEST.read_text())
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            (base / 'upstream').symlink_to(adapter.MANIFEST.parent / 'upstream', target_is_directory=True)
            for mutate in [
                lambda m: m['files'][0].update(sha256='0' * 64),
                lambda m: m['builtins_required'].update(unpinned=['eval']),
                lambda m: m['builtins_required'].update({m['cases'][0]: ['unknownBuiltin']}),
                lambda m: m['builtins_required'].update({m['cases'][0]: ['eval', 'eval']}),
                lambda m: m['builtins_required'].update({m['cases'][0]: []}),
                lambda m: m['files'][0].update(path='upstream/../escape', upstream_path='../escape'),
                lambda m: m['cases'].append(m['cases'][0]),
                lambda m: m['upstream'].update(commit='main'),
                lambda m: m['files'].pop(0),
                lambda m: m['baseline'].pop(next(iter(m['baseline']))),
                lambda m: m['baseline'].update(extra={'status': 'PASS'}),
                lambda m: m['baseline'][next(iter(m['baseline']))].update(status='FAIL'),
                lambda m: next(v for v in m['baseline'].values() if v['status'] == 'UNSUPPORTED').pop('reason'),
                lambda m: next(v for v in m['baseline'].values() if v['status'] == 'UNSUPPORTED').update(reason=' '),
            ]:
                value = copy.deepcopy(original)
                mutate(value)
                manifest = base / 'manifest.json'
                manifest.write_text(json.dumps(value))
                with self.assertRaises((ValueError, OSError)):
                    adapter.load_manifest(manifest)


if __name__ == '__main__':
    unittest.main()
