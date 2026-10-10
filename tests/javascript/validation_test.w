# wbuild: name=javascript_validation_test
# wbuild: target=javascript_validation_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 tests/javascript/validation_test.w -o bin/javascript_validation_test"
# wbuild: step="bin/javascript_validation_test"
import lib.testing
import libs.extras.javascript.parser


void js_validation_expect(char* source, int module, int success):
	pg_parse_result* result = js_parse(source, strlen(source), c"validation.js", module)
	if (result.success != success):
		println2(source)
		pg_diagnostics_print(result.diagnostics)
	assert_equal(success, result.success)
	pg_parse_result_free(result)


void test_js_module_and_function_contexts():
	js_validation_expect(c"export const x = 1;", 1, 1)
	js_validation_expect(c"export const x = 1;", 0, 0)
	js_validation_expect(c"if (true) { import 'x'; }", 1, 0)
	js_validation_expect(c"return 1;", 0, 0)
	js_validation_expect(c"function f() { return 1; }", 0, 1)
	js_validation_expect(c"yield 1;", 0, 0)
	js_validation_expect(c"function* f() { yield 1; }", 0, 1)
	js_validation_expect(c"await f();", 1, 0)
	js_validation_expect(c"async function f() { await g(); }", 0, 1)
	js_validation_expect(c"async function f() { function g() { await h(); } }", 0, 0)


void test_js_assignment_and_exponentiation_contexts():
	js_validation_expect(c"function f() { return new.target?.a; }", 0, 1)
	js_validation_expect(c"new.target;", 0, 0)
	js_validation_expect(c"() => new.target;", 0, 0)
	js_validation_expect(c"a?.3:0;", 0, 1)
	js_validation_expect(c"`\\u0`;", 0, 0)
	js_validation_expect(c"tag`\\u0`;", 0, 1)
	js_validation_expect(c"1 = x;", 0, 0)
	js_validation_expect(c"f()++;", 0, 0)
	js_validation_expect(c"++(x + y);", 0, 0)
	js_validation_expect(c"obj?.x = 1;", 0, 0)
	js_validation_expect(c"obj.x += 1; obj[x]++;", 0, 1)
	js_validation_expect(c"-2 ** 2;", 0, 0)
	js_validation_expect(c"(-2) ** 2;", 0, 1)
	js_validation_expect(c"const x;", 0, 0)
	js_validation_expect(c"let {x};", 0, 0)
	js_validation_expect(c"for (const x of xs) f(x);", 0, 1)


void test_js_strict_directives_and_identifiers():
	js_validation_expect(c"with (x) y;", 0, 1)
	js_validation_expect(c"'use strict'; with (x) y;", 0, 0)
	js_validation_expect(c"with (x) y;", 1, 0)
	js_validation_expect(c"function f() { 'use strict'; var eval; }", 0, 0)
	js_validation_expect(c"let \\u0069f = 1;", 0, 0)
	js_validation_expect(c"const obj = {\\u0069f: 1};", 0, 1)
	js_validation_expect(c"'use strict'; 010;", 0, 0)
	js_validation_expect(c"'use strict'; '\\1';", 0, 0)
	js_validation_expect(c"'use strict'; '\\0';", 0, 1)


void test_js_break_continue_contexts():
	js_validation_expect(c"break;", 0, 0)
	js_validation_expect(c"continue;", 0, 0)
	js_validation_expect(c"while (x) { break; continue; }", 0, 1)
	js_validation_expect(c"while (x) { function f() { break; } }", 0, 0)
	js_validation_expect(c"outer: while (x) { continue outer; }", 0, 1)
	js_validation_expect(c"outer: { break outer; }", 0, 1)
	js_validation_expect(c"outer: { continue outer; }", 0, 0)
