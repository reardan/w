# wbuild: name=javascript_runtime_remainder_test
# wbuild: target=javascript_runtime_remainder_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 --strict tests/javascript/runtime_remainder_test.w -o bin/javascript_runtime_remainder_test"
# wbuild: step="bin/javascript_runtime_remainder_test" expect_stdout="javascript_runtime_remainder_test: OK"
# wbuild: step="bin/javascript_runtime_remainder_test memory" expect_stdout="javascript_runtime_remainder_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

void remainder_eval(js_runtime* rt, char* source, int status):
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
	remainder_eval(rt, c"5%2===1 && -5%2===-1 && 5%-2===1 && -5%-2===-1 && 5.5%2===1.5;", 0)
	remainder_eval(rt, c"Object.is(-4%2,-0) && Object.is(-0%3,-0) && Object.is(0%-3,0) && Object.is(-0%Infinity,-0) && 7%Infinity===7;", 0)
	remainder_eval(rt, c"Number.isNaN(Infinity%2) && Number.isNaN(2%0) && Number.isNaN(2%-0) && Number.isNaN(NaN%2) && Number.isNaN(2%NaN);", 0)
	remainder_eval(rt, c"1e308%3===2 && 1.7976931348623157e308%3===2 && 5e-324%1e-323===5e-324 && 1e-323%5e-324===0 && 1%5e-324===0;", 0)
	remainder_eval(rt, c"'7'%true===0 && null%3===0 && Number.isNaN(undefined%3) && Object(7)%Object(4)===3;", 0)
	remainder_eval(rt, c"let order='';let left={valueOf:function(){order+='l';return 7;}};let right={valueOf:function(){order+='r';return 4;}};left%right===3 && order==='lr';", 0)
	remainder_eval(rt, c"let value=7;value%=4;value===3;", 0)
	remainder_eval(rt, c"5n%2n===1n && -5n%2n===-1n && 5n%-2n===1n && 18446744073709551615n%3n===0n && -9223372036854775808n%-1n===0n;", 0)
	remainder_eval(rt, c"let mixed=0;try{1n%2;}catch(e){mixed=e.constructor===TypeError;}mixed;", 0)
	remainder_eval(rt, c"let zero=0;try{1n%0n;}catch(e){zero=e.constructor===RangeError;}zero;", 0)
	remainder_eval(rt, c"let abrupt=0;try{1%{valueOf:function(){throw 71;}};}catch(e){abrupt=e;}abrupt===71;", 0)
	char* source = c"1.7976931348623157e308%7e-324;"
	assert_equal(5, js_runtime_eval(rt, source, strlen(source), 10).status)
	js_runtime_free(rt)
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_remainder_test: OK")
	return 0
