# wbuild: name=javascript_runtime_string_substring_test
# wbuild: target=javascript_runtime_string_substring_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 tests/javascript/runtime_string_substring_test.w -o bin/javascript_runtime_string_substring_test"
# wbuild: step="bin/javascript_runtime_string_substring_test" expect_stdout="javascript_runtime_string_substring_test: OK"
# wbuild: step="bin/javascript_runtime_string_substring_test memory" expect_stdout="javascript_runtime_string_substring_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

void substring_eval(js_runtime* rt, char* source):
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
	substring_eval(rt, c"'abc'.substring()==='abc' && 'abc'.substring(1)==='bc' && 'abc'.substring(2,0)==='ab' && 'abc'.substring(1,1)==='' && 'abc'.substring(1,undefined)==='bc' && 'abc'.substring(1,null)==='a';")
	substring_eval(rt, c"'abc'.substring(-Infinity,Infinity)==='abc' && 'abc'.substring(Infinity,-Infinity)==='abc' && 'abc'.substring(-1,-2)==='' && 'abc'.substring(99,100)==='' && 'abc'.substring(NaN,2)==='ab' && 'abc'.substring(2,NaN)==='ab';")
	substring_eval(rt, c"'abc'.substring(0.9,2.9)==='ab' && 'abc'.substring(-0.9,1.9)==='a' && 'abc'.substring(true,'3')==='bc' && 'abc'.substring(false,true)==='a';")
	substring_eval(rt, c"let utf=String.fromCharCode(0,55296,56320,65535);utf.substring(0,1)===String.fromCharCode(0) && utf.substring(1,2)===String.fromCharCode(55296) && utf.substring(2,3)===String.fromCharCode(56320) && utf.substring(4,1)===String.fromCharCode(55296,56320,65535);")
	substring_eval(rt, c"String.prototype.substring.call(123,1,3)==='23' && String.prototype.substring.call(true,1)==='rue' && String.prototype.substring.call(Object('abc'),1,2)==='b' && String.prototype.substring.call(123n,1)==='23';")
	substring_eval(rt, c"let order='';let receiver={toString:function(){order+='r';return 'abcdef';}};let start={valueOf:function(){order+='s';return 4;}};let end={valueOf:function(){order+='e';return 1;}};String.prototype.substring.call(receiver,start,end)==='bcd' && order==='rse';")
	substring_eval(rt, c"order='';let count=0;try{String.prototype.substring.call(null,start,end);}catch(e){count=e.constructor===TypeError;}count===true && order==='';")
	substring_eval(rt, c"order='';count=0;try{String.prototype.substring.call({toString:function(){order+='r';throw 17;}},start,end);}catch(e){count=e;}count===17 && order==='r';")
	substring_eval(rt, c"order='';count=0;try{String.prototype.substring.call(receiver,{valueOf:function(){order+='s';throw 18;}},end);}catch(e){count=e;}count===18 && order==='rs';")
	substring_eval(rt, c"order='';count=0;try{''.substring(start,{valueOf:function(){order+='e';throw 19;}});}catch(e){count=e;}count===19 && order==='se';")
	substring_eval(rt, c"count=0;try{'abc'.substring(1n);}catch(e){if(e.constructor===TypeError)count++;}try{'abc'.substring(0,1n);}catch(e){if(e.constructor===TypeError)count++;}count===2;")
	substring_eval(rt, c"let method=String.prototype.substring;let descriptor=Object.getOwnPropertyDescriptor(String.prototype,'substring');method.name==='substring' && method.length===2 && Object.getOwnPropertyDescriptor(method,'prototype')===undefined && descriptor.writable && !descriptor.enumerable && descriptor.configurable;")
	js_value* method = js_runtime_get(rt, rt.global, c"method")
	assert1(js_runtime_root(rt, method))
	js_value* text = js_runtime_string_value(rt, c"abcdefgh")
	assert1(js_runtime_root(rt, text))
	list[js_value*] arguments = new list[js_value*]
	js_runtime_begin(rt, 7)
	js_runtime_call_receiver(rt, method, text, arguments)
	assert_equal(5, rt.completion.status)
	js_runtime_begin(rt, 8)
	js_value* result = js_runtime_call_receiver(rt, method, text, arguments)
	assert_equal(0, rt.completion.status)
	assert_equal(0, rt.remaining)
	assert_equal(8, result.text.units.length)
	js_runtime_begin(rt, 1000)
	rt.max_properties = 4
	js_runtime_call_receiver(rt, method, text, arguments)
	assert_equal(5, rt.completion.status)
	rt.max_properties = 10000
	js_runtime* foreign = js_runtime_new()
	js_runtime_begin(rt, 1000)
	arguments.push(foreign.undefined_value)
	js_runtime_call_receiver(rt, method, text, arguments)
	assert_equal(2, rt.completion.status)
	js_runtime_begin(rt, 1000)
	arguments.clear()
	js_runtime_call_receiver(rt, method, foreign.undefined_value, arguments)
	assert_equal(2, rt.completion.status)
	js_runtime_free(foreign)
	__w_list_free(cast(__w_list*, arguments))
	js_runtime_free(rt)
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_string_substring_test: OK")
	return 0
