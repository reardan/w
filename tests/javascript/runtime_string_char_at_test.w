# wbuild: name=javascript_runtime_string_char_at_test
# wbuild: target=javascript_runtime_string_char_at_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 --strict tests/javascript/runtime_string_char_at_test.w -o bin/javascript_runtime_string_char_at_test"
# wbuild: step="bin/javascript_runtime_string_char_at_test" expect_stdout="javascript_runtime_string_char_at_test: OK"
# wbuild: step="bin/javascript_runtime_string_char_at_test memory" expect_stdout="javascript_runtime_string_char_at_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

void char_at_eval(js_runtime* rt, char* source):
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
	char_at_eval(rt, c"'abc'.charAt()==='a' && 'abc'.charAt(1)==='b' && 'abc'.charAt(2)==='c' && 'abc'.charAt(-0.9)==='a' && 'abc'.charAt(1.9)==='b';")
	char_at_eval(rt, c"'abc'.charAt(NaN)==='a' && 'abc'.charAt(undefined)==='a' && 'abc'.charAt(null)==='a' && 'abc'.charAt(false)==='a' && 'abc'.charAt(true)==='b' && 'abc'.charAt('2')==='c';")
	char_at_eval(rt, c"''.charAt()==='' && 'abc'.charAt(-1)==='' && 'abc'.charAt(3)==='' && 'abc'.charAt(Infinity)==='' && 'abc'.charAt(-Infinity)==='' && 'abc'.charAt(1e100)==='';")
	char_at_eval(rt, c"let pair=String.fromCharCode(55296,56320,0,65535);pair.charAt(0)===String.fromCharCode(55296) && pair.charAt(1)===String.fromCharCode(56320) && pair.charAt(2)===String.fromCharCode(0) && pair.charAt(3)===String.fromCharCode(65535) && pair.charAt(0).length===1;")
	char_at_eval(rt, c"String.prototype.charAt.call(123,1)==='2' && String.prototype.charAt.call(true,0)==='t' && String.prototype.charAt.call(Object('az'),1)==='z' && String.prototype.charAt.call(123n,2)==='3';")
	char_at_eval(rt, c"let order='';let receiver={toString:function(){order+='s';return 'ab';}};let index={valueOf:function(){order+='i';return 1;}};String.prototype.charAt.call(receiver,index)==='b' && order==='si';")
	char_at_eval(rt, c"order='';let error=0;try{String.prototype.charAt.call(null,index);}catch(e){error=e.constructor===TypeError;}error===true && order==='';")
	char_at_eval(rt, c"order='';error=0;try{String.prototype.charAt.call({toString:function(){order+='s';throw 17;}},index);}catch(e){error=e;}error===17 && order==='s';")
	char_at_eval(rt, c"error=0;try{''.charAt({valueOf:function(){throw 23;}});}catch(e){error=e;}error===23;")
	char_at_eval(rt, c"error=0;try{'abc'.charAt(1n);}catch(e){error=e.constructor===TypeError;}error===true;")
	char_at_eval(rt, c"let method=String.prototype.charAt;let descriptor=Object.getOwnPropertyDescriptor(String.prototype,'charAt');method.length===1 && method.name==='charAt' && !Object.hasOwn(method,'prototype') && descriptor.writable && !descriptor.enumerable && descriptor.configurable;")
	char_at_eval(rt, c"error=0;try{new method();}catch(e){error=e.constructor===TypeError;}error===true;")
	char_at_eval(rt, c"String.prototype.charAt=undefined;method.call('abc',1)==='b';")
	char_at_eval(rt, c"method.call('xy',0)==='x';")
	js_value* method = js_runtime_get(rt, rt.global, c"method")
	js_runtime* foreign = js_runtime_new()
	list[js_value*] arguments = new list[js_value*]
	js_runtime_call_receiver(rt, method, foreign.undefined_value, arguments)
	assert_equal(2, rt.completion.status)
	js_runtime_begin(rt, 1000)
	arguments.push(foreign.undefined_value)
	js_runtime_call_receiver(rt, method, js_class_string(rt, c"abc"), arguments)
	assert_equal(2, rt.completion.status)
	arguments.clear()
	js_runtime_begin(rt, 1000)
	js_value* owned_receiver = js_class_string(rt, c"abc")
	rt.max_values = rt.heap.length
	js_runtime_call_receiver(rt, method, owned_receiver, arguments)
	assert_equal(5, rt.completion.status)
	__w_list_free(cast(__w_list*, arguments))
	js_runtime_free(foreign)
	js_runtime_free(rt)
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_string_char_at_test: OK")
	return 0
