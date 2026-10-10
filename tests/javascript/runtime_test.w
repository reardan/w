# wbuild: name=javascript_runtime_test
# wbuild: target=javascript_runtime_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 tests/javascript/runtime_test.w -o bin/javascript_runtime_test"
# wbuild: step="bin/javascript_runtime_test" expect_stdout="javascript_runtime_test: OK"
# wbuild: step="bin/javascript_runtime_test memory" expect_stdout="javascript_runtime_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime


js_completion* js_test_eval(js_runtime* rt, char* source):
	return js_runtime_eval(rt, source, strlen(source), 10000)


void js_test_number(js_runtime* rt, char* source, float64 expected):
	js_completion* result = js_test_eval(rt, source)
	assert_equal(0, result.status)
	assert_equal(3, result.value.kind)
	assert1(result.value.number == expected)


js_value* js_test_host(void* context, list[js_value*] arguments):
	js_runtime* rt = cast(js_runtime*, context)
	assert_equal(-1, js_runtime_collect(rt))
	assert1(js_runtime_eval(rt, c"1;", 2, 10) == 0)
	assert1(js_runtime_invoke(rt, rt.undefined_value, arguments, 10) == 0)
	if (arguments.length != 1):
		js_runtime_throw(rt, rt.undefined_value)
		return rt.undefined_value
	return js_runtime_number(rt, arguments[0].number * 2.0)


void js_test_semantics():
	js_runtime* rt = js_runtime_new()
	js_test_number(rt, c"0.1 + 0.2;", 0.1 + 0.2)
	js_test_number(rt, c"let x = 1; { let x = 40; x++; } x;", 1.0)
	js_test_number(rt, c"function make(x) { return function(y) { x += y; return x; }; } const add = make(3); add(4); add(5);", 12.0)
	js_test_number(rt, c"const factorial = function fact(n) { if (n < 2) return 1; return n * fact(n - 1); }; factorial(5);", 120.0)
	js_test_number(rt, c"let sum = 0; for (let i = 0; i < 5; i++) { if (i === 2) continue; sum += i; } do { sum++; } while (sum < 10); while (true) { sum++; break; } sum;", 11.0)
	js_test_number(rt, c"const fns = []; for (let i = 0; i < 3; i++) { fns[i] = function() { return i; }; } fns[0]() * 100 + fns[1]() * 10 + fns[2]();", 12.0)
	js_test_number(rt, c"let initial; for (let i = 0, capture = (initial = function() { return i; }); i < 1; i++) { i = 7; } initial();", 0.0)
	js_test_number(rt, c"const a = [2, 4]; const o = {a, value: 1}; o.a[1] += 3; o.value++; a[1] + o.value + a.length;", 11.0)
	js_test_number(rt, c"let counter = 0; function receiver() { counter++; return o; } receiver().value += 2; counter * 10 + o.value;", 14.0)
	js_test_number(rt, c"false && missing(); true || missing(); null ?? 42;", 42.0)
	js_test_number(rt, c"const s = '\\0\\ud800x'; s.length;", 3.0)
	js_completion* result = js_test_eval(rt, c"s[0] + s[1];")
	assert_equal(0, result.status)
	assert_equal(4, result.value.kind)
	assert_equal(2, result.value.text.units.length)
	assert_equal(0, result.value.text.units[0])
	assert_equal(55296, result.value.text.units[1])
	result = js_test_eval(rt, c"NaN === NaN;")
	assert_equal(0, result.status)
	assert_equal(0, js_runtime_truth(result.value))
	assert1(js_runtime_bind(rt, c"twice", js_test_host))
	js_test_number(rt, c"twice(21);", 42.0)
	result = js_test_eval(rt, c"twice();")
	assert_equal(2, result.status)
	js_test_number(rt, c"function fromLoop() { while (true) { return 42; } } fromLoop();", 42.0)
	js_test_number(rt, c"let caught = 0; try { throw 40; } catch (e) { caught = e; } finally { caught += 2; } caught;", 42.0)
	js_test_number(rt, c"function fin() { try { return 1; } finally { return 2; } } fin();", 2.0)
	js_test_number(rt, c"function kept() { try { return 3; } finally { 4; } } kept();", 3.0)
	assert_equal(2, js_test_eval(rt, c"try { throw 7; } finally { 8; }").status)
	js_runtime_free(rt)


void js_test_errors_and_limits():
	js_runtime* rt = js_runtime_new()
	assert_equal(2, js_test_eval(rt, c"const fixed = 1; fixed = 2;").status)
	assert_equal(2, js_test_eval(rt, c"{ x; let x = 2; }").status)
	assert_equal(2, js_test_eval(rt, c"absent;").status)
	# Declaration conflicts are checked before any new bindings are installed.
	assert_equal(2, js_test_eval(rt, c"let fresh = 1; const fixed = 2;").status)
	js_test_number(rt, c"let fresh = 42; fresh;", 42.0)
	assert_equal(2, js_test_eval(rt, c"function unused() {} function fixed() {}").status)
	js_test_number(rt, c"let unused = 42; unused;", 42.0)
	js_test_number(rt, c"var old = 1; old;", 1.0)
	assert_equal(6, js_test_eval(rt, c"1 == 1;").status)
	assert_equal(6, js_test_eval(rt, c"1 + '1';").status)
	js_completion* result = js_test_eval(rt, c"throw 'failure';")
	assert_equal(2, result.status)
	assert_equal(4, result.value.kind)
	char* loop = c"while (true) {}"
	result = js_runtime_eval(rt, loop, strlen(loop), 50)
	assert_equal(5, result.status)
	assert_equal(50, result.steps)
	js_test_number(rt, c"40 + 2;", 42.0)
	rt.max_depth = 20
	assert_equal(5, js_test_eval(rt, c"function recur() { return recur(); } recur();").status)
	rt.parse_limits.tokens = 2
	assert_equal(5, js_test_eval(rt, c"1 + 2;").status)
	rt.parse_limits.tokens = 1000000
	rt.max_properties = 2
	assert_equal(5, js_test_eval(rt, c"'long';").status)
	assert_equal(5, js_test_eval(rt, c"[1, 2, 3];").status)
	rt.max_values = rt.heap.length
	assert_equal(5, js_test_eval(rt, c"123;").status)
	js_runtime_free(rt)


void js_test_collection():
	js_runtime* rt = js_runtime_new()
	js_runtime* other = js_runtime_new()
	js_value* cycle = js_test_eval(rt, c"const o = {}; o.self = o; o;").value
	assert1(js_runtime_root(rt, cycle))
	assert1(js_runtime_root(other, cycle) == 0)
	assert1(js_runtime_set(other, other.global, c"foreign", cycle) == 0)
	assert_equal(2, js_test_eval(other, c"o;").status)
	js_runtime_collect(rt)
	js_test_number(rt, c"let n = 42; n;", 42.0)
	js_runtime_unroot(rt, cycle)
	# Retained global bindings keep reachable cycles alive; an isolated cycle
	# created by an IIFE is collectable after its completion is replaced.
	js_value* temporary = js_test_eval(rt, c"(function() { const x = {}; x.self = x; return x; })();").value
	assert1(js_runtime_root(rt, temporary))
	js_test_number(rt, c"1;", 1.0)
	js_runtime_collect(rt)
	assert1(js_runtime_get(rt, temporary, c"self") == temporary)
	int rooted = rt.heap.length
	js_runtime_unroot(rt, temporary)
	assert1(js_runtime_collect(rt) > 0)
	assert1(rt.heap.length < rooted)
	# Captured lexical environments remain traced along with their functions.
	js_test_number(rt, c"function factory() { let state = 7; return function() { state++; return state; }; } const closure = factory(); closure();", 8.0)
	js_runtime_collect(rt)
	js_test_number(rt, c"closure();", 9.0)
	js_runtime_free(other)
	js_runtime_free(rt)


int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1):
		# Keep the guard-page allocator below the default kernel VMA cap.
		malloc_force_debug_mode()
		js_runtime* rt = js_runtime_new()
		js_runtime_bind(rt, c"twice", js_test_host)
		js_completion* result = js_test_eval(rt, c"const f = (function() { const o = {}; o.self = o; return function() { return o; }; })(); f();")
		assert_equal(0, result.status)
		js_runtime_root(rt, result.value)
		js_test_number(rt, c"twice(21);", 42.0)
		js_runtime_collect(rt)
		js_runtime_free(rt)
		assert_equal(0, debug_alloc_report_leaks())
		println(c"javascript_runtime_test: OK")
		return 0
	js_test_semantics()
	js_test_errors_and_limits()
	js_test_collection()
	println(c"javascript_runtime_test: OK")
	return 0
