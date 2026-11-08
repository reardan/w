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
import lib.str


# Every node kind produced by js_lower must be reached by a roundtrip case.
char* js_test_kinds = c"program block empty expression_statement return throw variable declarator function function_expression async_function async_function_expression generator_function generator_function_expression async_generator_function async_generator_function_expression arrow async_arrow parameters identifier string string_utf16 string_non_directive number bigint regex literal super new_target import_meta import_call template template_text tagged_template binary assignment unary await yield update_prefix update_postfix conditional call construct member computed_member optional_chain optional_member optional_computed_member optional_call spread array object property property_shorthand computed_property method static_method property_key computed_key class class_expression object_pattern array_pattern pattern_property computed_pattern_property default_pattern rest if while do_while for for_in for_of for_await_of switch case default with debugger label break continue try catch import import_named import_namespace import_specifier export export_default export_named export_from export_all export_specifier"
set[char*] js_test_seen


void js_test_visit(js_node* node):
	js_test_seen.add(strclone(node.kind))


void js_test_roundtrip(char* source, int module):
	pg_parse_result* parsed = js_parse(source, strlen(source), c"roundtrip.js", module)
	if (parsed.success == 0):
		println2(source)
		pg_diagnostics_print(parsed.diagnostics)
	assert1(parsed.success)
	js_node* tree = js_lower(parsed)
	if (tree == 0):
		println2(source)
		pg_diagnostics_print(parsed.diagnostics)
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
	if (js_node_equal(tree, other) == 0): println2(printed)
	assert1(js_node_equal(tree, other))
	if (js_test_seen != 0): js_node_walk(tree, js_test_visit)
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
	# Lowering still diagnoses CST shapes it does not model; constructed
	# nodes with invalid shapes are rejected by the printer.
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	js_node* invalid = js_node_new(c"method", c"get")
	js_node_add(invalid, js_node_new(c"property_key", c"x"))
	js_node* getter = js_node_new(c"function_expression", c"")
	js_node* parameters = js_node_new(c"parameters", c"")
	js_node_add(parameters, js_identifier(c"a"))
	js_node_add(getter, parameters)
	js_node_add(getter, js_node_new(c"block", c""))
	js_node_add(invalid, getter)
	js_node* object = js_node_new(c"object", c"")
	js_node_add(object, invalid)
	js_node* statement = js_node_new(c"expression_statement", c"")
	js_node_add(statement, object)
	assert1(js_print(statement, diagnostics) == 0)
	assert_equal(1, pg_diagnostics_count(diagnostics))
	js_node_free(statement)
	js_node* chain = js_node_new(c"optional_member", c"")
	js_node_add(chain, js_identifier(c"a"))
	js_node_add(chain, js_identifier(c"b"))
	statement = js_node_new(c"expression_statement", c"")
	js_node_add(statement, chain)
	assert1(js_print(statement, diagnostics) == 0)
	js_node_free(statement)
	js_node* anonymous = js_node_new(c"class", c"")
	js_node_add(anonymous, js_node_new(c"empty", c""))
	assert1(js_print(anonymous, diagnostics) == 0)
	js_node_free(anonymous)
	pg_diagnostics_free(diagnostics)


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
	if (argc <= 1): js_test_seen = new set[char*]
	if (argc > 1): malloc_force_debug_mode()
	js_test_roundtrip(c"new Promise((resolve, reject) => { resolve(3); }).then(value => value); new A.B(1); new A[method](); new new A();", 0)
	if (argc > 1):
		malloc_force_debug_mode()
		js_test_roundtrip(c"export function greet(name) { return \"Hello, \" + name; }", 1)
		js_test_roundtrip(c"const f = x => `${x}`; for (const x of [1, 2]) f(x);", 0)
		js_test_roundtrip(c"class A extends B { static async *[k](x = 1, ...r) { yield* super.m`t`; } get v() { return {[k]: 1, get g() {}, ...o}; } } switch (a?.b?.(c)) { case 1: for (var [p] in q); default: with (o) debugger; } try {} catch ({e}) {}", 0)
		js_test_roundtrip(c"import d, * as n from 'm'; export {d as e}; export * as f from 'g'; export default async function () {}", 1)
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
	js_test_roundtrip(c"outer: inner: for (let i=0; i<3; i++) { if(i) continue outer; break inner; } done: ;", 0)
	js_test_roundtrip(c"out\\u0065r: { 42; break outer; }", 0)
	js_test_roundtrip(c"let: { break let; } static: { break static; } implements: { break implements; }", 0)
	js_test_roundtrip(c"await: { break await; } yield: { break yield; }", 0)
	js_test_roundtrip(c"\\u0061wait: { break await; } y\\u0069eld: { break yield; }", 0)
	js_test_roundtrip(c"\"use strict\"; eval: { break eval; } arguments: { break arguments; }", 0)
	js_test_roundtrip(c"a: b: for (;;) { if (ok) continue a; else break b; }", 0)
	js_test_roundtrip(c"outer: { inner: { break outer; } }", 0)
	js_test_roundtrip(c"\\u0061: while (ok) { continue \\u0061; }", 0)
	js_test_roundtrip(c"if (ok) a: { if (other) use(); } else done();", 0)
	js_test_roundtrip(c"'use strict'; eval: arguments: { break arguments; }", 0)
	js_test_roundtrip(c"await: yield: let: { break yield; }", 0)
	js_test_roundtrip(c"\"use strict\"; 'x'; 'use\\x20strict'; const big = 12n; let d = [a, , ...b, ,]; function nt() { if (!new.target) throw new.target; return new.target; }", 0)
	js_test_roundtrip(c"class A extends B.C { constructor(a, ...b) { super(a); new.target; } static async *[key](x = 1) { yield; yield x; yield* y; await z; } get value() { return super.value; } set value(v) {} static get [k]() {} 'quoted'() {} 1() {} async m() {} *gen() {} ; }", 0)
	js_test_roundtrip(c"const K = class {}; const N = class Named extends (f()) { m() { return (class {}); } };", 0)
	js_test_roundtrip(c"async function f(a, {b, c: [d = 2, e]}, [g1, ...g2], ...rest) { await g(); for await (const x of xs) use(x); return async () => await h(); } const af = async function() {}; const ab = async x => x;", 0)
	js_test_roundtrip(c"function* g() { const x = yield 1; } const ge = function* named() {}; async function* ag() { yield await 1; } const age = async function*() {};", 0)
	js_test_roundtrip(c"const o = {[k]: 1, [a + b]() {}, 2: 'two', 0x10: x, 'a\\0': 1, get g() { return 1; }, set s(v) {}, async am() {}, *gm() {}, async *agm() {}, get [c]() {}, ...rest, short};", 0)
	js_test_roundtrip(c"const {a, b: {c}, [k]: v, 1: one, 'q': w = 3, ...more} = obj; const {n: [n1]} = obj; let [x, , [y], z = 4, ...others] = list; var [, hole,] = h;", 0)
	js_test_roundtrip(c"[a, b] = [b, a]; ({x, y: [z], w = 1, [k]: q, ...r} = obj); [o.p, q[0] = 1, ...s] = t;", 0)
	js_test_roundtrip(c"for (var k in o) use(k); for (const [k, v] of entries) use(k, v); for (x of xs); for (o.p in q); for ([a, b] of pairs); for (var {length} of strings); for (let i in arr) {}", 0)
	# Annex B.3.6 for-in initializers; the printer parenthesizes the [~In] value.
	js_test_roundtrip(c"for (var k = 1 in o) use(k); for (var j = (a in b) in o); for (var i = a ? b in c : d in o); for (var h = () => a in b);", 0)
	js_test_roundtrip(c"switch (x) { case 1: case 2: a(); break; default: b(); case 3: { c(); } } switch (y) {}", 0)
	js_test_roundtrip(c"with (o) { p(); } debugger; try { f(); } catch ({message}) { use(message); } try {} catch ([first]) {}", 0)
	js_test_roundtrip(c"a?.b; a?.[0]?.(1).c; a.b?.c.d(e)[f]; (a?.b).c; (a?.b)(); new (f())(); new A; tag`x${1}y`; a.b`\\unicode`; f()`t`; import('./m.js').then(m => m);", 0)
	js_test_roundtrip(c"f(...args, last); new F(...list); [...xs]; x instanceof Y; 'k' in o; a ** b; a % b; a == b; a != b; delete o.p; void 0; -x; +x; ~x; !x; typeof x; x **= 2; x %= 3;", 0)
	js_test_roundtrip(c"import def, {a as b, c, default as d} from './m.js'; import * as ns from 'n'; import def2, * as ns2 from 'n2'; import {} from 'e'; export {b as e, c}; export {x as default, y} from './y.js'; export * from 'all'; export * as named from 'ns'; export class C {} export async function af() {} export function* gf() {} export let l = 1, m;", 1)
	js_test_roundtrip(c"export default function () {}", 1)
	js_test_roundtrip(c"export default function named() {} import.meta;", 1)
	js_test_roundtrip(c"export default class {}", 1)
	js_test_roundtrip(c"export default class Named extends Base {}", 1)
	js_test_roundtrip(c"export default async function* () { await 0; }", 1)
	js_test_roundtrip(c"export default (function () {});", 1)
	js_test_roundtrip(c"export default 1 + 2;", 1)
	js_test_roundtrip(c"/ab+c/u.test(s); x = [null, true, false, this]; if (a) for (const k in o) if (k) use(k); else other(); if (b) with (o) if (c) d(); else e();", 0)
	for char* kind in split(js_test_kinds):
		if ((kind in js_test_seen) == 0): println2(kind)
		assert1(kind in js_test_seen)
	js_test_new_spans_and_limits()
	js_test_association()
	js_test_lower_reject()
	println(c"javascript_roundtrip_test: OK")
	return 0
