# wbuild: name=javascript_runtime_annexb_test
# wbuild: target=javascript_runtime_annexb_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 tests/javascript/runtime_annexb_test.w -o bin/javascript_runtime_annexb_test"
# wbuild: step="bin/javascript_runtime_annexb_test" expect_stdout="javascript_runtime_annexb_test: OK"
# wbuild: step="bin/javascript_runtime_annexb_test memory" expect_stdout="javascript_runtime_annexb_test: OK"
# Annex B runtime semantics (reardan/w#840): block and if-clause function
# declarations, labelled functions, legacy octal literals and web-compat
# function-call assignment targets.
import lib.assert
import lib.args
import libs.extras.javascript.runtime


void annexb_number(char* source, float64 expected):
	js_runtime* rt = js_runtime_new()
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 100000)
	if (result.status != 0 || result.value.kind != 3 || result.value.number != expected):
		println2(source)
		println2(result.message)
	assert_equal(0, result.status)
	assert_equal(3, result.value.kind)
	assert1(result.value.number == expected)
	js_runtime_free(rt)


void annexb_string(char* source, char* expected):
	js_runtime* rt = js_runtime_new()
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 100000)
	if (result.status != 0): println2(source)
	assert_equal(0, result.status)
	assert_equal(4, result.value.kind)
	js_text* text = js_runtime_key(expected)
	assert1(js_text_equal(text, result.value.text))
	js_text_free(text)
	js_runtime_free(rt)


# A completion that throws an engine ReferenceError.
void annexb_reference_error(char* source):
	js_runtime* rt = js_runtime_new()
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 100000)
	assert_equal(2, result.status)
	assert_equal(0, strcmp(result.value.intrinsic_error_name, c"ReferenceError"))
	js_runtime_free(rt)


void annexb_block_functions():
	# Var binding initialized to undefined, then assigned when evaluated.
	annexb_string(c"var before = typeof f; { function f() {} } before + typeof f;", c"undefinedfunction")
	annexb_number(c"function g() { var a = h; { function h() { return 2; } } return a === undefined ? h() : 0; } g();", 2.0)
	# A parameter, enclosing let, or enclosing block function blocks the hoist.
	annexb_number(c"function g(h) { { function h() {} } return h; } g(5);", 5.0)
	annexb_number(c"function g() { let k = 4; { function k() {} } return k; } g();", 4.0)
	annexb_number(c"function g() { { function m() { return 1; } { function m() { return 2; } } } return m(); } g();", 1.0)
	annexb_number(c"function g() { for (let n = 0; n < 1; n++) { function n() {} } return typeof n === 'undefined' ? 1 : 0; } g();", 1.0)
	# Sloppy blocks may repeat a plain function name; the last one wins.
	annexb_number(c"function g() { { function q() { return 1; } function q() { return 2; } } return q(); } g();", 2.0)
	# Strict code keeps block functions block-scoped.
	annexb_string(c"'use strict'; { function z() {} } typeof z;", c"undefined")
	annexb_string(c"function s() { 'use strict'; { function z() {} } return typeof z; } s();", c"undefined")


void annexb_clause_functions():
	annexb_number(c"function g() { if (true) function c() { return 6; } return c(); } g();", 6.0)
	annexb_string(c"function g() { if (false) function d() {} return typeof d; } g();", c"undefined")
	annexb_number(c"function g() { if (false) ; else function e() { return 7; } return e(); } g();", 7.0)
	annexb_number(c"function g() { let f = 3; if (true) function f() {} return f; } g();", 3.0)


void annexb_labelled_functions():
	annexb_number(c"label: function g() { return 8; } g();", 8.0)
	annexb_number(c"a: b: function g() { return 9; } g();", 9.0)


void annexb_legacy_literals():
	annexb_number(c"010;", 8.0)
	annexb_number(c"0777;", 511.0)
	annexb_number(c"08;", 8.0)
	annexb_number(c"019.5;", 19.5)
	annexb_string(c"'\\101' + '\\8';", c"A8")


void annexb_call_targets():
	annexb_reference_error(c"function f() {} f() = 1;")
	annexb_reference_error(c"function f() {} f()++;")
	annexb_reference_error(c"function f() {} --f();")
	annexb_reference_error(c"var o = { m() {} }; o.m() += 1;")
	# The call is evaluated before the ReferenceError.
	annexb_number(c"var n = 0; function f() { n++; } try { f() = 1; } catch (e) {} try { f()++; } catch (e) {} n;", 2.0)
	# Other runtime errors from the call propagate unchanged.
	annexb_number(c"var r = 0; function f() { throw 5; } try { f() = 1; } catch (e) { r = e; } r;", 5.0)


int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1):
		malloc_force_debug_mode()
		annexb_number(c"function g() { { function h() { return 2; } } if (true) function c() { return 1; } return h() + c(); } g();", 3.0)
		assert_equal(0, debug_alloc_report_leaks())
		println(c"javascript_runtime_annexb_test: OK")
		return 0
	annexb_block_functions()
	annexb_clause_functions()
	annexb_labelled_functions()
	annexb_legacy_literals()
	annexb_call_targets()
	println(c"javascript_runtime_annexb_test: OK")
	return 0
