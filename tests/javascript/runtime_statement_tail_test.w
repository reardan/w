# wbuild: name=javascript_runtime_statement_tail_test
# wbuild: target=javascript_runtime_statement_tail_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 --strict tests/javascript/runtime_statement_tail_test.w -o bin/javascript_runtime_statement_tail_test"
# wbuild: step="bin/javascript_runtime_statement_tail_test" expect_stdout="javascript_runtime_statement_tail_test: OK"
# wbuild: step="bin/javascript_runtime_statement_tail_test memory-semantics" expect_stdout="javascript_runtime_statement_tail_test: OK"
# wbuild: step="bin/javascript_runtime_statement_tail_test memory-depth" expect_stdout="javascript_runtime_statement_tail_test: OK"
# wbuild: step="bin/javascript_runtime_statement_tail_test memory-async" expect_stdout="javascript_runtime_statement_tail_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

js_completion* tail_eval(js_runtime* rt, char* source, int status):
	js_runtime_collect(rt)
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 20000)
	if (result.status != status):
		println(source)
		println(result.message)
	assert_equal(status, result.status)
	return result

void test_tail_semantics():
	js_runtime* rt = js_runtime_new()
	assert1(tail_eval(rt, c"let n=0;if(true)if(false)n=1;else n=2;n===2;", 0).value.number == 1.0)
	assert1(tail_eval(rt, c"if(true)true;", 0).value.number == 1.0)
	assert_equal(5, rt.completion.steps)
	assert_equal(0, tail_eval(rt, c"1;if(false)2;", 0).value.kind)
	assert_equal(5, rt.completion.steps)
	assert_equal(0, tail_eval(rt, c"1;if(true);", 0).value.kind)
	assert1(tail_eval(rt, c"let order='';function f(){try{if(true)return 7;}finally{order+='f';}}f()===7 && order==='f';", 0).value.number == 1.0)
	assert1(tail_eval(rt, c"let caught=0;try{if(true)throw 9;}catch(e){caught=e;}caught===9;", 0).value.number == 1.0)
	assert1(tail_eval(rt, c"let total=0;outer:for(let i=0;i<5;i++){if(i===1)continue;if(i===3)break outer;total+=i;}total===2;", 0).value.number == 1.0)
	js_runtime_free(rt)

void test_tail_depth():
	js_runtime* rt = js_runtime_new()
	rt.max_depth = 8
	string_builder* source = string_new()
	for i in range(30): string_append(source, c"if(true)")
	string_append(source, c"true;")
	assert1(tail_eval(rt, source.data, 0).value.number == 1.0)
	assert_equal(63, rt.completion.steps)
	assert_equal(5, js_runtime_eval(rt, source.data, source.length, 8).status)
	tail_eval(rt, c"function f(){if(true)return f();}f();", 5)
	string_free(source)
	js_runtime_free(rt)

void test_tail_async():
	js_runtime* rt = js_runtime_new()
	tail_eval(rt, c"let resolve;let p=new Promise(r=>{resolve=r;});let result=0;async function f(){if(await p)if(true)return 7;return 9;}f().then(v=>{result=v;});", 0)
	js_runtime_collect(rt)
	tail_eval(rt, c"resolve(true);", 0)
	assert_equal(0, js_runtime_drain_microtasks(rt, 20000).status)
	assert1(tail_eval(rt, c"result===7;", 0).value.number == 1.0)
	tail_eval(rt, c"let never=new Promise(()=>{});async function canceled(){if(await never)result=99;}canceled();", 0)
	js_runtime_collect(rt)
	js_runtime_async_cancel(rt)
	assert1(tail_eval(rt, c"result===7;", 0).value.number == 1.0)
	js_runtime_free(rt)

int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	if (argc == 1 || strcmp(args_get(1), c"memory-semantics") == 0): test_tail_semantics()
	if (argc == 1 || strcmp(args_get(1), c"memory-depth") == 0): test_tail_depth()
	if (argc == 1 || strcmp(args_get(1), c"memory-async") == 0): test_tail_async()
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_statement_tail_test: OK")
	return 0
