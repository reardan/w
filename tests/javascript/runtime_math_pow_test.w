# wbuild: name=javascript_runtime_math_pow_test
# wbuild: target=javascript_runtime_math_pow_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 --strict tests/javascript/runtime_math_pow_test.w -o bin/javascript_runtime_math_pow_test"
# wbuild: step="bin/javascript_runtime_math_pow_test" expect_stdout="javascript_runtime_math_pow_test: OK"
# wbuild: step="bin/javascript_runtime_math_pow_test memory" expect_stdout="javascript_runtime_math_pow_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

void math_pow_eval(js_runtime* rt, char* source, int status):
	js_runtime_collect(rt)
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 100000)
	if (result.status != status || (status == 0 && result.value.number != 1.0)):
		println(source)
		println(result.message)
	assert_equal(status, result.status)
	if (status == 0): assert1(result.value.number == 1.0)

int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	js_runtime* rt = js_runtime_new()
	math_pow_eval(rt, c"Math.pow(2,32)===4294967296 && Math.pow(-2,3)===-8 && Math.pow(4,0.5)===2 && Math.pow.length===2;", 0)
	math_pow_eval(rt, c"Object.is(Math.pow(-0,3),-0) && Object.is(Math.pow(-0,2),0) && Math.pow(-0,-3)===-Infinity && Math.pow(-Infinity,-3)===-0;", 0)
	math_pow_eval(rt, c"Number.isNaN(Math.pow(1,NaN)) && Number.isNaN(Math.pow(1,Infinity)) && Number.isNaN(Math.pow(-1,-Infinity)) && Number.isNaN(Math.pow(-2,0.5)) && Math.pow(NaN,0)===1;", 0)
	math_pow_eval(rt, c"let order='';let base={valueOf:function(){order+='b';return NaN;}};let exponent={valueOf:function(){order+='e';return 0;}};Math.pow(base,exponent)===1 && order==='be';", 0)
	math_pow_eval(rt, c"let thrown=0;try{Math.pow(2,{valueOf:function(){throw 71;}});}catch(e){thrown=e;}thrown===71;", 0)
	math_pow_eval(rt, c"let bigint=0;try{Math.pow(1n,2);}catch(e){bigint=e.constructor===TypeError;}bigint;", 0)
	math_pow_eval(rt, c"Math.pow(2,2,{valueOf:function(){throw 5;}})===4 && Math.pow('3','2')===9 && Math.pow(true,null)===1 && Number.isNaN(Math.pow()) && Object.getOwnPropertyDescriptor(Math,'pow').enumerable===false && Math.pow.name==='pow';", 0)
	math_pow_eval(rt, c"Math.pow(2,{valueOf:function(){return 3;}})===8 && typeof Math.pow(2,0.5)==='number';", 0)
	char* bounded = c"Math.pow(2,3);"
	js_completion* limited = js_runtime_eval(rt, bounded, strlen(bounded), 2)
	assert_equal(5, limited.status)
	js_runtime_free(rt)
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_math_pow_test: OK")
	return 0
