# wbuild: name=javascript_runtime_environments_test
# wbuild: target=javascript_runtime_environments_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 tests/javascript/runtime_environments_test.w -o bin/javascript_runtime_environments_test"
# wbuild: step="bin/javascript_runtime_environments_test" expect_stdout="javascript_runtime_environments_test: OK"
# wbuild: step="bin/javascript_runtime_environments_test memory" expect_stdout="javascript_runtime_environments_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime


js_completion* environment_eval(js_runtime* rt, char* source):
	return js_runtime_eval(rt, source, strlen(source), 10000)


void environment_number(js_runtime* rt, char* source, float64 expected):
	js_completion* result = environment_eval(rt, source)
	assert_equal(0, result.status)
	assert_equal(3, result.value.kind)
	assert1(result.value.number == expected)


void test_environments():
	js_runtime* rt = js_runtime_new()
	environment_number(rt, c"var repeated = 42; var repeated; repeated;", 42.0)
	environment_number(rt, c"var repeated = 7; repeated;", 7.0)
	environment_number(rt, c"function parameter(a) { var a; return a; } parameter(13);", 13.0)
	environment_number(rt, c"function scope(a) { { var a = 11; } return a; } scope(2);", 11.0)
	environment_number(rt, c"function hoist() { if (false) { var x = 1; } return typeof x === 'undefined' ? 1 : 0; } hoist();", 1.0)
	environment_number(rt, c"function hidden() { function inner() { var noLeak = 2; } return typeof noLeak === 'undefined' ? 1 : 0; } hidden();", 1.0)
	environment_number(rt, c"function duplicate() { return 1; } function duplicate() { return 2; } duplicate();", 2.0)
	environment_number(rt, c"function duplicate() { return 3; } duplicate();", 3.0)
	environment_number(rt, c"function replace(a) { function a() { return 5; } var a; return a(); } replace(1);", 5.0)
	environment_number(rt, c"function shadow() { var n = 6; { let n = 1; n++; } return n; } shadow();", 6.0)
	environment_number(rt, c"let callbacks = []; for (var i = 0; i < 3; i++) { callbacks[i] = function() { return i; }; } callbacks[0]() + callbacks[2]();", 6.0)
	environment_number(rt, c"var caught; try { throw 8; } catch (caught) { var caught = 9; } typeof caught === 'undefined' ? 1 : 0;", 1.0)
	assert_equal(2, environment_eval(rt, c"let repeated = 1;").status)
	assert_equal(0, environment_eval(rt, c"const immutable = 1;").status)
	assert_equal(2, environment_eval(rt, c"let untouched = 0; var immutable;").status)
	environment_number(rt, c"let untouched = 42; untouched;", 42.0)
	assert_equal(2, environment_eval(rt, c"function immutable() {}").status)
	environment_number(rt, c"(function self() { self = 1; return typeof self === 'function' ? 1 : 0; })();", 1.0)
	environment_number(rt, c"(function self() { self = 1; return 6; })();", 6.0)
	assert_equal(2, environment_eval(rt, c"(function self() { 'use strict'; self = 1; })();").status)
	assert_equal(2, environment_eval(rt, c"(function self() { return (function() { 'use strict'; self = 1; })(); })();").status)
	assert_equal(2, environment_eval(rt, c"'use strict'; (function self() { self = 1; })();").status)
	environment_number(rt, c"(function self() { self = 1; return 7; })();", 7.0)
	js_runtime_collect(rt)
	environment_number(rt, c"callbacks[1]();", 3.0)
	js_completion* result = environment_eval(rt, c"typeof absent;")
	assert_equal(0, result.status)
	assert1(js_runtime_key_is(result.value.text, c"undefined"))
	result = environment_eval(rt, c"try { typeof tdz; let tdz; } catch (e) { e.name; }")
	assert_equal(0, result.status)
	assert1(js_runtime_key_is(result.value.text, c"ReferenceError"))
	result = environment_eval(rt, c"typeof duplicate;")
	assert_equal(0, result.status)
	assert1(js_runtime_key_is(result.value.text, c"function"))
	js_runtime_free(rt)


int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	test_environments()
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_environments_test: OK")
	return 0
