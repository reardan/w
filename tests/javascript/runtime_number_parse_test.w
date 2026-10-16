# wbuild: name=javascript_runtime_number_parse_test
# wbuild: target=javascript_runtime_number_parse_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 tests/javascript/runtime_number_parse_test.w -o bin/javascript_runtime_number_parse_test"
# wbuild: step="bin/javascript_runtime_number_parse_test" expect_stdout="javascript_runtime_number_parse_test: OK"
# wbuild: step="bin/javascript_runtime_number_parse_test memory" expect_stdout="javascript_runtime_number_parse_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime
import libs.extras.javascript.runtime_number_parse

void number_parse_expect(js_runtime* rt, char* source):
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 100000)
	if (result.status != 0): println(result.message)
	assert_equal(0, result.status)
	assert1(js_runtime_truth(result.value))

int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1):
		malloc_force_debug_mode()
		js_runtime* checked = js_runtime_new()
		js_runtime_begin(checked, 10000)
		checked.running = 1
		for i in range(20):
			js_text* input = js_runtime_key(c" \t-12.5e2px")
			assert1(js_number_parse_float(checked, input) == -1250.0)
			js_text_free(input)
		checked.running = 0
		js_runtime_free(checked)
		assert_equal(0, debug_alloc_report_leaks())
		println(c"javascript_runtime_number_parse_test: OK")
		return 0
	js_runtime* rt = js_runtime_new()
	number_parse_expect(rt, c"parseFloat===Number.parseFloat && parseFloat('12.5px')===12.5 && parseFloat('-.5em')===-0.5 && parseFloat('1e+2tail')===100;")
	number_parse_expect(rt, c"parseFloat('1e+')===1 && parseFloat('2.5e-')===2.5 && parseFloat('0x10')===0 && parseFloat('1_000')===1 && parseFloat('.25.7')===0.25;")
	number_parse_expect(rt, c"Number.isNaN(parseFloat()) && Number.isNaN(parseFloat('')) && Number.isNaN(parseFloat('.')) && Number.isNaN(parseFloat('+')) && Number.isNaN(parseFloat('infinity')) && Number.isNaN(parseFloat('Inf')) && Number.isNaN(parseFloat('Infinity'.slice(0,7)));")
	number_parse_expect(rt, c"parseFloat('Infinityx')===Number.POSITIVE_INFINITY && parseFloat('-Infinity')===Number.NEGATIVE_INFINITY && parseFloat('+Infinity')===Number.POSITIVE_INFINITY && 1/parseFloat('-0px')===Number.NEGATIVE_INFINITY;")
	number_parse_expect(rt, c"parseFloat('\\uFEFF\\u00a0\\u2000\\u2028\\u2029\\u3000 42px')===42 && Number.isNaN(parseFloat('\\u008542')) && parseFloat('12\\u000034')===12 && Number.isNaN(parseFloat('\\u000012')) && parseFloat('8😀')===8;")
	number_parse_expect(rt, c"parseFloat('1e309')===Number.POSITIVE_INFINITY && 1/parseFloat('-1e-999')===Number.NEGATIVE_INFINITY && parseFloat('5e-324')===5e-324 && parseFloat('9007199254740993')===9007199254740992;")
	number_parse_expect(rt, c"parseFloat(12.5)===12.5 && parseFloat(100n)===100 && Number.isNaN(parseFloat(null)) && Number.isNaN(parseFloat(true));")
	number_parse_expect(rt, c"let order=''; const object={toString(){order+='s';return {};},valueOf(){order+='v';return '14px';}}; parseFloat(object)===14 && order==='sv';")
	number_parse_expect(rt, c"let reason={}; let caught=false; try{parseFloat({toString(){throw reason;}});}catch(e){caught=e===reason;} caught;")
	js_text* expensive = js_runtime_key(c"                   5")
	js_runtime_begin(rt, 5)
	rt.running = 1
	js_number_parse_float(rt, expensive)
	rt.running = 0
	assert_equal(5, rt.completion.status)
	js_text_free(expensive)
	js_runtime_free(rt)
	println(c"javascript_runtime_number_parse_test: OK")
	return 0
