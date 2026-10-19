#!/usr/bin/env python3
"""Contract regressions for the bounded Test262 adapter (real W execution)."""
import copy
import importlib.util
import json
import subprocess
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
    def test_native_quota_failure_preserves_sentinel_and_roots(self):
        for extra in ([], ['memory']):
            process = subprocess.run([str(BINARY), '--quota-contract', *extra], capture_output=True, text=True, timeout=10)
            self.assertEqual(process.returncode, 0, process.stderr)
            self.assertEqual(process.stdout, 'Test262 native quota ownership: OK\n')

    def execute(self, source, mode='sloppy', budget=10000, asynchronous=False):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'test.js'
            path.write_text(('"use strict";\n' if mode == 'strict' else '') + source)
            return adapter.execute(BINARY, path, mode, 5, budget, asynchronous=asynchronous)

    def test_actual_upstream_execution(self):
        report, status = adapter.run(adapter.MANIFEST, BINARY)
        self.assertEqual(status, 0)
        self.assertEqual(report['counts'], {'PASS': 131, 'FAIL': 0, 'UNSUPPORTED': 20, 'ERROR': 0})
        self.assertEqual(report['execution_passes'], 122)
        self.assertEqual(report['assertions'], 360)
        self.assertEqual(report['variants'], 151)
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
        self.assertEqual(report['counts'], {'PASS': 130, 'FAIL': 0, 'UNSUPPORTED': 21, 'ERROR': 0})
        self.assertEqual(len(report['baseline_changes']), 1)
        self.assertEqual(report['baseline_changes'][0]['expected'], 'PASS')
        self.assertEqual(report['baseline_changes'][0]['actual'], 'UNSUPPORTED')

    def test_new_support_requires_baseline_review(self):
        # Model an older status baseline for a case which the real executor
        # now passes; newly available support still requires explicit review.
        manifest, sources = adapter.load_manifest(adapter.MANIFEST)
        manifest = copy.deepcopy(manifest)
        case_id = next(key for key, value in manifest['baseline'].items()
                       if value['status'] == 'PASS')
        manifest['baseline'][case_id] = {'status': 'UNSUPPORTED', 'reason': 'previous runtime subset'}
        with patch.object(adapter, 'load_manifest', return_value=(manifest, sources)):
            report, status = adapter.run(adapter.MANIFEST, BINARY)
        self.assertEqual(status, 1)
        self.assertEqual(report['counts'], {'PASS': 131, 'FAIL': 0, 'UNSUPPORTED': 20, 'ERROR': 0})
        self.assertEqual(len(report['baseline_changes']), 1)
        self.assertEqual(report['baseline_changes'][0]['expected'], 'UNSUPPORTED')
        self.assertEqual(report['baseline_changes'][0]['actual'], 'PASS')

    def test_pinned_builtin_requirements_do_not_mask_runtime_failures(self):
        manifest, _ = adapter.load_manifest(adapter.MANIFEST)
        requirements = manifest['builtins_required']
        self.assertEqual(len(requirements), 4)
        report, status = adapter.run(adapter.MANIFEST, BINARY)
        self.assertEqual(status, 0)
        for result in report['results']:
            case = result['id'].split('#')[0]
            if case in requirements and not set(requirements[case]) <= adapter.BUILTINS:
                self.assertEqual(result['status'], 'UNSUPPORTED')
                self.assertEqual(result['actual']['phase'], 'metadata')
                self.assertEqual(result['actual']['message'],
                                 'unsupported required built-ins: ' + ', '.join(sorted(set(requirements[case]) - adapter.BUILTINS)))
        # Direct execution retains genuine ReferenceError, including the
        # unavailable eval built-in. No runtime exception is relabelled by classify.
        for source in ['unknownUserVariable;', 'eval("1 + 1");']:
            actual = self.execute(source)
            self.assertEqual(actual['error_type'], 'ReferenceError')
            self.assertEqual(adapter.classify({}, actual), 'FAIL')
        self.assertEqual(self.execute("assert.sameValue(Number.isFinite(1), true);assert.sameValue(isNaN(0), false);assert.sameValue(isNaN(undefined), true);")['outcome'], 'normal')
        # Claiming availability actually runs the pinned cases; it must expose
        # eval failures. Check Number constants directly as well, so passing
        # NaN arithmetic cannot conceal an unavailable required constant.
        with patch.object(adapter, 'BUILTINS', adapter.KNOWN_BUILTINS):
            promoted, status = adapter.run(adapter.MANIFEST, BINARY)
        self.assertEqual(status, 1)
        self.assertEqual(promoted['counts']['FAIL'], 2)
        self.assertEqual(len(promoted['baseline_changes']), 2)
        self.assertEqual(self.execute("assert.sameValue(Number.NaN, NaN);assert.sameValue(Number.POSITIVE_INFINITY, Infinity);assert.sameValue(Number.NEGATIVE_INFINITY, -Infinity);")['outcome'], 'normal')

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
        for source in ['assert.compareArray([], []);', '$262.createRealm();', '$DONE();']:
            actual = self.execute(source)
            self.assertEqual(adapter.classify({}, actual), 'UNSUPPORTED', actual)
        self.assertEqual(adapter.classify({}, self.execute('while (true) {}', budget=10)), 'ERROR')

    def test_native_throws_checks_constructor_and_runs_callback(self):
        for source in [
            'assert.throws(ReferenceError, function(){missingIdentifier;});',
            'assert.throws(Error, function(){throw new Error("expected");});',
            'function E(){} assert.throws(E, function(){throw new E();});',
        ]:
            actual = self.execute(source)
            self.assertEqual(actual['outcome'], 'normal', actual)
            self.assertEqual(actual['assertions'], 1)
        for source in [
            'assert.throws(Error, function(){});',
            'assert.throws(Error, function(){throw "Error";});',
            'assert.throws(Error, function(){missingIdentifier;});',
            'assert.throws(Error, 1);',
            'function bad(){} bad.constructor=TypeError;assert.throws(TypeError,function(){throw bad;});',
            'assert.throws(Error, function(){throw 1n;});',
        ]:
            actual = self.execute(source)
            self.assertEqual(actual['outcome'], 'throw', actual)
            self.assertEqual(actual['error_type'], 'Test262Error')
        actual = self.execute('assert.throws(Error, function(){while(true){}});', budget=100)
        self.assertEqual(actual['outcome'], 'limit')

    def test_async_done_microtasks_and_failure_identity(self):
        for source in [
            'Promise.resolve().then(function(){assert.sameValue(1,1);$DONE();});',
            'async function f(){await Promise.resolve();$DONE();} f();',
        ]:
            actual = self.execute(source, asynchronous=True)
            self.assertEqual(actual['outcome'], 'normal', actual)
            self.assertEqual(actual['done_calls'], 1)
        for source in ['$DONE();$DONE();', 'Promise.resolve().then(function(){$DONE();$DONE();});']:
            actual = self.execute(source, asynchronous=True)
            self.assertEqual(actual['outcome'], 'throw', actual)
            self.assertEqual(actual['error_type'], 'Test262Error')
        actual = self.execute('Promise.resolve().then(function(){$DONE(new ReferenceError("expected"));});', asynchronous=True)
        self.assertEqual(actual['outcome'], 'throw')
        self.assertEqual(actual['error_type'], 'ReferenceError')
        self.assertEqual(adapter.classify({'negative': {'phase': 'runtime', 'type': 'ReferenceError'}}, actual), 'PASS')
        actual = self.execute('new Promise(function(){});', asynchronous=True)
        self.assertEqual(actual['outcome'], 'incomplete')
        self.assertEqual(adapter.classify({}, actual), 'ERROR')
        actual = self.execute('queueMicrotask(function(){while(true){}});', asynchronous=True, budget=100)
        self.assertEqual(actual['outcome'], 'limit')

    def test_complete_inventory_keeps_unexecuted_denominator(self):
        manifest, _ = adapter.load_manifest(adapter.MANIFEST)
        inventory = adapter.suite_inventory(adapter.MANIFEST, manifest)
        self.assertEqual(inventory['counts']['candidate_test_files_excluding_fixtures'], 53616)
        self.assertEqual(inventory['unselected_files'], 53616 - len(manifest['cases']))
        self.assertIsNone(inventory['runnable_variants'])

    def test_original_upstream_assertions_execute_without_native_replacement(self):
        _, sources = adapter.load_manifest(adapter.MANIFEST)
        setup, reason = adapter.prepare_harness(sources, [])
        self.assertIsNone(reason)
        with tempfile.TemporaryDirectory() as directory:
            harness = Path(directory) / 'harness.js'
            source = Path(directory) / 'test.js'
            harness.write_text(setup)
            for text, expected in [
                ('assert.sameValue(1,1);assert.throws(TypeError,function(){null.x;});', 'normal'),
                ('assert.sameValue(1,2);', 'throw'),
                ('Promise.resolve().then(function(){assert.sameValue(1,1);$DONE();});', 'normal'),
            ]:
                source.write_text(text)
                actual = adapter.execute(BINARY, source, 'sloppy', 5, 100000,
                                         asynchronous='Promise' in text, harness_path=harness)
                self.assertEqual(actual['outcome'], expected, actual)
                self.assertEqual(actual['phase'], 'execute')
                self.assertFalse(actual['native_assertion_counter'])
            # Harness startup is a different phase, never evidence for a test's
            # runtime-negative expectation. Strict directives stay on the test.
            harness.write_text('missingHarnessGlobal;')
            source.write_text('throw new ReferenceError();')
            actual = adapter.execute(BINARY, source, 'sloppy', 5, 100000, harness_path=harness)
            self.assertEqual(actual['phase'], 'harness')
            self.assertEqual(adapter.classify({'negative': {'phase': 'runtime', 'type': 'ReferenceError'}}, actual), 'ERROR')
            harness.write_text(setup)
            source.write_text('"use strict"; var o={};Object.defineProperty(o,"x",{value:1});assert.throws(TypeError,function(){o.x=2;});')
            actual = adapter.execute(BINARY, source, 'strict', 5, 100000, harness_path=harness)
            self.assertEqual(actual['outcome'], 'normal', actual)

    def test_original_include_resolution_rejects_missing_cycles_and_capability_gaps(self):
        _, sources = adapter.load_manifest(adapter.MANIFEST)
        source, reason = adapter.prepare_harness(sources, ['compareArray.js'])
        self.assertIsNone(reason)
        self.assertIn(sources['upstream/harness/compareArray.js'], source)
        source, reason = adapter.prepare_harness(sources, ['propertyHelper.js'])
        self.assertIsNone(reason)
        self.assertIn(sources['upstream/harness/propertyHelper.js'], source)
        constructor_setup, reason = adapter.prepare_harness(sources, ['isConstructor.js'])
        self.assertIsNone(reason)
        with patch.object(adapter, 'FEATURES', adapter.FEATURES - {'Reflect.construct'}):
            _, blocked = adapter.prepare_harness(sources, ['isConstructor.js'])
            self.assertIn('Reflect.construct', blocked)
        with tempfile.TemporaryDirectory() as directory:
            harness = Path(directory) / 'harness.js'
            harness.write_text(constructor_setup)
            test = Path(directory) / 'test.js'
            test.write_text('assert(isConstructor(function F(){}));assert(!isConstructor(()=>{}));')
            actual = adapter.execute(BINARY, test, 'sloppy', 5, 100000, harness_path=harness)
            self.assertEqual(actual['outcome'], 'normal', actual)
        for includes in [['missing.js'], ['../assert.js']]:
            with self.assertRaises(ValueError):
                adapter.prepare_harness(sources, includes)
        def fixture(includes, body):
            return '/*---\ndescription: dependency contract\nincludes: [' + includes + ']\n---*/\n' + body
        sources['upstream/harness/a.js'] = fixture('b.js', 'var afterDependency = 1;')
        sources['upstream/harness/b.js'] = fixture('', 'var beforeDependent = 1;')
        source, reason = adapter.prepare_harness(sources, ['a.js', 'b.js'])
        self.assertIsNone(reason)
        self.assertLess(source.index('var beforeDependent'), source.index('var afterDependency'))
        self.assertEqual(source.count('var beforeDependent'), 1)
        sources['upstream/harness/b.js'] = fixture('a.js', '')
        with self.assertRaises(ValueError):
            adapter.prepare_harness(sources, ['a.js'])

    def test_duplicate_and_nonfinite_protocol_fields_are_rejected(self):
        for text in ['{"outcome":"throw","outcome":"normal"}', '{"steps":NaN}', '{"steps":Infinity}']:
            with self.assertRaises(ValueError):
                adapter.strict_json(text)

    def test_metadata_and_variants(self):
        def meta(fields):
            return adapter.metadata('/*---\ndescription: test\n' + fields + '\n---*/\n')
        self.assertEqual(adapter.variants(meta('')), ['sloppy', 'strict'])
        for flag, expected in [('onlyStrict', 'strict'), ('noStrict', 'sloppy'), ('raw', 'raw'), ('module', 'module')]:
            self.assertEqual(adapter.variants(meta('flags: [' + flag + ']')), [expected])
        for fields in ['flags: [module]', 'flags: [unknownFlag]', 'includes:\n  - compareArray.js', 'features: [BigInt]']:
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

    def test_implemented_reflection_features_reach_execution(self):
        meta = {'flags': [], 'includes': [], 'features': ['Reflect', 'Reflect.set', 'Object.is', 'arrow-function']}
        self.assertIsNone(adapter.unsupported(meta))
        actual = self.execute("const o={x:3};assert.sameValue(Reflect.get(o,'x'),3);assert.sameValue(Reflect.set(o,'x',4),true);assert.sameValue(o.x,4);assert.sameValue(Object.is(NaN,NaN),true);assert.sameValue((x=>x+1)(2),3);")
        self.assertEqual(actual['outcome'], 'normal', actual)
        self.assertIn('Symbol', adapter.unsupported(dict(meta, features=['Symbol'])))

    def test_native_script_global_object_and_lexical_bindings(self):
        for mode in ('sloppy', 'strict'):
            actual = self.execute("assert.sameValue(this,globalThis);assert.sameValue(Object.getOwnPropertyDescriptor(this,'globalThis').enumerable,false);assert.sameValue(this.Object,Object);var x=3;assert.sameValue(this.x,3);this.x=4;assert.sameValue(x,4);let lexical=5;assert.sameValue(this.lexical,undefined);assert.sameValue(lexical,5);Object.defineProperty(this,'throwing',{get:function(){throw 23;}});try{throwing;throw 'lost';}catch(e){assert.sameValue(e,23);}", mode)
            self.assertEqual(actual['outcome'], 'normal', actual)
        actual = self.execute("if(this!==globalThis || this.Object!==Object) throw 1;", 'raw')
        self.assertEqual(actual['outcome'], 'normal', actual)

    def test_error_cause_capability_executes_native_semantics(self):
        source = "let calls=0;let parent={};Object.defineProperty(parent,'cause',{get:function(){calls++;return 23;}});let options=Object.create(parent);let e=new URIError('message',options);assert.sameValue(e.cause,23);assert.sameValue(calls,1);assert.sameValue(e.constructor,URIError);assert.sameValue(Object.getOwnPropertyDescriptor(e,'cause').enumerable,false);let n=new EvalError('text',{cause:undefined});assert.sameValue(Object.hasOwn(n,'cause'),true);let bad={};Object.defineProperty(bad,'cause',{get:function(){throw 9;}});let caught;try{new Error('x',bad);}catch(e){caught=e;}assert.sameValue(caught,9);"
        for mode in ('sloppy', 'strict'):
            actual = self.execute(source, mode)
            self.assertEqual(actual['outcome'], 'normal', actual)
            self.assertEqual(actual['assertions'], 6)
        self.assertIn('error-cause', adapter.FEATURES)

    def test_error_brand_capability_uses_internal_identity(self):
        source = "let actual=new TypeError('x');let fake=Object.create(TypeError.prototype);fake.name='TypeError';assert.sameValue(Error.isError(actual),true);assert.sameValue(Error.isError(fake),false);assert.sameValue(Error.isError(TypeError.prototype),false);Object.setPrototypeOf(actual,null);assert.sameValue(Error.isError(actual),true);let effects=0;let guarded={};Object.defineProperty(guarded,'name',{get:function(){effects++;throw 23;}});assert.sameValue(Error.isError(guarded),false);assert.sameValue(effects,0);assert.throws(TypeError,function(){new Error.isError();});"
        for mode in ('sloppy', 'strict'):
            actual = self.execute(source, mode)
            self.assertEqual(actual['outcome'], 'normal', actual)
            self.assertEqual(actual['assertions'], 7)
        self.assertIn('Error.isError', adapter.FEATURES)
        for dependency in ('Symbol', 'Proxy', 'cross-realm'):
            self.assertIsNotNone(adapter.unsupported({'features': ['Error.isError', dependency], 'flags': [], 'includes': []}))

    def test_invalid_utf8_output_is_error(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / 'bad-runner'
            binary.write_text("#!/usr/bin/env python3\nimport os;os.write(1,b'\\xff')\n")
            binary.chmod(0o755)
            actual = adapter.execute(binary, Path(directory) / 'test.js', 'sloppy', 1, 1000)
            self.assertEqual(adapter.classify({}, actual), 'ERROR')
            self.assertEqual(actual['stdout_hex'], 'ff')

    def test_missing_driver_preserves_variant_denominator(self):
        with tempfile.TemporaryDirectory() as directory:
            report, status = adapter.run(adapter.MANIFEST, Path(directory) / 'absent')
        self.assertEqual(status, 1)
        self.assertEqual(report['variants'], 151)
        self.assertEqual(len(report['results']), 151)
        self.assertGreater(report['counts']['ERROR'], 0)
        self.assertEqual(report['counts']['PASS'], 0)
        self.assertIsNone(report['evidence']['runner_sha256'])
        self.assertTrue(report['evidence']['runner_hash_error'])


if __name__ == '__main__':
    unittest.main()
