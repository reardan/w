# wbuild: name=javascript_modules_async_test
# wbuild: target=javascript_modules_async_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 tests/javascript/modules_async_test.w -o bin/javascript_modules_async_test"
# wbuild: step="bin/javascript_modules_async_test" expect_stdout="javascript_modules_async_test: OK"
# wbuild: step="bin/javascript_modules_async_test memory" expect_stdout="javascript_modules_async_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.modules

struct async_module_fixture:
	js_module_source borrowed
	int calls
	char* source

js_module_source* async_module_resolve(void* context, char* name, char* referrer):
	async_module_fixture* fixture = cast(async_module_fixture*, context)
	fixture.calls = fixture.calls + 1
	fixture.borrowed.identifier = name
	char* source = fixture.source
	if (source == 0):
		if (strcmp(name, c"dep") == 0): source = c"order+='d'; export const value=await pending; order+='D';"
		elif (strcmp(name, c"root") == 0): source = c"import {value} from 'dep'; order+='r'; export const result=value+1;"
		else: source = c"import {value} from 'dep'; order+='j'; export const result=value+2;"
	fixture.borrowed.source = source
	fixture.borrowed.length = strlen(source)
	return &fixture.borrowed

void async_module_eval(js_runtime* rt, char* source):
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 10000)
	assert_equal(0, result.status)
	assert1(result.value.number == 1.0)

void async_module_graph():
	async_module_fixture fixture
	fixture.source = 0
	fixture.calls = 0
	js_runtime* rt = js_runtime_new()
	async_module_eval(rt, c"let order='';let resolve;const pending=new Promise(r=>{resolve=r;});true;")
	js_modules* modules = js_modules_new(rt, async_module_resolve, &fixture)
	js_module* root = js_modules_evaluate_async(modules, c"root", c"", 10000)
	if (root == 0): println(rt.completion.message)
	assert1(root != 0)
	assert_equal(2, root.state)
	assert_equal(1, root.evaluation_promise.promise_state)
	assert1(js_modules_export(modules, root, c"result") == 0)
	# A second root joins the already pending dependency without restarting it.
	js_module* join = js_modules_evaluate_async(modules, c"join", c"", 10000)
	assert1(join != 0)
	assert_equal(2, join.state)
	assert_equal(3, rt.async_tasks.length)
	js_runtime_collect(rt)
	async_module_eval(rt, c"order==='d';")
	async_module_eval(rt, c"resolve(40);order==='d';")
	assert_equal(0, js_runtime_drain_microtasks(rt, 10000).status)
	assert_equal(3, root.state)
	assert_equal(3, join.state)
	assert_equal(2, root.evaluation_promise.promise_state)
	assert1(js_modules_export(modules, root, c"result").number == 41.0)
	assert1(js_modules_export(modules, join, c"result").number == 42.0)
	async_module_eval(rt, c"order==='dDrj';")
	assert1(js_modules_evaluate_async(modules, c"root", c"", 10000) == root)
	assert_equal(0, rt.async_tasks.length)
	js_modules_free(modules)
	js_runtime_free(rt)

void async_module_rejection():
	async_module_fixture fixture
	fixture.source = 0
	fixture.calls = 0
	fixture.source = c"await Promise.reject(17); export const unreachable=1;"
	js_runtime* rt = js_runtime_new()
	js_modules* modules = js_modules_new(rt, async_module_resolve, &fixture)
	js_module* entry = js_modules_evaluate_async(modules, c"bad", c"", 10000)
	assert1(entry != 0)
	assert_equal(2, entry.state)
	assert_equal(0, js_runtime_drain_microtasks(rt, 10000).status)
	assert_equal(4, entry.state)
	assert_equal(3, entry.evaluation_promise.promise_state)
	assert1(entry.evaluation_promise.promise_result.number == 17.0)
	js_runtime_collect(rt)
	assert1(js_modules_evaluate_async(modules, c"bad", c"", 10000) == 0)
	assert_equal(2, rt.completion.status)
	assert1(rt.completion.value.number == 17.0)
	js_modules_free(modules)
	js_runtime_free(rt)

void async_module_cancel():
	async_module_fixture fixture
	fixture.source = 0
	fixture.calls = 0
	fixture.source = c"await pending; ran=1;"
	js_runtime* rt = js_runtime_new()
	async_module_eval(rt, c"let release;let ran=0;const pending=new Promise(r=>{release=r;});async function standalone(){await pending;ran+=2;}standalone();true;")
	js_modules* modules = js_modules_new(rt, async_module_resolve, &fixture)
	assert1(js_modules_evaluate_async(modules, c"root", c"", 10000) != 0)
	assert_equal(2, rt.async_tasks.length)
	js_modules_free(modules)
	assert_equal(1, rt.async_tasks.length)
	js_runtime_collect(rt)
	async_module_eval(rt, c"release(1);true;")
	assert_equal(0, js_runtime_drain_microtasks(rt, 10000).status)
	async_module_eval(rt, c"ran===2;")
	js_runtime_free(rt)

void async_module_profile():
	js_parse_limits* limits = js_parse_limits_new()
	char* source = c"await 1;"
	pg_parse_result* parsed = js_parse_with_limits(source, strlen(source), c"profile", 1, limits)
	assert_equal(0, parsed.success)
	pg_parse_result_free(parsed)
	limits.top_level_await = 1
	parsed = js_parse_with_limits(source, strlen(source), c"profile", 1, limits)
	assert_equal(1, parsed.success)
	pg_parse_result_free(parsed)
	parsed = js_parse_with_limits(source, strlen(source), c"profile", 0, limits)
	assert_equal(0, parsed.success)
	pg_parse_result_free(parsed)
	source = c"function f(){await 1;}"
	parsed = js_parse_with_limits(source, strlen(source), c"profile", 1, limits)
	assert_equal(0, parsed.success)
	pg_parse_result_free(parsed)
	source = c"async function f(x=await 1){}"
	parsed = js_parse_with_limits(source, strlen(source), c"profile", 1, limits)
	assert_equal(0, parsed.success)
	pg_parse_result_free(parsed)
	free(limits)

int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	async_module_graph()
	async_module_cancel()
	if (argc == 1):
		async_module_rejection()
		async_module_profile()
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_modules_async_test: OK")
	return 0
