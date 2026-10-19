# wbuild: name=javascript_runtime_global_numeric_test
# wbuild: target=javascript_runtime_global_numeric_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 --strict tests/javascript/runtime_global_numeric_test.w -o bin/javascript_runtime_global_numeric_test"
# wbuild: step="bin/javascript_runtime_global_numeric_test" expect_stdout="javascript_runtime_global_numeric_test: OK"
# wbuild: step="bin/javascript_runtime_global_numeric_test memory" expect_stdout="javascript_runtime_global_numeric_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

void numeric_eval(js_runtime* rt, char* source, int expected):
	js_runtime_collect(rt)
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 100000)
	if (result.status != expected || (expected == 0 && result.value.number != 1.0)):
		println(source)
		println(result.message)
	assert_equal(expected, result.status)
	if (expected == 0): assert1(result.value.number == 1.0)

int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	js_runtime* rt = js_runtime_new()
	numeric_eval(rt, c"parseInt('12x')===12 && parseInt('  -0xF')===-15 && parseInt('010')===10 && parseInt('0b11')===0 && parseInt('0o11')===0;", 0)
	numeric_eval(rt, c"parseInt('0x10',16)===16 && parseInt('0X10',0)===16 && parseInt('0x10',10)===0 && parseInt('0x10',36)===42804 && parseInt('z',36)===35 && parseInt('Z',36)===35;", 0)
	numeric_eval(rt, c"parseInt('12',4294967298)===1 && parseInt('12',-4294967286)===12 && parseInt('12',10.9)===12 && parseInt('12',NaN)===12 && parseInt('12',Infinity)===12;", 0)
	numeric_eval(rt, c"isNaN(parseInt('1',1)) && isNaN(parseInt('1',37)) && isNaN(parseInt('1',-2)) && isNaN(parseInt('0x')) && isNaN(parseInt('-')) && isNaN(parseInt('')) && isNaN(parseInt());", 0)
	numeric_eval(rt, c"parseInt('\\uFEFF\\u00A0\\u1680\\u2000\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000+42tail')===42 && isNaN(parseInt('\\u180E1')) && isNaN(parseInt('\\u00851')) && parseInt('12\\u000034')===12 && parseInt('12\\uD8003')===12;", 0)
	numeric_eval(rt, c"Object.is(parseInt('-0'),-0) && Object.is(parseInt('-000x',10),-0) && Object.is(parseInt('-0x0'),-0) && Object.is(parseInt('+0'),0) && parseInt(1e21)===1 && parseInt(1e-7)===1 && parseInt(19n)===19;", 0)
	numeric_eval(rt, c"parseInt('9007199254740993')===9007199254740992 && parseInt('9007199254740995')===9007199254740996 && parseInt('20000000000001',16)===9007199254740992 && parseInt('20000000000003',16)===9007199254740996;", 0)
	numeric_eval(rt, c"let order='';let source={toString:function(){order+='s';return '17';}};let radix={valueOf:function(){order+='r';return 8;}};parseInt(source,radix)===15 && order==='sr';", 0)
	numeric_eval(rt, c"order='';let thrown=0;try{parseInt({toString:function(){order+='s';throw 17;}},radix);}catch(e){thrown=e;}thrown===17 && order==='s';", 0)
	numeric_eval(rt, c"order='';thrown=0;try{parseInt('bad',{valueOf:function(){order+='r';throw 23;}});}catch(e){thrown=e;}thrown===23 && order==='r';", 0)
	numeric_eval(rt, c"thrown=0;try{parseInt('10',2n);}catch(e){thrown=e.constructor===TypeError;}thrown===true;", 0)
	numeric_eval(rt, c"isNaN() && isNaN(undefined) && isNaN('abc') && isNaN(NaN) && !isNaN(null) && !isNaN('') && !isNaN('  ') && !isNaN('0x10') && !isNaN(true) && !isNaN(Infinity);", 0)
	numeric_eval(rt, c"!isFinite() && !isFinite(undefined) && !isFinite(NaN) && !isFinite(Infinity) && !isFinite(-Infinity) && isFinite(null) && isFinite('') && isFinite(false) && isFinite(-0) && isFinite('1e308') && !isFinite('1e309');", 0)
	numeric_eval(rt, c"order='';let numeric={valueOf:function(){order+='v';return {};},toString:function(){order+='s';return '5';}};isFinite(numeric) && order==='vs' && !Number.isFinite(numeric);", 0)
	numeric_eval(rt, c"thrown=0;try{isNaN({valueOf:function(){throw 29;}});}catch(e){thrown=e;}thrown===29;", 0)
	numeric_eval(rt, c"thrown=0;try{isFinite(1n);}catch(e){thrown=e.constructor===TypeError;}thrown===true;", 0)
	numeric_eval(rt, c"thrown=0;try{isNaN(Object(1n));}catch(e){thrown=e.constructor===TypeError;}thrown===true;", 0)
	numeric_eval(rt, c"parseInt.length===2 && parseInt.name==='parseInt' && isNaN.length===1 && isNaN.name==='isNaN' && isFinite.length===1 && isFinite.name==='isFinite' && Number.parseInt===parseInt && !Object.hasOwn(parseInt,'prototype');", 0)
	numeric_eval(rt, c"let descriptor=Object.getOwnPropertyDescriptor(Number,'parseInt');descriptor.value===parseInt && descriptor.writable && !descriptor.enumerable && descriptor.configurable;", 0)
	numeric_eval(rt, c"descriptor=Object.getOwnPropertyDescriptor(parseInt,'length');descriptor.value===2 && !descriptor.writable && !descriptor.enumerable && descriptor.configurable;", 0)
	numeric_eval(rt, c"thrown=0;try{new isFinite();}catch(e){thrown=e.constructor===TypeError;}thrown===true && parseInt.call(null,'20')===20;", 0)
	js_value* global = js_runtime_alloc(rt, 5)
	assert1(js_runtime_set_global_object(rt, global))
	numeric_eval(rt, c"descriptor=Object.getOwnPropertyDescriptor(this,'isNaN');descriptor.value===isNaN && descriptor.writable && !descriptor.enumerable && descriptor.configurable;", 0)
	js_runtime* foreign = js_runtime_new()
	list[js_value*] arguments = new list[js_value*]
	arguments.push(foreign.undefined_value)
	js_runtime_call(rt, js_runtime_get(rt, rt.global, c"parseInt"), arguments)
	assert_equal(2, rt.completion.status)
	__w_list_free(cast(__w_list*, arguments))
	js_runtime_free(foreign)
	numeric_eval(rt, c"true;", 0)
	js_text* long_number = js_text_new()
	for i in range(400): long_number.units.push('9')
	assert1(js_parse_integer(rt, long_number, 10) == float64_from_bits(0x7ff << 52))
	js_text_free(long_number)
	char* bounded = c"parseInt('12345678901234567890123456789012345678901234567890');"
	js_completion* limited = js_runtime_eval(rt, bounded, strlen(bounded), 25)
	assert_equal(5, limited.status)
	js_runtime_free(rt)
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_global_numeric_test: OK")
	return 0
