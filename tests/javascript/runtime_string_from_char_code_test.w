# wbuild: name=javascript_runtime_string_from_char_code_test
# wbuild: target=javascript_runtime_string_from_char_code_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 tests/javascript/runtime_string_from_char_code_test.w -o bin/javascript_runtime_string_from_char_code_test"
# wbuild: step="bin/javascript_runtime_string_from_char_code_test" expect_stdout="javascript_runtime_string_from_char_code_test: OK"
# wbuild: step="bin/javascript_runtime_string_from_char_code_test memory" expect_stdout="javascript_runtime_string_from_char_code_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

void from_char_code_eval(js_runtime* rt, char* source):
	js_runtime_collect(rt)
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 100000)
	if (result.status != 0 || js_runtime_truth(result.value) == 0):
		println(source)
		println(result.message)
	assert_equal(0, result.status)
	assert1(js_runtime_truth(result.value))

int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	js_runtime* rt = js_runtime_new()
	from_char_code_eval(rt, c"String.fromCharCode()==='' && String.fromCharCode(65,66)==='AB' && String.fromCharCode.length===1 && String.fromCharCode.name==='fromCharCode';")
	from_char_code_eval(rt, c"String.fromCharCode(65537,-65535,1.9)===String.fromCharCode(1,1,1) && String.fromCharCode(-1,-1.9)===String.fromCharCode(65535,65535);")
	from_char_code_eval(rt, c"String.fromCharCode(NaN,Infinity,-Infinity,undefined,null,-0)===String.fromCharCode(0,0,0,0,0,0);")
	from_char_code_eval(rt, c"String.fromCharCode(55296).length===1 && String.fromCharCode(55296,56320).length===2 && String.fromCharCode(0).length===1;")
	from_char_code_eval(rt, c"String.fromCharCode(9007199254740991)===String.fromCharCode(65535) && String.fromCharCode(1.7976931348623157e308)===String.fromCharCode(0);")
	from_char_code_eval(rt, c"String.fromCharCode('66',true)==='B\\u0001' && String.fromCharCode(new Number(67))==='C';")
	from_char_code_eval(rt, c"let order='';let a={valueOf:function(){order+='a';return 65;}};let b={valueOf:function(){order+='b';return 66;}};String.fromCharCode(a,b)==='AB' && order==='ab';")
	from_char_code_eval(rt, c"let reads='';let caught=0;try{String.fromCharCode({valueOf:function(){reads+='a';throw 12;}},{valueOf:function(){reads+='b';return 1;}});}catch(e){caught=e;}caught===12 && reads==='a';")
	from_char_code_eval(rt, c"let big=0;try{String.fromCharCode(1n);}catch(e){big=e.constructor===TypeError;}big;")
	from_char_code_eval(rt, c"let sym=0;try{String.fromCharCode(Symbol());}catch(e){sym=e.constructor===TypeError;}sym;")
	from_char_code_eval(rt, c"let descriptor=Object.getOwnPropertyDescriptor(String,'fromCharCode');descriptor.writable && !descriptor.enumerable && descriptor.configurable && Object.getOwnPropertyDescriptor(String.fromCharCode,'prototype')===undefined;")
	# Budget: every argument and every produced unit is charged.
	js_value* function = js_runtime_get(rt, rt.string_constructor, c"fromCharCode")
	list[js_value*] arguments = new list[js_value*]
	for i in range(8): arguments.push(js_runtime_number(rt, 65.0))
	js_runtime_begin(rt, 3)
	js_runtime_call_receiver(rt, function, rt.string_constructor, arguments)
	assert_equal(5, rt.completion.status)
	js_runtime_begin(rt, 1000)
	js_value* result = js_runtime_call_receiver(rt, function, rt.string_constructor, arguments)
	assert_equal(0, rt.completion.status)
	assert_equal(8, result.text.units.length)
	rt.max_properties = 4
	js_runtime_begin(rt, 1000)
	js_runtime_call_receiver(rt, function, rt.string_constructor, arguments)
	assert_equal(5, rt.completion.status)
	rt.max_properties = 10000
	js_runtime* foreign = js_runtime_new()
	js_runtime_begin(rt, 1000)
	arguments.clear()
	arguments.push(foreign.undefined_value)
	js_runtime_call_receiver(rt, function, rt.string_constructor, arguments)
	assert_equal(2, rt.completion.status)
	js_runtime_free(foreign)
	__w_list_free(cast(__w_list*, arguments))
	js_runtime_free(rt)
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_string_from_char_code_test: OK")
	return 0
