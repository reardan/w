# wbuild: name=javascript_runtime_numeric_keys_test
# wbuild: target=javascript_runtime_numeric_keys_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 --strict tests/javascript/runtime_numeric_keys_test.w -o bin/javascript_runtime_numeric_keys_test"
# wbuild: step="bin/javascript_runtime_numeric_keys_test" expect_stdout="javascript_runtime_numeric_keys_test: OK"
# wbuild: step="bin/javascript_runtime_numeric_keys_test memory" expect_stdout="javascript_runtime_numeric_keys_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

void numeric_keys_eval(js_runtime* rt, char* source):
	js_runtime_collect(rt)
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 100000)
	if (result.status != 0 || result.value.number != 1.0):
		println(source)
		println(result.message)
	assert_equal(0, result.status)
	assert1(result.value.number == 1.0)

int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	js_runtime* rt = js_runtime_new()
	numeric_keys_eval(rt, c"let statuses={0:'Pass',1:'Fail',2:'Timeout'};statuses[0]==='Pass' && statuses[2]==='Timeout';")
	numeric_keys_eval(rt, c"let normalized={1.0:1,1e0:2,0x1:3,0b1:4,0o1:5};normalized['1']===5 && Object.keys(normalized).length===1;")
	numeric_keys_eval(rt, c"let numbers={1e21:1,1e20:2,0.000001:3,0.0000001:4,9007199254740993:5};numbers['1e+21']===1 && numbers['100000000000000000000']===2 && numbers['0.000001']===3 && numbers['1e-7']===4 && numbers['9007199254740992']===5;")
	numeric_keys_eval(rt, c"let order='';let duplicate={1:(order+='a'),1.0:(order+='b')};order==='ab' && duplicate[1]==='ab';")
	numeric_keys_eval(rt, c"let invoked=0;Object.defineProperty(Object.prototype,'7',{set:function(){invoked++;},configurable:true});let own={7:4};let ok=own[7]===4 && invoked===0;delete Object.prototype[7];ok;")
	numeric_keys_eval(rt, c"let methods={1.0(){return 7;}};methods[1]()===7;")
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	char* printed = js_print(rt.scripts[rt.scripts.length - 1], diagnostics)
	assert1(printed != 0)
	assert_equal(0, diagnostics.items.length)
	js_runtime* copy = js_runtime_new()
	numeric_keys_eval(copy, printed)
	js_runtime_free(copy)
	free(printed)
	pg_diagnostics_free(diagnostics)
	js_runtime_free(rt)
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_numeric_keys_test: OK")
	return 0
