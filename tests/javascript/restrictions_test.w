# wbuild: name=javascript_restrictions_test
# wbuild: target=javascript_restrictions_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 tests/javascript/restrictions_test.w -o bin/javascript_restrictions_test"
# wbuild: step="bin/javascript_restrictions_test"
import lib.testing
import libs.extras.javascript.parser
import libs.extras.javascript.restrictions


void js_restriction_expect(char* source, int module, int expected):
	pg_parse_result* result = js_parse(source, strlen(source), c"restrictions.js", module)
	js_validate_restrictions(result, module)
	if (result.success != expected):
		println2(source)
		pg_diagnostics_print(result.diagnostics)
	assert_equal(expected, result.success)
	pg_parse_result_free(result)


void test_js_assignment_pattern_targets():
	js_restriction_expect(c"({a = 1} = obj);", 0, 1)
	js_restriction_expect(c"({a: {b = 1}} = obj);", 0, 1)
	js_restriction_expect(c"({a = {b = 1}} = obj);", 0, 0)
	js_restriction_expect(c"const obj = {a = 1};", 0, 0)
	js_restriction_expect(c"f({a = 1});", 0, 0)
	js_restriction_expect(c"[a, {b: c}, ...rest] = xs;", 0, 1)
	js_restriction_expect(c"[a = 1, ...[b]] = xs;", 0, 1)
	js_restriction_expect(c"({a: obj.x, ...other.x} = xs);", 0, 1)
	js_restriction_expect(c"[1] = xs;", 0, 0)
	js_restriction_expect(c"[f()] = xs;", 0, 0)
	js_restriction_expect(c"[a + b] = xs;", 0, 0)
	js_restriction_expect(c"[a += 1] = xs;", 0, 0)
	js_restriction_expect(c"[...a, b] = xs;", 0, 0)
	js_restriction_expect(c"[...a,] = xs;", 0, 0)
	js_restriction_expect(c"[...a = 1] = xs;", 0, 0)
	js_restriction_expect(c"({a: 1} = xs);", 0, 0)
	js_restriction_expect(c"({m(){}} = xs);", 0, 0)
	js_restriction_expect(c"({...{a}} = xs);", 0, 0)
	js_restriction_expect(c"({...a, b} = xs);", 0, 0)
	js_restriction_expect(c"({...a,} = xs);", 0, 0)


void test_js_loop_target_constraints():
	js_restriction_expect(c"for ({a} of xs) {}", 0, 1)
	js_restriction_expect(c"for ([a] in xs) {}", 0, 1)
	js_restriction_expect(c"for (obj.x of xs) {}", 0, 1)
	js_restriction_expect(c"for (f() of xs) {}", 0, 0)
	js_restriction_expect(c"for (1 in xs) {}", 0, 0)
	js_restriction_expect(c"for (async of xs) {}", 0, 0)
	js_restriction_expect(c"for await (x of xs) {}", 0, 0)
	js_restriction_expect(c"async function f(){ for await (x of xs) {} }", 0, 1)
	js_restriction_expect(c"async function f(){ for await (x in xs) {} }", 0, 0)
	js_restriction_expect(c"async function f(){ for await (;;){ } }", 0, 0)


void test_js_super_contexts():
	js_restriction_expect(c"super.x;", 0, 0)
	js_restriction_expect(c"function f(){ super.x; }", 0, 0)
	js_restriction_expect(c"class A { m(){ super.x; } }", 0, 1)
	js_restriction_expect(c"const o = {m(){ super.x; }};", 0, 1)
	js_restriction_expect(c"class A extends B { constructor(){ super(); } }", 0, 1)
	js_restriction_expect(c"class A extends B { constructor(x=super()){} }", 0, 1)
	js_restriction_expect(c"class A extends B { constructor(){ (()=>super())(); } }", 0, 1)
	js_restriction_expect(c"class A { constructor(){ super(); } }", 0, 0)
	js_restriction_expect(c"class A extends B { m(){ super(); } }", 0, 0)
	js_restriction_expect(c"class A extends B { constructor(){ function f(){ super(); } } }", 0, 0)
	js_restriction_expect(c"class A { m(){ super; } }", 0, 0)
	js_restriction_expect(c"class A { m(){ super?.x; } }", 0, 0)
	js_restriction_expect(c"class A { m(){ new super(); } }", 0, 0)
	js_restriction_expect(c"class A { m(){ new super.x(); } }", 0, 1)
	js_restriction_expect(c"class A { m(){ (()=>super.x)(); } }", 0, 1)
	js_restriction_expect(c"const o = {m(){ return {super: 1}; }};", 0, 1)


void test_js_strict_assignment_restrictions():
	js_restriction_expect(c"((eval)) = 1;", 1, 0)
	js_restriction_expect(c"delete ((x));", 1, 0)
	js_restriction_expect(c"eval = 1;", 0, 1)
	js_restriction_expect(c"eval = 1;", 1, 0)
	js_restriction_expect(c"[arguments] = xs;", 1, 0)
	js_restriction_expect(c"eval++;", 1, 0)
	js_restriction_expect(c"++arguments;", 1, 0)
	js_restriction_expect(c"delete x;", 1, 0)
	js_restriction_expect(c"delete obj.x;", 1, 1)
	js_restriction_expect(c"for (eval of xs) {}", 1, 0)


void test_js_statement_contexts():
	js_restriction_expect(c"switch(x){default:; default:;}", 0, 0)
	js_restriction_expect(c"label: label: while(x){}", 0, 0)
	js_restriction_expect(c"a: while(x){ b: while(y){ break a; } }", 0, 1)
	js_restriction_expect(c"if(x) let y = 1;", 0, 0)
	js_restriction_expect(c"for(;;) const y = 1;", 0, 0)
	js_restriction_expect(c"a: class C {}", 0, 0)
	js_restriction_expect(c"while(x) function f(){}", 0, 0)
	js_restriction_expect(c"if(x) function f(){}", 1, 0)
	js_restriction_expect(c"if(x) var y = 1;", 0, 1)
