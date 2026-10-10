# wbuild: name=javascript_roundtrip_test
# wbuild: target=javascript_roundtrip_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 tests/javascript/roundtrip_test.w -o bin/javascript_roundtrip_test"
# wbuild: step="bin/javascript_roundtrip_test" expect_stdout="javascript_roundtrip_test: OK"
# wbuild: step="bin/javascript_roundtrip_test memory" expect_stdout="javascript_roundtrip_test: OK"
# wbuild: target=javascript_roundtrip_64_test tag=tests_x64 dep=javascript_parser
# wbuild: step="bin/wv2 x64 tests/javascript/roundtrip_test.w -o bin/javascript_roundtrip_64_test"
# wbuild: step="bin/javascript_roundtrip_64_test" expect_stdout="javascript_roundtrip_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.parser
import libs.extras.javascript.lower
import libs.extras.javascript.printer


void js_test_roundtrip(char* source, int module):
	pg_parse_result* parsed = js_parse(source, strlen(source), c"roundtrip.js", module)
	if (parsed.success == 0): pg_diagnostics_print(parsed.diagnostics)
	assert1(parsed.success)
	js_node* tree = js_lower(parsed)
	if (tree == 0): pg_diagnostics_print(parsed.diagnostics)
	assert1(tree != 0)
	assert_equal(0, tree.offset)
	char* printed = js_print(tree, parsed.diagnostics)
	if (printed == 0): pg_diagnostics_print(parsed.diagnostics)
	assert1(printed != 0)
	pg_parse_result* reparsed = js_parse(printed, strlen(printed), c"printed.js", module)
	if (reparsed.success == 0):
		println2(printed)
		pg_diagnostics_print(reparsed.diagnostics)
	assert1(reparsed.success)
	js_node* other = js_lower(reparsed)
	assert1(other != 0)
	assert1(js_node_equal(tree, other))
	js_node_free(tree)
	js_node_free(other)
	free(printed)
	pg_parse_result_free(parsed)
	pg_parse_result_free(reparsed)


void js_test_association():
	pg_parse_result* parsed = js_parse_script(c"a - b - c; a ** b ** c; a = b = c;", c"association.js")
	assert1(parsed.success)
	js_node* program = js_lower(parsed)
	assert1(program != 0)
	js_node* subtract = program.children[0].children[0]
	assert_strings_equal(c"-", subtract.text)
	assert_strings_equal(c"-", subtract.children[0].text)
	assert_strings_equal(c"c", subtract.children[1].text)
	js_node* power = program.children[1].children[0]
	assert_strings_equal(c"**", power.text)
	assert_strings_equal(c"a", power.children[0].text)
	assert_strings_equal(c"**", power.children[1].text)
	js_node* assignment = program.children[2].children[0]
	assert_strings_equal(c"assignment", assignment.kind)
	assert_strings_equal(c"assignment", assignment.children[1].kind)
	assert_equal(0, subtract.offset)
	assert_equal(9, subtract.length)
	assert_equal(0, subtract.children[0].offset)
	assert_equal(5, subtract.children[0].length)
	js_node_free(program)
	pg_parse_result_free(parsed)


void js_test_lower_reject():
	pg_parse_result* parsed = js_parse_script(c"class A {}", c"unsupported.js")
	assert1(parsed.success)
	assert1(js_lower(parsed) == 0)
	assert_equal(1, pg_diagnostics_count(parsed.diagnostics))
	assert1(parsed.success == 0)
	pg_parse_result_free(parsed)



void js_test_new_spans_and_limits():
	char* source = c"while (ok) value++;"
	pg_parse_result* parsed = js_parse_script(source, c"spans.js")
	js_node* tree = js_lower(parsed)
	assert1(tree != 0)
	js_node* loop = tree.children[0]
	assert_strings_equal(c"while", loop.kind)
	assert_equal(0, loop.offset)
	assert_equal(strlen(source), loop.length)
	assert_equal(7, loop.children[0].offset)
	assert_equal(2, loop.children[0].length)
	assert_equal(11, loop.children[1].children[0].offset)
	assert_equal(7, loop.children[1].children[0].length)
	js_node_free(tree)
	pg_parse_result_free(parsed)
	js_parse_limits* limits = js_parse_limits_new()
	limits.tokens = 2
	parsed = js_parse_with_limits(source, strlen(source), c"limited.js", 0, limits)
	assert_equal(0, parsed.success)
	assert1(parsed.stream.resource_failed)
	pg_parse_result_free(parsed)
	limits.tokens = 1000000
	limits.ast_nodes = 1
	parsed = js_parse_with_limits(source, strlen(source), c"limited.js", 0, limits)
	assert_equal(0, parsed.success)
	assert1(parsed.stream.resource_failed)
	pg_parse_result_free(parsed)
	limits.ast_nodes = 1000000
	limits.checkpoints = 1
	parsed = js_parse_with_limits(source, strlen(source), c"limited.js", 0, limits)
	assert_equal(0, parsed.success)
	assert1(parsed.stream.resource_failed)
	pg_parse_result_free(parsed)
	limits.checkpoints = 0
	parsed = js_parse_with_limits(source, strlen(source), c"invalid.js", 0, limits)
	assert_equal(0, parsed.success)
	pg_parse_result_free(parsed)
	parsed = js_parse_with_limits(0, 3, c"invalid.js", 0, 0)
	assert_equal(0, parsed.success)
	pg_parse_result_free(parsed)
	parsed = js_parse_with_limits(source, -1, c"invalid.js", 0, 0)
	assert_equal(0, parsed.success)
	pg_parse_result_free(parsed)
	parsed = js_parse_with_limits(0, 0, 0, 0, 0)
	assert1(parsed.success)
	pg_parse_result_free(parsed)
	free(limits)


int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1):
		malloc_force_debug_mode()
		js_test_roundtrip(c"export function greet(name) { return \"Hello, \" + name; }", 1)
		js_test_roundtrip(c"const f = x => `${x}`; for (const x of [1, 2]) f(x);", 0)
		assert_equal(0, debug_alloc_report_leaks())
		println(c"javascript_roundtrip_test: OK")
		return 0
	js_test_roundtrip(c"export function greet(name) { return \"Hello, \" + name; }", 1)
	js_test_roundtrip(c"const x = 2 + 3 * 4; const ratio = a / b / c; const ok = /ab+c/i.test(s);", 0)
	js_test_roundtrip(c"const t = `a${{x: `b${n}`}.x}c`;", 0)
	js_test_roundtrip(c"function f() { return\n/x/; }", 0)
	js_test_roundtrip(c"if (ok) /x/.test(s); else value = cond ? a : b;", 0)
	js_test_roundtrip(c"a++; --b; a[b + c](d, e); const values = [1, 'two', true, null];", 0)
	js_test_roundtrip(c"import x from './old.js'; import './side.js'; export const name = 'a\\n\\\"b';", 1)
	js_test_roundtrip(c"const o = {x: 1, y}; a, b, c;", 0)
	js_test_roundtrip(c"const escaped = `\\` \\${literal} \\\\`; obj.return;", 0)
	js_test_roundtrip(c"const o = {__proto__}; function relaxed(a, a) { \"use\\x20strict\"; return a; }", 0)
	js_test_roundtrip(c"for (let i = 0; i < 4; i++) { if (i === 2) continue; a += i; } while (a) { a--; break; } do a++; while (a < 4); for (;;) break;", 0)
	js_test_roundtrip(c"const f = function(x) { return function named(y) { return x + y; }; };", 0)
	js_test_roundtrip(c"const nul = '\\0'; const high = '\\ud800'; const low = '\\udfff'; const pair = '\\ud83d\\ude00';", 0)
	js_test_roundtrip(c"try { throw 1; } catch (e) { value = e; } finally { done(); } try {} catch {} try {} finally {}", 0)
	js_test_roundtrip(c"const identity = '\\é';", 0)
	js_test_roundtrip(c"const f = x => y => x + y; const g = () => ({ok: true}); const h = (a, b) => { return a + b; };", 0)
	js_test_roundtrip(c"for (const item of items) { use(item); } for (let ch of text) ch = ch;", 0)
	js_test_roundtrip(c"if (ok) for (const x of items) { if (x) use(x); } else done();", 0)
	js_test_new_spans_and_limits()
	js_test_association()
	js_test_lower_reject()
	println(c"javascript_roundtrip_test: OK")
	return 0
