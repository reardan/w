# wbuild: name=javascript_runtime_promises_test
# wbuild: target=javascript_runtime_promises_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 tests/javascript/runtime_promises_test.w -o bin/javascript_runtime_promises_test"
# wbuild: step="bin/javascript_runtime_promises_test" expect_stdout="javascript_runtime_promises_test: OK"
# wbuild: step="bin/javascript_runtime_promises_test memory" expect_stdout="javascript_runtime_promises_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime


js_value* promise_eval(js_runtime* rt, char* source):
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 10000)
	assert_equal(0, result.status)
	return result.value


void test_promises():
	js_runtime* rt = js_runtime_new()
	promise_eval(rt, c"let log = ''; Promise.resolve(4).then(x => { log += 'a'; return x + 1; }).then(x => { log += `${x}`; }); queueMicrotask(() => { log += 'b'; }); log;")
	assert1(js_runtime_get(rt, rt.global, c"log").text.units.length == 0)
	# Queued reactions retain both callbacks and anonymous source promises.
	js_runtime_collect(rt)
	assert_equal(0, js_runtime_drain_microtasks(rt, 1000).status)
	assert1(promise_eval(rt, c"log === 'ab5';").number == 1.0)
	promise_eval(rt, c"let result = 0; Promise.reject(7).then(0).catch(x => x + 1).then(x => { throw x + 2; }).catch(x => { result = x; });")
	assert_equal(0, js_runtime_drain_microtasks(rt, 1000).status)
	assert1(promise_eval(rt, c"result === 10;").number == 1.0)
	promise_eval(rt, c"let adopted = 0; Promise.resolve(1).then(x => Promise.resolve(x + 3)).then(x => { adopted = x; });")
	assert_equal(0, js_runtime_drain_microtasks(rt, 1000).status)
	assert1(promise_eval(rt, c"adopted === 4;").number == 1.0)
	promise_eval(rt, c"let cycle; let caught = false; cycle = Promise.resolve().then(() => cycle); cycle.catch(() => { caught = true; });")
	assert_equal(0, js_runtime_drain_microtasks(rt, 1000).status)
	assert1(promise_eval(rt, c"caught;").number == 1.0)
	assert1(promise_eval(rt, c"let same = Promise.resolve(3); Promise.resolve(same) === same;").number == 1.0)
	js_runtime_free(rt)


void test_executor():
	js_runtime* rt = js_runtime_new()
	promise_eval(rt, c"let finish; let result = 0; let started = false; new Promise(resolve => { started = true; finish = resolve; }).then(x => { result = x; });")
	assert1(promise_eval(rt, c"started && result === 0;").number == 1.0)
	js_runtime_collect(rt)
	promise_eval(rt, c"finish(19); finish(22);")
	assert_equal(0, js_runtime_drain_microtasks(rt, 1000).status)
	assert1(promise_eval(rt, c"result === 19;").number == 1.0)
	promise_eval(rt, c"new Promise((resolve, reject) => { reject(4); resolve(7); }).catch(x => { result = x; });")
	assert_equal(0, js_runtime_drain_microtasks(rt, 1000).status)
	assert1(promise_eval(rt, c"result === 4;").number == 1.0)
	promise_eval(rt, c"new Promise(() => { throw 12; }).catch(x => { result = x; });")
	assert_equal(0, js_runtime_drain_microtasks(rt, 1000).status)
	assert1(promise_eval(rt, c"result === 12;").number == 1.0)
	promise_eval(rt, c"new Promise(resolve => { resolve(8); throw 12; }).then(x => { result = x; });")
	assert_equal(0, js_runtime_drain_microtasks(rt, 1000).status)
	assert1(promise_eval(rt, c"result === 8;").number == 1.0)
	promise_eval(rt, c"let finishInner; let inner = new Promise(resolve => { finishInner = resolve; }); new Promise((resolve, reject) => { resolve(inner); reject(9); }).then(x => { result = x; }); finishInner(27);")
	js_runtime_collect(rt)
	assert_equal(0, js_runtime_drain_microtasks(rt, 1000).status)
	assert1(promise_eval(rt, c"result === 27;").number == 1.0)
	assert1(promise_eval(rt, c"let bad = 0; try { Promise(() => {}); } catch(e) { bad++; } try { new Promise(5); } catch(e) { bad++; } bad === 2;").number == 1.0)
	promise_eval(rt, c"queueMicrotask(() => { result = 99; });")
	js_runtime_clear_microtasks(rt)
	js_runtime_collect(rt)
	assert_equal(0, js_runtime_drain_microtasks(rt, 1000).status)
	assert1(promise_eval(rt, c"result === 27;").number == 1.0)
	js_runtime_free(rt)


void test_pending_and_limits():
	js_runtime* rt = js_runtime_new()
	js_runtime* other = js_runtime_new()
	js_value* pending = js_runtime_promise_new(rt)
	js_runtime_set(rt, rt.global, c"pending", pending)
	promise_eval(rt, c"let answer = 0; pending.then(x => { answer = x; });")
	js_runtime_collect(rt)
	assert_equal(0, js_runtime_drain_microtasks(rt, 10).status)
	assert1(js_runtime_promise_settle(rt, pending, js_runtime_number(rt, 42.0), 0))
	assert1(js_runtime_promise_settle(rt, pending, rt.undefined_value, 1))
	js_runtime_collect(rt)
	assert_equal(5, js_runtime_drain_microtasks(rt, 0).status)
	assert_equal(0, js_runtime_drain_microtasks(rt, 100).status)
	assert1(promise_eval(rt, c"answer === 42;").number == 1.0)
	promise_eval(rt, c"queueMicrotask(() => { throw 9; }); queueMicrotask(() => { answer = 8; });")
	assert_equal(2, js_runtime_drain_microtasks(rt, 100).status)
	js_runtime_collect(rt)
	assert_equal(0, js_runtime_drain_microtasks(rt, 100).status)
	assert1(promise_eval(rt, c"answer === 8;").number == 1.0)
	promise_eval(rt, c"function repeat() { queueMicrotask(repeat); } queueMicrotask(repeat);")
	assert_equal(5, js_runtime_drain_microtasks(rt, 80).status)
	assert_equal(80, rt.completion.steps)
	assert1(rt.microtasks.length <= 1)
	js_runtime_begin(rt, 100)
	assert_equal(0, js_runtime_promise_settle(rt, pending, other.undefined_value, 0))
	assert_equal(2, rt.completion.status)
	js_runtime_free(other)
	js_runtime_free(rt)
	rt = js_runtime_new()
	rt.max_microtasks = 1
	char* overflow = c"queueMicrotask(() => {}); queueMicrotask(() => {});"
	assert_equal(5, js_runtime_eval(rt, overflow, strlen(overflow), 100).status)
	assert_equal(0, js_runtime_drain_microtasks(rt, 100).status)
	js_runtime_free(rt)


int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	test_promises()
	test_executor()
	test_pending_and_limits()
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_promises_test: OK")
	return 0
