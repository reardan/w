# wbuild: name=javascript_runtime_invoke_test
# wbuild: target=javascript_runtime_invoke_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 tests/javascript/runtime_invoke_test.w -o bin/javascript_runtime_invoke_test"
# wbuild: step="bin/javascript_runtime_invoke_test" expect_stdout="javascript_runtime_invoke_test: OK"
# wbuild: step="bin/javascript_runtime_invoke_test memory" expect_stdout="javascript_runtime_invoke_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime


js_value* invoke_fixture(js_runtime* rt, char* source):
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 10000)
	assert_equal(0, result.status)
	return result.value


js_value* invoke_host(void* context, list[js_value*] arguments):
	js_runtime* rt = cast(js_runtime*, context)
	assert_equal(-1, js_runtime_collect(rt))
	assert1(js_runtime_invoke(rt, rt.undefined_value, arguments, 10) == 0)
	assert1(js_runtime_eval(rt, c"1;", 2, 10) == 0)
	if (arguments.length == 0):
		js_runtime_throw(rt, rt.undefined_value)
		return rt.undefined_value
	return arguments[0]


void test_invoke_lifetime():
	js_runtime* rt = js_runtime_new()
	js_value* callback = invoke_fixture(rt, c"(function() { let state = 0; return function(delta) { state += delta; return {state}; }; })();")
	assert1(js_runtime_root(rt, callback))
	invoke_fixture(rt, c"0;")
	js_runtime_collect(rt)
	list[js_value*] arguments = new list[js_value*]
	js_value* delta = js_runtime_number(rt, 21.0)
	assert1(js_runtime_root(rt, delta))
	arguments.push(delta)
	int script_count = rt.scripts.length
	# A retained callback still runs after script storage reaches its cap.
	rt.max_scripts = script_count
	js_completion* result = js_runtime_invoke(rt, callback, arguments, 1000)
	assert_equal(0, result.status)
	assert1(js_runtime_get(rt, result.value, c"state").number == 21.0)
	assert1(result.steps > 1)
	# The returned object is rooted by the completion, even after collection.
	js_runtime_collect(rt)
	assert1(js_runtime_get(rt, result.value, c"state").number == 21.0)
	result = js_runtime_invoke(rt, callback, arguments, 1000)
	assert_equal(0, result.status)
	assert1(js_runtime_get(rt, result.value, c"state").number == 42.0)
	assert_equal(script_count, rt.scripts.length)
	js_runtime_unroot(rt, callback)
	js_runtime_unroot(rt, delta)
	# Replace the completion without parsing, so the now-unrooted closure and
	# its captured environment can be reclaimed despite the script cap.
	assert1(js_runtime_bind(rt, c"identity", invoke_host))
	js_value* identity = js_runtime_get(rt, rt.global, c"identity")
	result = js_runtime_invoke(rt, identity, arguments, 1)
	assert_equal(0, result.status)
	assert_equal(1, result.steps)
	assert1(result.value == delta)
	assert1(js_runtime_collect(rt) > 0)
	__w_list_free(cast(__w_list*, arguments))
	js_runtime_free(rt)


void test_invoke_errors():
	js_runtime* rt = js_runtime_new()
	js_runtime* other = js_runtime_new()
	list[js_value*] arguments = new list[js_value*]
	js_value* callable = invoke_fixture(rt, c"function echo(value) { return value; } echo;")
	assert_equal(2, js_runtime_invoke(rt, 0, arguments, 100).status)
	assert_equal(2, js_runtime_invoke(rt, other.undefined_value, arguments, 100).status)
	assert_equal(2, js_runtime_invoke(rt, rt.undefined_value, arguments, 100).status)
	assert_equal(2, js_runtime_invoke(rt, callable, 0, 100).status)
	arguments.push(other.undefined_value)
	assert_equal(2, js_runtime_invoke(rt, callable, arguments, 100).status)
	rt.max_properties = 0
	assert_equal(5, js_runtime_invoke(rt, callable, arguments, 100).status)
	rt.max_properties = 10000
	arguments[0] = 0
	assert_equal(2, js_runtime_invoke(rt, callable, arguments, 100).status)
	arguments.pop()
	assert_equal(5, js_runtime_invoke(rt, callable, arguments, 0).status)
	assert_equal(5, js_runtime_invoke(rt, callable, arguments, 1).status)
	assert_equal(1, rt.completion.steps)
	js_completion* result = js_runtime_invoke(rt, callable, arguments, 100)
	assert_equal(0, result.status)
	assert1(result.value == rt.undefined_value)
	js_value* exception = invoke_fixture(rt, c"function fail() { try { throw 7; } finally { 9; } } fail;")
	result = js_runtime_invoke(rt, exception, arguments, 100)
	assert_equal(2, result.status)
	assert1(result.value.number == 7.0)
	js_runtime_collect(rt)
	assert1(result.value.number == 7.0)
	js_value* recursive = invoke_fixture(rt, c"function recurse() { return recurse(); } recurse;")
	rt.max_depth = 12
	assert_equal(5, js_runtime_invoke(rt, recursive, arguments, 1000).status)
	assert_equal(0, rt.depth)
	assert_equal(0, rt.running)
	rt.max_depth = 256
	js_value* forever = invoke_fixture(rt, c"function loop() { while (true) {} } loop;")
	result = js_runtime_invoke(rt, forever, arguments, 30)
	assert_equal(5, result.status)
	assert_equal(30, result.steps)
	assert1(js_runtime_bind(rt, c"identity", invoke_host))
	js_value* identity = js_runtime_get(rt, rt.global, c"identity")
	assert_equal(2, js_runtime_invoke(rt, identity, arguments, 1).status)
	arguments.push(js_runtime_number(rt, 42.0))
	result = js_runtime_invoke(rt, identity, arguments, 1)
	assert_equal(0, result.status)
	assert1(result.value.number == 42.0)
	__w_list_free(cast(__w_list*, arguments))
	js_runtime_free(other)
	js_runtime_free(rt)


int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	test_invoke_lifetime()
	test_invoke_errors()
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_invoke_test: OK")
	return 0
