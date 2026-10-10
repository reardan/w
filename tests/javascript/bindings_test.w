# wbuild: name=javascript_bindings_test
# wbuild: target=javascript_bindings_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 tests/javascript/bindings_test.w -o bin/javascript_bindings_test"
# wbuild: step="bin/javascript_bindings_test"
import lib.testing
import libs.extras.javascript.parser
import libs.extras.javascript.bindings


void js_binding_expect(char* source, int module, int expected):
	pg_parse_result* result = js_parse(source, strlen(source), c"bindings.js", module)
	js_validate_bindings(result, module)
	if (result.success != expected):
		println2(source)
		pg_diagnostics_print(result.diagnostics)
	assert_equal(expected, result.success)
	pg_parse_result_free(result)


void test_js_duplicate_lexical_bindings():
	js_binding_expect(c"let a; let a;", 0, 0)
	js_binding_expect(c"var a; let a;", 0, 0)
	js_binding_expect(c"let a; var a;", 0, 0)
	js_binding_expect(c"{ var a; } let a;", 0, 0)
	js_binding_expect(c"let a; { var a; }", 0, 0)
	js_binding_expect(c"const {a, a} = value;", 0, 0)
	js_binding_expect(c"let \\u0061; const a = 1;", 0, 0)
	js_binding_expect(c"function f(a) { let a; }", 0, 0)
	js_binding_expect(c"class A {} let A;", 0, 0)
	js_binding_expect(c"import a from 'x'; const a = 1;", 1, 0)
	js_binding_expect(c"function f() {} function f() {}", 1, 0)
	js_binding_expect(c"for (let a of values) { var a; }", 0, 0)
	js_binding_expect(c"try {} catch ({x, x}) {}", 0, 0)
	js_binding_expect(c"try {} catch (x) { let x; }", 0, 0)


void test_js_valid_binding_shadowing():
	js_binding_expect(c"try {} catch (e) { var e; }", 0, 1)
	js_binding_expect(c"try {} catch ({e}) { var e; }", 0, 0)
	js_binding_expect(c"let e; try {} catch (e) { var e; }", 0, 0)
	js_binding_expect(c"export default function f() {} const f = 1;", 1, 0)
	js_binding_expect(c"export default class C {} const C = 1;", 1, 0)
	js_binding_expect(c"var a; var a;", 0, 1)
	js_binding_expect(c"let a; { let a; }", 0, 1)
	js_binding_expect(c"var a; { let a; }", 0, 1)
	js_binding_expect(c"{ let a; } var a;", 0, 1)
	js_binding_expect(c"let a; function f() { var a; }", 0, 1)
	js_binding_expect(c"function f(a) { var a; { let a; } }", 0, 1)
	js_binding_expect(c"function f() {} function f() {}", 0, 1)
	js_binding_expect(c"for (let x of xs) {} let x;", 0, 1)
	js_binding_expect(c"const {a: x, b: y} = value;", 0, 1)


void test_js_parameter_early_errors():
	js_binding_expect(c"function f(a, a) {}", 0, 1)
	js_binding_expect(c"function f(a, a) {'use strict';}", 0, 0)
	js_binding_expect(c"function f(a, a) {}", 1, 0)
	js_binding_expect(c"function f(a, a = 1) {}", 0, 0)
	js_binding_expect(c"function f({a}, a) {}", 0, 0)
	js_binding_expect(c"const f = (a, a) => a;", 0, 0)
	js_binding_expect(c"const o = {f(a, a) {}};", 0, 0)
	js_binding_expect(c"function f(a = 1) {'use strict';}", 0, 0)
	js_binding_expect(c"const f = (a = 1) => {'use strict';};", 0, 0)
	js_binding_expect(c"function f(a, ...rest, b) {}", 0, 0)
	js_binding_expect(c"function f(a, ...rest,) {}", 0, 0)
	js_binding_expect(c"function f(a, ...rest) {}", 0, 1)
	js_binding_expect(c"function f({a}, [b], c = 1) {}", 0, 1)


void test_js_rest_binding_constraints():
	js_binding_expect(c"const {a, ...rest, b} = obj;", 0, 0)
	js_binding_expect(c"const {a, ...rest,} = obj;", 0, 0)
	js_binding_expect(c"const {...{a}} = obj;", 0, 0)
	js_binding_expect(c"const {...rest} = obj;", 0, 1)
	js_binding_expect(c"const [a, ...[b]] = arr;", 0, 1)


void test_js_class_constructor_constraints():
	js_binding_expect(c"class A { constructor() {} constructor(x) {} }", 0, 0)
	js_binding_expect(c"class A { async constructor() {} }", 0, 0)
	js_binding_expect(c"class A { *constructor() {} }", 0, 0)
	js_binding_expect(c"class A { get constructor() {} }", 0, 0)
	js_binding_expect(c"class A { set constructor(x) {} }", 0, 0)
	js_binding_expect(c"class A { static prototype() {} }", 0, 0)
	js_binding_expect(c"class A { constructor() {} 'constr\\u0075ctor'() {} }", 0, 0)
	js_binding_expect(c"class A { constructor() {} static constructor() {} }", 0, 1)
	js_binding_expect(c"class A { ['constructor']() {} constructor() {} }", 0, 1)
	js_binding_expect(c"class A { get value() {} set value(x) {} }", 0, 1)
	js_binding_expect(c"class A { get value(x) {} }", 0, 0)
	js_binding_expect(c"class A { set value() {} }", 0, 0)
