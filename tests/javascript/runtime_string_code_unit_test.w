# wbuild: name=javascript_runtime_string_code_unit_test
# wbuild: target=javascript_runtime_string_code_unit_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 tests/javascript/runtime_string_code_unit_test.w -o bin/javascript_runtime_string_code_unit_test"
# wbuild: step="bin/javascript_runtime_string_code_unit_test" expect_stdout="javascript_runtime_string_code_unit_test: OK"
# wbuild: step="bin/javascript_runtime_string_code_unit_test memory" expect_stdout="javascript_runtime_string_code_unit_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

void code_unit_eval(js_runtime* rt, char* source):
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
	code_unit_eval(rt, c"'abc'.charCodeAt()===97 && 'abc'.charCodeAt(1)===98 && 'abc'.charCodeAt(2)===99 && 'abc'.charCodeAt(-0.9)===97 && 'abc'.charCodeAt(1.9)===98;")
	code_unit_eval(rt, c"'abc'.charCodeAt(NaN)===97 && 'abc'.charCodeAt(undefined)===97 && 'abc'.charCodeAt(null)===97 && 'abc'.charCodeAt(false)===97 && 'abc'.charCodeAt(true)===98 && 'abc'.charCodeAt('2')===99;")
	code_unit_eval(rt, c"isNaN(''.charCodeAt()) && isNaN('abc'.charCodeAt(-1)) && isNaN('abc'.charCodeAt(3)) && isNaN('abc'.charCodeAt(Infinity)) && isNaN('abc'.charCodeAt(-Infinity)) && isNaN('abc'.charCodeAt(1e100));")
	code_unit_eval(rt, c"let pair=String.fromCharCode(55296,56320,0,65535);pair.charCodeAt(0)===55296 && pair.charCodeAt(1)===56320 && pair.charCodeAt(2)===0 && pair.charCodeAt(3)===65535;")
	code_unit_eval(rt, c"String.prototype.charCodeAt.call(123,1)===50 && String.prototype.charCodeAt.call(true,0)===116 && String.prototype.charCodeAt.call(Object('az'),1)===122;")
	code_unit_eval(rt, c"let order='';let receiver={toString:function(){order+='s';return 'ab';}};let index={valueOf:function(){order+='i';return 1;}};String.prototype.charCodeAt.call(receiver,index)===98 && order==='si';")
	code_unit_eval(rt, c"order='';let error=0;try{String.prototype.charCodeAt.call(null,index);}catch(e){error=e.constructor===TypeError;}error===true && order==='';")
	code_unit_eval(rt, c"order='';error=0;try{String.prototype.charCodeAt.call({toString:function(){order+='s';throw 17;}},index);}catch(e){error=e;}error===17 && order==='s';")
	code_unit_eval(rt, c"error=0;try{'abc'.charCodeAt({valueOf:function(){throw 23;}});}catch(e){error=e;}error===23;")
	code_unit_eval(rt, c"error=0;try{'abc'.charCodeAt(1n);}catch(e){error=e.constructor===TypeError;}error===true;")
	code_unit_eval(rt, c"let method=String.prototype.charCodeAt;let descriptor=Object.getOwnPropertyDescriptor(String.prototype,'charCodeAt');method.length===1 && method.name==='charCodeAt' && Object.getOwnPropertyDescriptor(method,'prototype')===undefined && descriptor.writable && !descriptor.enumerable && descriptor.configurable;")
	# Budget: arguments are charged against the active evaluation budget.
	js_value* char_code_at = js_runtime_get(rt, rt.string_prototype, c"charCodeAt")
	js_value* char_at = js_runtime_get(rt, rt.string_prototype, c"charAt")
	js_value* subject = js_runtime_string_value(rt, c"abc")
	assert1(js_runtime_root(rt, subject))
	list[js_value*] charge = new list[js_value*]
	for i in range(3): charge.push(js_runtime_number(rt, 1.0))
	js_runtime_begin(rt, 2)
	rt.running = 1
	js_runtime_call_receiver(rt, char_code_at, subject, charge)
	assert_equal(5, rt.completion.status)
	rt.running = 0
	js_runtime_begin(rt, 2)
	rt.running = 1
	js_runtime_call_receiver(rt, char_at, subject, charge)
	assert_equal(5, rt.completion.status)
	rt.running = 0
	js_runtime_begin(rt, 3)
	rt.running = 1
	js_value* code = js_runtime_call_receiver(rt, char_code_at, subject, charge)
	assert_equal(0, rt.completion.status)
	assert_equal(0, rt.remaining)
	assert1(code.number == 98.0)
	rt.running = 0
	__w_list_free(cast(__w_list*, charge))
	js_runtime* foreign = js_runtime_new()
	list[js_value*] arguments = new list[js_value*]
	js_runtime_call_receiver(rt, js_runtime_get(rt, rt.string_prototype, c"charCodeAt"), foreign.undefined_value, arguments)
	assert_equal(2, rt.completion.status)
	__w_list_free(cast(__w_list*, arguments))
	js_runtime_free(foreign)
	js_runtime_free(rt)
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_string_code_unit_test: OK")
	return 0
