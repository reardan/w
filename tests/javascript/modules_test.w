# wbuild: name=javascript_modules_test
# wbuild: target=javascript_modules_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 tests/javascript/modules_test.w -o bin/javascript_modules_test"
# wbuild: step="bin/javascript_modules_test" expect_stdout="javascript_modules_test: OK"
import lib.assert
import libs.extras.javascript.modules

struct module_fixture:
	list[js_module_source*] sources
	js_module_source borrowed
	int calls
	int reentrant
	js_modules* modules

module_fixture* module_fixture_new():
	module_fixture* fixture = new module_fixture()
	fixture.sources = new list[js_module_source*]
	return fixture

void module_fixture_add(module_fixture* fixture, char* name, char* source):
	js_module_source* entry = new js_module_source()
	entry.identifier = name
	entry.source = source
	entry.length = strlen(source)
	fixture.sources.push(entry)

js_module_source* module_resolve(void* context, char* name, char* referrer):
	module_fixture* fixture = cast(module_fixture*, context)
	fixture.calls = fixture.calls + 1
	asserts(c"referrer supplied", referrer != 0)
	if (fixture.reentrant):
		asserts(c"resolver cannot reenter evaluation", js_modules_evaluate(fixture.modules, name, referrer, 100) == 0)
		assert_equal(-1, js_runtime_collect(fixture.modules.runtime))
	if (strcmp(name, c"alias") == 0): name = c"dep"
	for i in range(fixture.sources.length):
		js_module_source* entry = fixture.sources[i]
		if (strcmp(entry.identifier, name) == 0):
			# Reuse one resolver record to exercise borrowed-result lifetime.
			fixture.borrowed.identifier = entry.identifier
			fixture.borrowed.source = entry.source
			fixture.borrowed.length = entry.length
			return &fixture.borrowed
	return 0

void module_fixture_free(module_fixture* fixture):
	for i in range(fixture.sources.length): free(fixture.sources[i])
	__w_list_free(cast(__w_list*, fixture.sources))
	free(fixture)

void test_modules_graph():
	module_fixture* fixture = module_fixture_new()
	module_fixture_add(fixture, c"dep", c"counter.n += 1; let privateValue = 40; export const box = {n:1}; export const inc = () => { privateValue += 1; return privateValue; }; export const answer = 40;")
	module_fixture_add(fixture, c"left", c"import {answer as a, box} from 'dep'; export const left = a + 1; export {box};")
	module_fixture_add(fixture, c"right", c"import {answer} from 'alias'; export const right = answer + 2;")
	module_fixture_add(fixture, c"root", c"import {left, box} from 'left'; import {right} from 'right'; import {inc} from 'dep'; export {inc as next}; export const result = left + right; box.n += 2; export const object = box; export const topThis = this; const hidden = 9;")
	js_runtime* rt = js_runtime_new()
	char* setup = c"const counter = {n:0};"
	assert_equal(0, js_runtime_eval(rt, setup, strlen(setup), 100).status)
	js_modules* modules = js_modules_new(rt, module_resolve, fixture)
	fixture.modules = modules
	fixture.reentrant = 1
	js_module* root = js_modules_evaluate(modules, c"root", c"", 10000)
	asserts(c"graph evaluated", root != 0)
	assert_equal(0, rt.completion.status)
	assert_equal(4, modules.entries.length)
	assert1(js_modules_export(modules, root, c"result").number == 83.0)
	assert_equal(0, js_modules_export(modules, root, c"topThis").kind)
	asserts(c"private names not exported", js_modules_export(modules, root, c"hidden") == 0)
	js_module* dep = js_modules_evaluate(modules, c"dep", c"root", 1000)
	asserts(c"object export identity", js_modules_export(modules, dep, c"box") == js_modules_export(modules, root, c"object"))
	asserts(c"cache returns same record", js_modules_evaluate(modules, c"root", c"", 1000) == root)
	js_runtime_collect(rt)
	assert_equal(0, js_runtime_eval(rt, c"counter.n;", 10, 100).status)
	assert1(rt.completion.value.number == 1.0)
	asserts(c"module lexical does not leak globally", js_runtime_binding(rt.global, c"hidden") == 0)
	asserts(c"dependency lexical does not leak globally", js_runtime_binding(rt.global, c"privateValue") == 0)
	js_value* next = js_modules_export(modules, root, c"next")
	js_runtime_root(rt, next)
	js_modules_free(modules)
	js_runtime_collect(rt)
	list[js_value*] args = new list[js_value*]
	assert_equal(0, js_runtime_invoke(rt, next, args, 1000).status)
	assert1(rt.completion.value.number == 41.0)
	assert_equal(0, js_runtime_invoke(rt, next, args, 1000).status)
	assert1(rt.completion.value.number == 42.0)
	__w_list_free(cast(__w_list*, args))
	js_runtime_unroot(rt, next)
	js_runtime_free(rt)
	module_fixture_free(fixture)

void module_reject(char* source, int status):
	module_fixture* fixture = module_fixture_new()
	module_fixture_add(fixture, c"root", source)
	module_fixture_add(fixture, c"dep", c"counter.n += 1; export const x = 1;")
	js_runtime* rt = js_runtime_new()
	char* setup = c"const counter = {n:0};"
	assert_equal(0, js_runtime_eval(rt, setup, strlen(setup), 100).status)
	js_modules* modules = js_modules_new(rt, module_resolve, fixture)
	asserts(c"module rejected", js_modules_evaluate(modules, c"root", c"", 10000) == 0)
	assert_equal(status, rt.completion.status)
	asserts(c"failure has diagnostic", rt.completion.message[0] != 0)
	assert_equal(0, js_runtime_eval(rt, c"counter.n", 9, 100).status)
	assert1(rt.completion.value.number == 0.0)
	js_modules_free(modules)
	js_runtime_free(rt)
	module_fixture_free(fixture)

void test_modules_rejections():
	module_reject(c"import {missing} from 'dep'; export const x = 1;", 2)
	module_reject(c"import {x} from 'missing';", 2)
	module_reject(c"import x from 'dep';", 2)
	module_reject(c"export {missing} from 'dep';", 2)
	module_reject(c"export {x};", 6)
	module_reject(c"export const x = 1; export {x};", 6)
	module_reject(c"import {x} from 'dep'; const x = 2;", 6)
	module_reject(c"import('dep');", 6)
	module_reject(c"import 'de\\u0000p';", 6)
	module_reject(c"await 1;", 6)
	module_reject(c"import {x} from 'dep'; function* Unsupported() {}", 6)

void test_modules_cached_failure():
	module_fixture* fixture = module_fixture_new()
	module_fixture_add(fixture, c"bad", c"counter.n += 1; throw {reason:7}; export const x = 1;")
	module_fixture_add(fixture, c"first", c"import 'bad';")
	module_fixture_add(fixture, c"second", c"import 'bad';")
	module_fixture_add(fixture, c"linked", c"import 'bad';")
	js_runtime* rt = js_runtime_new()
	char* setup = c"const counter = {n:0};"
	js_runtime_eval(rt, setup, strlen(setup), 100)
	js_modules* modules = js_modules_new(rt, module_resolve, fixture)
	# Link a parent first, then fail its dependency through another parent.
	js_runtime_begin(rt, 1000)
	rt.running = 1
	js_module* linked = js_modules_link(modules, c"linked", c"", 1)
	rt.running = 0
	asserts(c"parent linked without evaluating", linked != 0 && linked.state == 1)
	asserts(c"first evaluation fails", js_modules_evaluate(modules, c"first", c"", 1000) == 0)
	assert_equal(2, rt.completion.status)
	js_value* thrown = rt.completion.value
	js_runtime_collect(rt)
	asserts(c"failed root cached", js_modules_evaluate(modules, c"first", c"", 1000) == 0)
	asserts(c"same cached exception", rt.completion.value == thrown)
	asserts(c"different root also fails", js_modules_evaluate(modules, c"second", c"", 1000) == 0)
	asserts(c"same dependency exception", rt.completion.value == thrown)
	asserts(c"previously linked parent fails", js_modules_evaluate(modules, c"linked", c"", 1000) == 0)
	assert_equal(2, rt.completion.status)
	asserts(c"execute restores cached exception", rt.completion.value == thrown)
	js_runtime_eval(rt, c"counter.n", 9, 100)
	assert1(rt.completion.value.number == 1.0)
	js_modules_free(modules)
	js_runtime_free(rt)
	module_fixture_free(fixture)

void test_modules_limits_and_imports():
	module_fixture* fixture = module_fixture_new()
	module_fixture_add(fixture, c"dep", c"export const x = 1;")
	module_fixture_add(fixture, c"root", c"import {x} from 'dep'; x = 2;")
	module_fixture_add(fixture, c"strict", c"undeclared = 1;")
	module_fixture_add(fixture, c"loop", c"while (true) {}")
	module_fixture_add(fixture, c"cycle-a", c"import 'cycle-b';")
	module_fixture_add(fixture, c"cycle-b", c"import 'cycle-a';")
	js_runtime* rt = js_runtime_new()
	js_modules* modules = js_modules_new(rt, module_resolve, fixture)
	asserts(c"import assignment rejected", js_modules_evaluate(modules, c"root", c"", 1000) == 0)
	assert_equal(2, rt.completion.status)
	asserts(c"strict undeclared assignment rejected", js_modules_evaluate(modules, c"strict", c"", 1000) == 0)
	assert_equal(2, rt.completion.status)
	asserts(c"indirect cycles link", js_modules_evaluate(modules, c"cycle-a", c"", 1000) != 0)
	asserts(c"loop bounded", js_modules_evaluate(modules, c"loop", c"", 100) == 0)
	assert_equal(5, rt.completion.status)
	js_modules_free(modules)
	modules = js_modules_new(rt, module_resolve, fixture)
	modules.max_modules = 1
	asserts(c"module count bounded", js_modules_evaluate(modules, c"root", c"", 1000) == 0)
	assert_equal(5, rt.completion.status)
	js_modules_free(modules)
	modules = js_modules_new(rt, module_resolve, fixture)
	modules.max_depth = 1
	asserts(c"module depth bounded", js_modules_evaluate(modules, c"root", c"", 1000) == 0)
	assert_equal(5, rt.completion.status)
	js_modules_free(modules)
	modules = js_modules_new(rt, module_resolve, fixture)
	modules.max_bytes = 1
	asserts(c"module bytes bounded", js_modules_evaluate(modules, c"root", c"", 1000) == 0)
	assert_equal(5, rt.completion.status)
	js_modules_free(modules)
	modules = js_modules_new(rt, module_resolve, fixture)
	modules.max_requests = 0
	asserts(c"module requests bounded", js_modules_evaluate(modules, c"root", c"", 1000) == 0)
	assert_equal(5, rt.completion.status)
	js_modules_free(modules)
	modules = js_modules_new(rt, module_resolve, fixture)
	int old_scripts = rt.max_scripts
	rt.max_scripts = rt.scripts.length
	asserts(c"runtime AST count bounded", js_modules_evaluate(modules, c"dep", c"", 1000) == 0)
	assert_equal(5, rt.completion.status)
	rt.max_scripts = old_scripts
	asserts(c"zero execution budget rejected", js_modules_evaluate(modules, c"dep", c"", 0) == 0)
	assert_equal(5, rt.completion.status)
	rt.parse_limits.tokens = 1
	asserts(c"parser tokens bounded", js_modules_evaluate(modules, c"dep", c"", 1000) == 0)
	assert_equal(5, rt.completion.status)
	js_modules_free(modules)
	js_runtime_free(rt)
	module_fixture_free(fixture)

void test_modules_function_exports():
	module_fixture* fixture = module_fixture_new()
	module_fixture_add(fixture, c"dep", c"let count = 0; export function next() { return ++count; } function hidden() { return 7; } export {hidden as value}; export function swap() { next = () => 20; }")
	module_fixture_add(fixture, c"root", c"import {next, value, swap} from 'dep'; export const [result] = [next() + next() + value()]; swap(); export const changed = next(); export const retained = () => next();")
	js_runtime* rt = js_runtime_new()
	js_modules* modules = js_modules_new(rt, module_resolve, fixture)
	js_module* root = js_modules_evaluate(modules, c"root", c"", 10000)
	asserts(c"function exports evaluated", root != 0)
	assert1(js_modules_export(modules, root, c"result").number == 10.0)
	assert1(js_modules_export(modules, root, c"changed").number == 20.0)
	js_value* retained = js_modules_export(modules, root, c"retained")
	js_runtime_root(rt, retained)
	js_modules_free(modules)
	js_runtime_collect(rt)
	list[js_value*] args = new list[js_value*]
	assert_equal(0, js_runtime_invoke(rt, retained, args, 1000).status)
	assert1(rt.completion.value.number == 20.0)
	__w_list_free(cast(__w_list*, args))
	js_runtime_free(rt)
	module_fixture_free(fixture)

# Evaluates root after declaring the global log string.
js_module* module_run(module_fixture* fixture, js_runtime* rt, js_modules* modules, char* root):
	char* setup = c"var log = '';"
	assert_equal(0, js_runtime_eval(rt, setup, strlen(setup), 100).status)
	return js_modules_evaluate(modules, root, c"", 100000)

float64 module_number(js_modules* modules, js_module* entry, char* name):
	js_value* value = js_modules_export(modules, entry, name)
	asserts(name, value != 0 && value.kind == 3)
	return value.number

int module_true(js_modules* modules, js_module* entry, char* name):
	js_value* value = js_modules_export(modules, entry, name)
	return value != 0 && value.kind == 2 && value.number != 0.0

int module_string(js_modules* modules, js_module* entry, char* name, char* expected):
	js_value* value = js_modules_export(modules, entry, name)
	if (value == 0 || value.kind != 4): return 0
	js_text* text = js_runtime_key(expected)
	int same = js_text_equal(text, value.text)
	js_text_free(text)
	return same

void test_modules_cycles():
	module_fixture* fixture = module_fixture_new()
	# a -> b -> a: b runs first and sees a's let binding in its TDZ; b's
	# function declaration is instantiated before any body runs.
	module_fixture_add(fixture, c"a", c"import {b, readA, early, hoisted} from 'b'; log += 'a'; export let a = 1; export const fromB = b + readA(); export const sawEarly = early; export const sawHoisted = hoisted; export function helper() { return 'hoisted'; }")
	module_fixture_add(fixture, c"b", c"import {a, helper} from 'a'; log += 'b'; let caught = 'none'; try { a; } catch (error) { caught = error.name; } export const early = caught; export const hoisted = helper(); export let b = 2; export function readA() { return a; }")
	module_fixture_add(fixture, c"c", c"import {a} from 'a'; log += 'c'; export const seen = a;")
	js_runtime* rt = js_runtime_new()
	js_modules* modules = js_modules_new(rt, module_resolve, fixture)
	js_module* a = module_run(fixture, rt, modules, c"a")
	asserts(c"cycle evaluated", a != 0)
	assert1(module_number(modules, a, c"fromB") == 3.0)
	asserts(c"TDZ in cycle", module_string(modules, a, c"sawEarly", c"ReferenceError"))
	asserts(c"functions instantiated at link", module_string(modules, a, c"sawHoisted", c"hoisted"))
	js_module* c = js_modules_evaluate(modules, c"c", c"", 1000)
	asserts(c"cached cycle reused", c != 0 && module_number(modules, c, c"seen") == 1.0)
	assert_equal(0, js_runtime_eval(rt, c"log", 3, 100).status)
	js_text* order = js_runtime_key(c"bac")
	asserts(c"DFS evaluation order", js_text_equal(order, rt.completion.value.text))
	js_text_free(order)
	js_modules_free(modules)
	js_runtime_free(rt)
	module_fixture_free(fixture)

void test_modules_cycle_failure():
	module_fixture* fixture = module_fixture_new()
	module_fixture_add(fixture, c"a", c"import 'b'; export const x = 1;")
	module_fixture_add(fixture, c"b", c"import 'a'; throw {reason: 3};")
	module_fixture_add(fixture, c"c", c"import {x} from 'a';")
	js_runtime* rt = js_runtime_new()
	js_modules* modules = js_modules_new(rt, module_resolve, fixture)
	asserts(c"cycle throw fails", js_modules_evaluate(modules, c"a", c"", 1000) == 0)
	assert_equal(2, rt.completion.status)
	js_value* thrown = rt.completion.value
	asserts(c"every module on the stack failed", modules.entries[0].state == 4 && modules.entries[1].state == 4)
	asserts(c"importer sees cached error", js_modules_evaluate(modules, c"c", c"", 1000) == 0 && rt.completion.value == thrown)
	js_modules_free(modules)
	js_runtime_free(rt)
	module_fixture_free(fixture)

void test_modules_default_and_namespace():
	module_fixture* fixture = module_fixture_new()
	module_fixture_add(fixture, c"fn", c"export default function () { return 5; }")
	module_fixture_add(fixture, c"named", c"export default function seven() { return 7; } export const again = seven();")
	module_fixture_add(fixture, c"expr", c"export default (function () { return 3; });")
	module_fixture_add(fixture, c"cls", c"export default class { get value() { return 11; } }")
	module_fixture_add(fixture, c"value", c"export let count = 1; export function inc() { count += 1; } export default 40 + 2; let hidden = 0;")
	module_fixture_add(fixture, c"root", c"import f from 'fn'; import seven, {again} from 'named'; import e from 'expr'; import C from 'cls'; import * as ns from 'value'; import answer from 'value'; export const total = f() + seven() + e() + new C().value + again; export const names = f.name + ',' + seven.name + ',' + e.name + ',' + C.name; export const before = ns.count; ns.inc(); export const after = ns.count; export const dflt = ns.default === answer; export const tag = ns[Symbol.toStringTag]; export const proto = Object.getPrototypeOf(ns) === null; export const missing = ns.hidden === undefined; let rejected = false; try { ns.count = 9; } catch (error) { rejected = error instanceof TypeError; } export const readOnly = rejected && ns.count === 2; let added = false; try { ns.extra = 1; } catch (error) { added = ns.extra === undefined; } export const sealed = added; export {ns};")
	js_runtime* rt = js_runtime_new()
	js_modules* modules = js_modules_new(rt, module_resolve, fixture)
	js_module* root = module_run(fixture, rt, modules, c"root")
	asserts(c"default and namespace imports evaluated", root != 0)
	assert1(module_number(modules, root, c"total") == 33.0)
	asserts(c"default names", module_string(modules, root, c"names", c"default,seven,default,default"))
	assert1(module_number(modules, root, c"before") == 1.0)
	assert1(module_number(modules, root, c"after") == 2.0)
	asserts(c"namespace default", module_true(modules, root, c"dflt"))
	asserts(c"namespace tag", module_string(modules, root, c"tag", c"Module"))
	asserts(c"namespace prototype", module_true(modules, root, c"proto"))
	asserts(c"namespace omits private names", module_true(modules, root, c"missing"))
	asserts(c"namespace read-only", module_true(modules, root, c"readOnly"))
	asserts(c"namespace not extensible", module_true(modules, root, c"sealed"))
	js_module* value = js_modules_evaluate(modules, c"value", c"", 1000)
	asserts(c"host namespace is the imported one", js_modules_namespace(modules, value) == js_modules_export(modules, root, c"ns"))
	assert1(module_number(modules, value, c"default") == 42.0)
	js_modules_free(modules)
	js_runtime_free(rt)
	module_fixture_free(fixture)

void test_modules_star_exports():
	module_fixture* fixture = module_fixture_new()
	module_fixture_add(fixture, c"dep", c"export let count = 1; export function inc() { count += 1; } export default 'hidden';")
	module_fixture_add(fixture, c"other", c"export const count = 0;")
	module_fixture_add(fixture, c"mid", c"export * from 'dep'; export * as inner from 'dep';")
	module_fixture_add(fixture, c"both", c"export * from 'dep'; export * from 'other';")
	module_fixture_add(fixture, c"root", c"import {count, inc, inner} from 'mid'; import * as mid from 'mid'; inc(); export const live = count; export const nested = inner.count; export const same = inner === mid.inner; export const noDefault = mid.default === undefined && inner.default === 'hidden';")
	module_fixture_add(fixture, c"ambiguous", c"import {count} from 'both';")
	module_fixture_add(fixture, c"spread", c"import * as both from 'both'; export const skipped = both.count === undefined && typeof both.inc === 'function';")
	js_runtime* rt = js_runtime_new()
	js_modules* modules = js_modules_new(rt, module_resolve, fixture)
	js_module* root = module_run(fixture, rt, modules, c"root")
	asserts(c"star exports evaluated", root != 0)
	assert1(module_number(modules, root, c"live") == 2.0)
	assert1(module_number(modules, root, c"nested") == 2.0)
	asserts(c"export * as ns is one namespace", module_true(modules, root, c"same"))
	asserts(c"export * skips default", module_true(modules, root, c"noDefault"))
	js_module* mid = js_modules_evaluate(modules, c"mid", c"", 1000)
	assert1(js_modules_export(modules, mid, c"count").number == 2.0)
	asserts(c"host export of a namespace re-export", js_modules_export(modules, mid, c"inner") != 0)
	asserts(c"ambiguous star import rejected", js_modules_evaluate(modules, c"ambiguous", c"", 1000) == 0)
	assert_equal(2, rt.completion.status)
	asserts(c"link error is a SyntaxError", strcmp(rt.completion.value.intrinsic_error_name, c"SyntaxError") == 0)
	js_module* spread = js_modules_evaluate(modules, c"spread", c"", 1000)
	asserts(c"ambiguous names leave the namespace", spread != 0 && module_true(modules, spread, c"skipped"))
	js_modules_free(modules)
	js_runtime_free(rt)
	module_fixture_free(fixture)

int main():
	test_modules_cycles()
	test_modules_cycle_failure()
	test_modules_default_and_namespace()
	test_modules_star_exports()
	test_modules_function_exports()
	test_modules_graph()
	test_modules_rejections()
	test_modules_cached_failure()
	test_modules_limits_and_imports()
	println(c"javascript_modules_test: OK")
	return 0
