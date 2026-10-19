# wbuild: name=javascript_runtime_property_key_test
# wbuild: target=javascript_runtime_property_key_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 --strict tests/javascript/runtime_property_key_test.w -o bin/javascript_runtime_property_key_test"
# wbuild: step="bin/javascript_runtime_property_key_test" expect_stdout="javascript_runtime_property_key_test: OK"
# wbuild: step="bin/javascript_runtime_property_key_test memory" expect_stdout="javascript_runtime_property_key_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

void property_key_eval(js_runtime* rt, char* source, int expected):
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
	property_key_eval(rt, c"let object={};object[undefined]=1;object[null]=2;object[true]=3;object[false]=4;object[NaN]=5;object[Infinity]=6;object[-Infinity]=7;object[1.5]=8;object[-0]=9;object[1e21]=10;object[123n]=11;object.undefined===1 && object.null===2 && object.true===3 && object.false===4 && object.NaN===5 && object.Infinity===6 && object['-Infinity']===7 && object['1.5']===8 && object['0']===9 && object['1e+21']===10 && object['123']===11;", 0)
	property_key_eval(rt, c"object[undefined]===1 && object[null]===2 && object[true]===3 && object[NaN]===5 && object[1.5]===8 && object[123n]===11 && delete object[undefined] && !Object.hasOwn(object,'undefined');", 0)
	property_key_eval(rt, c"let key={toString:function(){return 'x';},valueOf:function(){throw 99;}};object[key]=12;object[key]===12 && delete object[key] && !Object.hasOwn(object,'x');", 0)
	property_key_eval(rt, c"let order='';key={toString:function(){order+='s';return {};},valueOf:function(){order+='v';return true;}};object[key]===3 && order==='sv';", 0)
	property_key_eval(rt, c"let calls=0;let property={};Object.defineProperty(property,'toString',{get:function(){calls++;throw 81;}});let caught=0;try{object[property];}catch(e){caught=e;}caught===81 && calls===1;", 0)
	property_key_eval(rt, c"caught=0;try{object[{toString:function(){return {};},valueOf:function(){return {};}}];}catch(e){caught=e.constructor===TypeError;}caught===true;", 0)
	property_key_eval(rt, c"let valueKey={toString:3,valueOf:function(){return null;}};object[valueKey]===2;", 0)
	property_key_eval(rt, c"order='';key={toString:function(){order+='k';return 'x';}};function base(){order+='b';return object;}function expression(){order+='e';return key;}function rhs(){order+='r';return 2;}base()[expression()]=rhs();order==='berk' && object.x===2;", 0)
	property_key_eval(rt, c"order='';base()[expression()]+=rhs();order==='bekrk' && object.x===4;", 0)
	property_key_eval(rt, c"order='';let before=base()[expression()]++;order==='bekk' && before===4 && object.x===5;", 0)
	property_key_eval(rt, c"let twice=0;key={toString:function(){twice++;return twice===1?'x':'y';}};object[key]+=1;twice===2 && object.x===5 && object.y===6;", 0)
	property_key_eval(rt, c"order='';key={toString:function(){order+='k';throw 71;}};caught=0;try{base()[expression()]=rhs();}catch(e){caught=e;}caught===71 && order==='berk';", 0)
	property_key_eval(rt, c"order='';caught=0;try{base()[expression()]+=rhs();}catch(e){caught=e;}caught===71 && order==='bek';", 0)
	property_key_eval(rt, c"order='';function throwing(){order+='r';throw 72;}caught=0;try{base()[expression()]=throwing();}catch(e){caught=e;}caught===72 && order==='ber';", 0)
	property_key_eval(rt, c"order='';caught=0;try{null[expression()];}catch(e){caught=e.constructor===TypeError;}caught===true && order==='e';", 0)
	property_key_eval(rt, c"order='';caught=0;try{undefined[expression()]=rhs();}catch(e){caught=e.constructor===TypeError;}caught===true && order==='er';", 0)
	property_key_eval(rt, c"order='';caught=0;try{delete null[expression()];}catch(e){caught=e.constructor===TypeError;}caught===true && order==='e';", 0)
	property_key_eval(rt, c"order='';null?.[expression()]===undefined && order==='';", 0)
	property_key_eval(rt, c"key={toString:function(){return 'run';}};object.run=function(){return this===object;};object[key]() && object?.[key]();", 0)
	property_key_eval(rt, c"calls=0;Object.defineProperty(object,'erase',{get:function(){calls++;throw 91;},configurable:true});key={toString:function(){return 'erase';}};delete object[key] && calls===0;", 0)
	property_key_eval(rt, c"key={toString:function(){return 'iterated';}};for(object[key] in {name:1}){}object.iterated==='name';", 0)
	property_key_eval(rt, c"let utf='\\u0000\\ud800';object[utf]=23;object[utf]===23 && delete object[utf];", 0)
	js_value* target = js_runtime_alloc(rt, 5)
	js_value* local = js_runtime_number(rt, 1.5)
	assert1(js_runtime_root(rt, target))
	assert1(js_runtime_root(rt, local))
	js_runtime* foreign = js_runtime_new()
	js_runtime_begin(rt, 1000)
	assert1(js_runtime_property_key(rt, target, foreign.undefined_value) == 0)
	assert_equal(2, rt.completion.status)
	js_runtime_begin(rt, 1000)
	assert1(js_runtime_property_key(rt, foreign.global, local) == 0)
	assert_equal(2, rt.completion.status)
	js_runtime_free(foreign)
	js_runtime_begin(rt, 1000)
	js_runtime_collect(rt)
	js_text* native_key = js_runtime_property_key(rt, target, local)
	assert1(native_key != 0)
	assert1(js_runtime_key_is(native_key, c"1.5"))
	js_text_free(native_key)
	js_runtime_free(rt)
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_property_key_test: OK")
	return 0
