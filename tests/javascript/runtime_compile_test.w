# wbuild: name=javascript_runtime_compile_test
# wbuild: target=javascript_runtime_compile_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 tests/javascript/runtime_compile_test.w -o bin/javascript_runtime_compile_test"
# wbuild: step="bin/javascript_runtime_compile_test" expect_stdout="javascript_runtime_compile_test: OK"
# wbuild: step="bin/javascript_runtime_compile_test memory" expect_stdout="javascript_runtime_compile_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime


js_value* compile_test_host(void* runtime, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	char* source = c"(function(event){return this.x + event + retained;})"
	if (args.length > 0):
		if (args[0].number == 1.0): source = c"retained = 900; function bad(){}"
		if (args[0].number == 2.0): source = c"(function(){while(true){}})"
		if (args[0].number == 3.0): source = c"(function("
	int remaining = rt.remaining
	int depth = rt.depth
	js_runtime_label* label = rt.label
	js_value* function = js_runtime_compile_function(rt, source, strlen(source))
	assert_equal(1, rt.running)
	assert_equal(depth, rt.depth)
	assert1(label == rt.label)
	assert1(rt.remaining <= remaining && rt.remaining >= remaining - 1)
	return function


void compile_test_eval(js_runtime* rt, char* source, int status):
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 10000)
	assert_equal(status, result.status)
	if (status == 0): assert1(result.value.number == 1.0)


int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	js_runtime* rt = js_runtime_new()
	js_runtime_bind(rt, c"compileHandler", compile_test_host)
	compile_test_eval(rt, c"let retained=3; let object={x:4, fn:compileHandler()}; object.fn(5)===12;", 0)
	js_runtime_collect(rt)
	compile_test_eval(rt, c"object.fn(5)===12 && String(42)==='42' && String()==='' && String(undefined)==='undefined' && String(null)==='null' && String(true)==='true' && String(9007199254740993n)==='9007199254740993';", 0)
	compile_test_eval(rt, c"compileHandler(1);", 6)
	compile_test_eval(rt, c"retained===3;", 0)
	compile_test_eval(rt, c"compileHandler(3);", 6)
	compile_test_eval(rt, c"compileHandler(2)();", 5)
	rt.max_scripts = rt.scripts.length + 1
	compile_test_eval(rt, c"compileHandler();", 5)
	js_runtime_free(rt)
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_compile_test: OK")
	return 0
