# wbuild: name=javascript_runtime_labels_test
# wbuild: target=javascript_runtime_labels_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 tests/javascript/runtime_labels_test.w -o bin/javascript_runtime_labels_test"
# wbuild: step="bin/javascript_runtime_labels_test" expect_stdout="javascript_runtime_labels_test: OK"
# wbuild: step="bin/javascript_runtime_labels_test memory" expect_stdout="javascript_runtime_labels_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime


void js_labels_number(char* source, float64 expected):
	js_runtime* rt = js_runtime_new()
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 10000)
	assert_equal(0, result.status)
	assert_equal(3, result.value.kind)
	assert1(result.value.number == expected)
	assert1(rt.label == 0)
	assert1(rt.jump_target == 0)
	js_runtime_free(rt)


void js_labels_invalid(char* source):
	pg_parse_result* parsed = js_parse_script(source, c"labels.js")
	assert_equal(0, parsed.success)
	pg_parse_result_free(parsed)


int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1):
		malloc_force_debug_mode()
		js_labels_number(c"let n = 0; a: b: for (const x of [1, 2, 3]) { try { n += x; continue a; } finally { n++; } } n;", 9.0)
		assert_equal(0, debug_alloc_report_leaks())
		println(c"javascript_runtime_labels_test: OK")
		return 0
	js_labels_number(c"outer: { 42; break outer; 9; }", 42.0)
	js_labels_number(c"42; outer: { break outer; }", 42.0)
	js_labels_number(c"a: b: { 42; break a; }", 42.0)
	js_labels_number(c"outer: { inner: { 40; break inner; } 42; break outer; }", 42.0)
	js_labels_number(c"outer: { while (true) { 42; break outer; } 9; }", 42.0)
	js_labels_number(c"let n = 0; outer: for (let i = 0; i < 3; i++) { for (;;) { n++; continue outer; } n += 100; } n;", 3.0)
	js_labels_number(c"let n = 0; a: b: while (n < 3) { n++; continue a; } n;", 3.0)
	js_labels_number(c"let n = 0; a: b: do { n++; continue b; } while (n < 3); n;", 3.0)
	js_labels_number(c"let n = 0; a: b: for (const x of [1, 2, 3]) { for (;;) { n += x; continue a; } } n;", 6.0)
	js_labels_number(c"let n = 0; outer: while (n < 3) { for (const x of [1, 2]) { n++; continue outer; } } n;", 3.0)
	js_labels_number(c"outer: for (const x of [1, 2]) { 42; break outer; }", 42.0)
	js_labels_number(c"outer: while (true) { while (true) { break; } 42; break outer; }", 42.0)
	js_labels_number(c"let n = 0; outer: while (n < 3) { n++; if (n < 3) continue; 42; }", 42.0)
	js_labels_number(c"a: { try { 42; break a; } finally { 9; } }", 42.0)
	js_labels_number(c"a: { b: { try { 9; break b; } finally { 42; break a; } } 8; }", 42.0)
	js_labels_number(c"let n = 0; let f = 0; a: while (n < 3) { try { n++; continue a; } finally { f++; } } n * 10 + f;", 33.0)
	js_labels_number(c"let n = 0; a: while (n < 3) { try { break a; } finally { n++; continue a; } } n;", 3.0)
	js_labels_number(c"function f() { a: { try { break a; } finally { return 42; } } return 9; } f();", 42.0)
	js_labels_number(c"a: { try { throw 9; } finally { 42; break a; } }", 42.0)
	js_labels_number(c"try { a: { try { break a; } finally { throw 42; } } } catch (e) { e; }", 42.0)
	js_labels_number(c"\\u0061: { 42; break a; }", 42.0)
	js_labels_number(c"a: { 42; break \\u0061; }", 42.0)
	js_labels_number(c"a: { var n = 42; break a; } n;", 42.0)
	js_labels_number(c"a: { function f() { a: { return 42; } } f(); }", 42.0)
	js_labels_number(c"'use strict'; eval: arguments: { 42; break eval; }", 42.0)
	js_labels_number(c"await: yield: let: { 42; break yield; }", 42.0)
	js_labels_invalid(c"'use strict'; yield: {}")
	js_labels_invalid(c"'use strict'; let: {}")
	js_labels_invalid(c"a: { a: {} }")
	js_labels_invalid(c"a: { \\u0061: {} }")
	js_labels_invalid(c"a: { continue a; }")
	js_labels_invalid(c"a: { while (true) { continue a; } }")
	js_labels_invalid(c"while (true) { break missing; }")
	js_labels_invalid(c"a: while (true) { function f() { break a; } }")
	js_labels_invalid(c"a: while (true) { const f = () => { continue a; }; }")
	js_runtime* rt = js_runtime_new()
	char* source = c"a: while (true) { continue a; }"
	assert_equal(5, js_runtime_eval(rt, source, strlen(source), 30).status)
	assert1(rt.label == 0)
	source = c"a: function f() {}"
	assert_equal(6, js_runtime_eval(rt, source, strlen(source), 100).status)
	source = c"try { missing; } catch (e) { e.name = 'TypeError'; throw e; }"
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 1000)
	assert_equal(2, result.status)
	assert_strings_equal(c"ReferenceError", result.value.intrinsic_error_name)
	source = c"throw {name: 'ReferenceError'};"
	result = js_runtime_eval(rt, source, strlen(source), 1000)
	assert_equal(2, result.status)
	assert_strings_equal(c"", result.value.intrinsic_error_name)
	js_runtime_free(rt)
	println(c"javascript_runtime_labels_test: OK")
	return 0
