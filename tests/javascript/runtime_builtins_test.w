# wbuild: name=javascript_runtime_builtins_test
# wbuild: target=javascript_runtime_builtins_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 tests/javascript/runtime_builtins_test.w -o bin/javascript_runtime_builtins_test"
# wbuild: step="bin/javascript_runtime_builtins_test" expect_stdout="javascript_runtime_builtins_test: OK"
# wbuild: step="bin/javascript_runtime_builtins_test memory" expect_stdout="javascript_runtime_builtins_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime


void builtin_test_eval(js_runtime* rt, char* source):
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 10000)
	assert_equal(0, result.status)
	assert1(result.value.number == 1.0)


void test_builtin_scripts():
	js_runtime* rt = js_runtime_new()
	builtin_test_eval(rt, c"Math.round(1.5) === 2 && Math.round(-1.5) === -1 && 1 / Math.round(-0.5) === -Infinity && Math.round(0.49999999999999994) === 0;")
	builtin_test_eval(rt, c"Math.floor(-1.2) === -2 && Math.ceil(-1.2) === -1 && Math.trunc(-1.9) === -1 && 1 / Math.ceil(-0.1) === -Infinity && 1 / Math.trunc(-0.1) === -Infinity;")
	builtin_test_eval(rt, c"Math.round(4503599627370495.5) === 4503599627370496 && Math.floor(1e100) === 1e100 && Math.trunc(-Infinity) === -Infinity && Number.isNaN(Math.round(NaN));")
	builtin_test_eval(rt, c"Math.max() === -Infinity && Math.min() === Infinity && Math.max(-2,5,3) === 5 && Math.min(-2,5,3) === -2 && Number.isNaN(Math.max(1,NaN));")
	builtin_test_eval(rt, c"1 / Math.max(-0,0) === Infinity && 1 / Math.max(0,-0) === Infinity && 1 / Math.min(0,-0) === -Infinity && 1 / Math.min(-0,0) === -Infinity;")
	builtin_test_eval(rt, c"Math.abs(-3) === 3 && 1 / Math.abs(-0) === Infinity && Math.sign(-6) === -1 && 1 / Math.sign(-0) === -Infinity && Math.sqrt(9) === 3 && Number.isNaN(Math.sqrt(-1));")
	builtin_test_eval(rt, c"Math.hypot(3,4) === 5 && Math.hypot() === 0 && Math.hypot(NaN,Infinity) === Infinity && Number.isFinite(Math.hypot(1e300,1e300)) && Math.hypot(1e-300,0) === 1e-300;")
	builtin_test_eval(rt, c"Number.isInteger(3) && !Number.isInteger(3.1) && !Number.isInteger(Infinity) && !Number.isInteger('3') && !Number.isFinite(null) && !Number.isFinite(true) && !Number.isFinite('1') && Number.isFinite(1e300);")
	builtin_test_eval(rt, c"Number.isSafeInteger(9007199254740991) && !Number.isSafeInteger(9007199254740992) && !Number.isNaN('x') && Number.isNaN(NaN) && !Number.isInteger() && Math.fround(16777217) === 16777216;")
	builtin_test_eval(rt, c"Math.round(true) === 1 && Math.max(null,false,-1) === 0 && Number.isNaN(Math.round()) && Math.PI > 3.14 && Number.EPSILON > 0;")
	builtin_test_eval(rt, c"let stamp = Date.now(); Number.isInteger(stamp) && stamp > 1700000000000 && stamp < 9007199254740991;")
	# Exercise the actual bridge expressions with representative inputs.
	builtin_test_eval(rt, c"let ratio = 1.5; let x = 13; let requestedWidth = 900; let width = 640; Math.round(x * ratio) === 20 && Math.max(1,Math.floor(Math.min(requestedWidth,width))) === 640 && Number.isInteger(2147483647);")
	js_runtime_collect(rt)
	builtin_test_eval(rt, c"Math.round(2.5) === 3 && Number.isInteger(Date.now());")
	js_runtime_free(rt)


void test_builtin_host():
	js_runtime* rt = js_runtime_new()
	js_value* math = js_runtime_get(rt, rt.global, c"Math")
	js_value* rounder = js_runtime_get(rt, math, c"round")
	js_value* number = js_runtime_number(rt, -0.1)
	list[js_value*] args = new list[js_value*]
	args.push(number)
	assert_equal(0, js_runtime_invoke(rt, rounder, args, 10).status)
	assert_equal(1 << 63, float64_bits(rt.completion.value.number))
	# Active host calls charge arguments, independently of AST evaluation.
	assert_equal(5, js_runtime_invoke(rt, rounder, args, 1).status)
	assert_equal(0, js_runtime_invoke(rt, rounder, args, 10).status)
	int limit = rt.max_properties
	rt.max_properties = 0
	assert_equal(5, js_runtime_invoke(rt, rounder, args, 10).status)
	rt.max_properties = limit
	js_runtime_begin(rt, 100)
	js_text* pi_key = js_runtime_key(c"PI")
	assert_equal(0, js_runtime_member_write(rt, math, pi_key, number))
	js_text_free(pi_key)
	# Truncation handles subnormal numbers without losing zero's sign.
	assert_equal(0, float64_bits(js_builtin_trunc(float64_from_bits(1))))
	assert_equal(1 << 63, float64_bits(js_builtin_trunc(float64_from_bits((1 << 63) | 1))))
	assert1(js_builtin_sqrt(float64_from_bits(1)) > 0.0)
	js_runtime_root(rt, rounder)
	js_runtime_collect(rt)
	args[0] = js_runtime_number(rt, 8.5)
	assert_equal(0, js_runtime_invoke(rt, rounder, args, 10).status)
	assert1(rt.completion.value.number == 9.0)
	js_runtime_unroot(rt, rounder)
	__w_list_free(cast(__w_list*, args))
	js_runtime_free(rt)


int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	if (argc == 1): test_builtin_scripts()
	test_builtin_host()
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_builtins_test: OK")
	return 0
