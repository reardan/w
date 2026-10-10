# wbuild: name=javascript_parser_test
# wbuild: target=javascript_parser_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 tests/javascript/parser_test.w -o bin/javascript_parser_test"
# wbuild: step="bin/javascript_parser_test"
import lib.testing
import libs.extras.javascript.parser


pg_parse_result* js_expect_parse(char* source):
	pg_parse_result* result = js_parse(source, strlen(source), c"fixture.js", 1)
	if (result.success == 0):
		println2(source)
		pg_diagnostics_print(result.diagnostics)
	assert_equal(1, result.success)
	char* restored = pg_token_stream_source(result.stream)
	assert_strings_equal(source, restored)
	free(restored)
	return result


void js_accept(char* source):
	pg_parse_result_free(js_expect_parse(source))


void js_reject(char* source):
	pg_parse_result* result = js_parse(source, strlen(source), c"invalid.js", 1)
	if (result.success): println2(source)
	assert_equal(0, result.success)
	assert1(pg_diagnostics_count(result.diagnostics) > 0)
	pg_parse_result_free(result)


void test_js_contextual_regex_and_templates():
	js_accept(c"const ratio = a / b / c;")
	js_accept(c"const ok = /ab+c/i.test(s);")
	js_accept(c"if (ok) /x/.test(s); f(ok) / n;")
	js_accept(c"const t = `a${{x: `b${n}`}.x}c`;")
	js_accept(c"const t = `line\n${ /[a/]+/g.test(x) ? `yes` : `no` }`;")
	js_accept(c"const t = `//raw /*raw*/ ${f({a: 1})}`;")
	js_accept(c"({x: 1}) / n; {} /x/.test(s);")


void test_js_newline_sensitive_statements():
	js_accept(c"function f() { return\n/x/; }")
	js_accept(c"function f() { return /*\n*/ value; }")
	js_accept(c"function f() { return\r\nvalue; }")
	js_accept(c"function f() { return\xe2\x80\xa8value; }")
	js_accept(c"a\n++b;")
	js_accept(c"a = b\n/hi/g.exec(c);")
	js_accept(c"let x = 1\nlet y = 2\nx + y")
	js_reject(c"throw\nerror;")
	js_reject(c"throw /*\n*/ error;")
	js_reject(c"const f = (x)\n=> x;")
	js_reject(c"a b;")


void test_js_modern_syntax_shapes():
	js_accept(c"export function greet(name) { return \"Hello, \" + name; }")
	js_accept(c"import value, {old as renamed} from './old.js'; export {renamed};")
	js_accept(c"export * as ns from './old.js'; export {x as y} from './old.js';")
	js_accept(c"const f = (a, b = 2, ...rest) => ({value: a + b});")
	js_accept(c"const f = async x => await work(x);")
	js_accept(c"function* gen() { yield 1; yield* other(); }")
	js_accept(c"class Foo extends Base { constructor(x) { this.x = x; } static f() { return 1; } get x() { return 2; } }")
	js_accept(c"const {a: b = 1, ...rest} = obj; const [x,, y] = arr;")
	js_accept(c"for (const x of xs) { if (x) continue; } for (let i = 0; i < 3; i++) total += i;")
	js_accept(c"try { work(); } catch ({message}) { report(message); } finally { done(); }")
	js_accept(c"switch (x) { case 1: break; default: x = 2; }")
	js_accept(c"const x = obj?.items?.[0] ?? 42; fn?.(x);")
	js_accept(c"const x = 2 ** 3 ** 4; a = b = c;")
	js_accept(c"const x = new Foo(1).bar; const y = new Foo; const z = import('./module.js');")


void test_js_malformed_source():
	js_reject(c"const x = /unterminated;")
	js_reject(c"const x = `unterminated;")
	js_reject(c"const x = `a${{x: 1}`;")
	js_reject(c"/* unterminated")
	js_reject(c"const x = 0x;")
	js_reject(c"const x = /x/gg;")
	js_reject(c"const x = a ?? b || c;")
	js_reject(c"const x = a || b ?? c;")
	js_reject(c"let = ;")
