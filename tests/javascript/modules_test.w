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
	module_reject(c"import 'root';", 6)
	module_reject(c"import x from 'dep';", 6)
	module_reject(c"import * as ns from 'dep';", 6)
	module_reject(c"export default 1;", 6)
	module_reject(c"export * from 'dep';", 6)
	module_reject(c"export {x} from 'dep';", 6)
	module_reject(c"export let x = 1;", 6)
	module_reject(c"let x = 1; export {x};", 6)
	module_reject(c"export {x};", 6)
	module_reject(c"export const x = 1; export {x};", 6)
	module_reject(c"import {x} from 'dep'; const x = 2;", 6)
	module_reject(c"import('dep');", 6)
	module_reject(c"import 'de\\u0000p';", 6)
	module_reject(c"await 1;", 6)
	module_reject(c"import {x} from 'dep'; class Unsupported {}", 6)

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
	asserts(c"indirect cycles rejected", js_modules_evaluate(modules, c"cycle-a", c"", 1000) == 0)
	assert_equal(6, rt.completion.status)
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

int main():
	test_modules_function_exports()
	test_modules_graph()
	test_modules_rejections()
	test_modules_cached_failure()
	test_modules_limits_and_imports()
	println(c"javascript_modules_test: OK")
	return 0
