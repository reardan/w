# wbuild: name=javascript_runtime_promise_retry_test
# wbuild: target=javascript_runtime_promise_retry_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 tests/javascript/runtime_promise_retry_test.w -o bin/javascript_runtime_promise_retry_test"
# wbuild: step="bin/javascript_runtime_promise_retry_test" expect_stdout="javascript_runtime_promise_retry_test: OK"
# wbuild: step="bin/javascript_runtime_promise_retry_test memory" expect_stdout="javascript_runtime_promise_retry_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

void test_promise_retry(int rejected):
	js_runtime* rt = js_runtime_new()
	js_value* promise = js_runtime_promise_new(rt)
	js_runtime_set(rt, rt.global, c"pending", promise)
	char* source = c"let result=0;pending.then(v=>{result=v;},e=>{result=e;});pending.then(()=>{});"
	assert_equal(0, js_runtime_eval(rt, source, strlen(source), 1000).status)
	js_value* value = js_runtime_number(rt, 7.0)
	js_runtime_root(rt, value)
	rt.max_microtasks = 1
	js_runtime_begin(rt, 1000)
	assert_equal(0, js_runtime_promise_settle(rt, promise, value, rejected))
	assert_equal(5, rt.completion.status)
	assert_equal(1, promise.promise_state)
	assert_equal(0, rt.microtasks.length)
	js_runtime_collect(rt)
	rt.max_microtasks = 10000
	js_runtime_begin(rt, 1000)
	assert_equal(1, js_runtime_promise_settle(rt, promise, value, rejected))
	assert_equal(2 + rejected, promise.promise_state)
	assert_equal(0, js_runtime_drain_microtasks(rt, 1000).status)
	assert_equal(0, js_runtime_eval(rt, c"result===7;", 11, 100).status)
	assert1(rt.completion.value.number == 1.0)
	js_runtime_free(rt)

void test_thenable_retry():
	js_runtime* rt = js_runtime_new()
	char* source = c"let calls=0;const object={then(r){calls++;r(7);}};"
	assert_equal(0, js_runtime_eval(rt, source, strlen(source), 1000).status)
	js_value* value = js_runtime_get(rt, rt.global, c"object")
	js_value* promise = js_runtime_promise_new(rt)
	js_runtime_root(rt, promise)
	rt.max_microtasks = 0
	js_runtime_begin(rt, 1000)
	assert_equal(0, js_runtime_promise_settle(rt, promise, value, 0))
	assert_equal(1, promise.promise_state)
	js_runtime_collect(rt)
	rt.max_microtasks = 10000
	js_runtime_begin(rt, 1000)
	assert1(js_runtime_promise_settle(rt, promise, value, 0))
	assert_equal(0, js_runtime_drain_microtasks(rt, 1000).status)
	assert_equal(2, promise.promise_state)
	assert1(promise.promise_result.number == 7.0)
	assert_equal(0, js_runtime_eval(rt, c"calls===1;", 10, 100).status)
	assert1(rt.completion.value.number == 1.0)
	js_runtime_free(rt)

int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	test_promise_retry(0)
	test_promise_retry(1)
	test_thenable_retry()
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_promise_retry_test: OK")
	return 0
