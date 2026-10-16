# wbuild: name=javascript_runtime_numeric_coercion_test
# wbuild: target=javascript_runtime_numeric_coercion_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 --strict tests/javascript/runtime_numeric_coercion_test.w -o bin/javascript_runtime_numeric_coercion_test"
# wbuild: step="bin/javascript_runtime_numeric_coercion_test" expect_stdout="javascript_runtime_numeric_coercion_test: OK"
# wbuild: step="bin/javascript_runtime_numeric_coercion_test memory-values" expect_stdout="javascript_runtime_numeric_coercion_test: OK"
# wbuild: step="bin/javascript_runtime_numeric_coercion_test memory-order" expect_stdout="javascript_runtime_numeric_coercion_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

void numeric_eval(js_runtime* rt, char* source, int status):
	js_runtime_collect(rt)
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 20000)
	if (result.status != status || (status == 0 && result.value.number != 1.0)):
		println(source)
		println(result.message)
	assert_equal(status, result.status)
	if (status == 0): assert1(result.value.number == 1.0)

void test_numeric_values():
	js_runtime* rt = js_runtime_new()
	numeric_eval(rt, c"(128&undefined)===0 && (undefined|4)===4 && (true^3)===2 && (null|1)===1;", 0)
	numeric_eval(rt, c"('0xff'&15)===15 && (' 3.9 '|0)===3 && ('bad'|7)===7 && ('0b101'^true)===4;", 0)
	numeric_eval(rt, c"('4'<<'2')===16 && ('-8'>>1)===-4 && ('-1'>>>0)===4294967295 && (1<<33)===2;", 0)
	numeric_eval(rt, c"(1<<undefined)===1 && (null>>true)===0 && ~undefined===-1 && ~'3'===-4 && ~false===-1;", 0)
	numeric_eval(rt, c"(Infinity|0)===0 && (NaN&1)===0 && (4294967295|0)===-1 && (4294967296|0)===0;", 0)
	numeric_eval(rt, c"let flags;flags|=128;flags&='255';flags===128;", 0)
	numeric_eval(rt, c"1n&1;", 2)
	numeric_eval(rt, c"1n>>>1n;", 2)
	numeric_eval(rt, c"1n&1n;", 6)
	numeric_eval(rt, c"~1n;", 6)
	js_runtime_free(rt)

void test_numeric_order():
	js_runtime* rt = js_runtime_new()
	numeric_eval(rt, c"let order='';let a={valueOf:function(){order+='a';return '7';}};true;", 0)
	numeric_eval(rt, c"let b={valueOf:function(){order+='b';return 3;}};(a&b)===3 && order==='ab';", 0)
	numeric_eval(rt, c"let fallback={valueOf:function(){return this;},toString:function(){return '2';}};(fallback<<2)===8 && ~fallback===-3;", 0)
	numeric_eval(rt, c"let count=0;let bad={valueOf:function(){throw 4;}};let later={valueOf:function(){count++;return 1;}};true;", 0)
	numeric_eval(rt, c"let caught=0;try{bad|later;}catch(e){caught=e;}caught===4 && count===0;", 0)
	numeric_eval(rt, c"let big={valueOf:function(){return 1n;}};let thrown=0;true;", 0)
	numeric_eval(rt, c"try{big&bad;}catch(e){thrown=e;}thrown===4;", 0)
	numeric_eval(rt, c"({})|1;", 6)
	numeric_eval(rt, c"let recursive={valueOf:function(){return recursive|0;}};true;", 0)
	rt.max_depth = 20
	numeric_eval(rt, c"recursive|0;", 5)
	rt.max_depth = 256
	char* source = c"a|b;"
	assert_equal(5, js_runtime_eval(rt, source, strlen(source), 5).status)
	js_runtime_free(rt)

int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	if (argc == 1 || strcmp(args_get(1), c"memory-values") == 0): test_numeric_values()
	if (argc == 1 || strcmp(args_get(1), c"memory-order") == 0): test_numeric_order()
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_numeric_coercion_test: OK")
	return 0
