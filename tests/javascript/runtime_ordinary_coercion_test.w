# wbuild: name=javascript_runtime_ordinary_coercion_test
# wbuild: target=javascript_runtime_ordinary_coercion_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 --strict tests/javascript/runtime_ordinary_coercion_test.w -o bin/javascript_runtime_ordinary_coercion_test"
# wbuild: step="bin/javascript_runtime_ordinary_coercion_test" expect_stdout="javascript_runtime_ordinary_coercion_test: OK"
# wbuild: step="bin/javascript_runtime_ordinary_coercion_test memory" expect_stdout="javascript_runtime_ordinary_coercion_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

void ordinary_coercion_eval(js_runtime* rt, char* source):
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
	ordinary_coercion_eval(rt, c"let empty=Object.create(null);let object={};let actions=[function(){return String(empty);},function(){return Number(empty);},function(){return parseInt(empty);},function(){return ''.charCodeAt(empty);},function(){return ''.charAt(empty);},function(){return object[empty];},function(){return empty==0;}];let errors=0;for(let i=0;i<actions.length;i++){try{actions[i]();}catch(e){if(e.constructor===TypeError)errors++;}}errors===7;")
	ordinary_coercion_eval(rt, c"let numeric=Object.create(null);numeric.valueOf=function(){return 17;};String(numeric)==='17' && Number(numeric)===17 && numeric==17 && parseInt(numeric)===17;")
	ordinary_coercion_eval(rt, c"let textual=Object.create(null);textual.toString=function(){return '23';};String(textual)==='23' && Number(textual)===23 && textual==23;")
	ordinary_coercion_eval(rt, c"object[numeric]=41;object[textual]=42;object['17']===41 && object['23']===42;")
	ordinary_coercion_eval(rt, c"let noncallable=Object.create(null);noncallable.valueOf=3;noncallable.toString=undefined;errors=0;try{String(noncallable);}catch(e){if(e.constructor===TypeError)errors++;}try{Number(noncallable);}catch(e){if(e.constructor===TypeError)errors++;}errors===2;")
	ordinary_coercion_eval(rt, c"let returned=Object.create(null);returned.valueOf=function(){return returned;};returned.toString=function(){return returned;};errors=0;try{String(returned);}catch(e){if(e.constructor===TypeError)errors++;}try{Number(returned);}catch(e){if(e.constructor===TypeError)errors++;}errors===2;")
	ordinary_coercion_eval(rt, c"let order='';let dynamic=Object.create(null);Object.defineProperty(dynamic,'toString',{get:function(){order+='s';dynamic.valueOf=function(){order+='v';return 31;};return undefined;}});String(dynamic)==='31' && order==='sv';")
	ordinary_coercion_eval(rt, c"order='';let changed=Object.create(null);changed.valueOf=function(){order+='v';Object.setPrototypeOf(changed,{toString:function(){order+='s';return '37';}});return changed;};Number(changed)===37 && order==='vs';")
	ordinary_coercion_eval(rt, c"let thrown=0;let abrupt=Object.create(null);Object.defineProperty(abrupt,'toString',{get:function(){throw 81;}});try{String(abrupt);}catch(e){thrown=e;}thrown===81;")
	ordinary_coercion_eval(rt, c"thrown=0;let abruptNumber=Object.create(null);Object.defineProperty(abruptNumber,'valueOf',{get:function(){throw 82;}});try{Number(abruptNumber);}catch(e){thrown=e;}thrown===82;")
	ordinary_coercion_eval(rt, c"let savedToString=Object.prototype.toString;delete Object.prototype.toString;errors=0;try{String({});}catch(e){if(e.constructor===TypeError)errors++;}try{Number({});}catch(e){if(e.constructor===TypeError)errors++;}Object.defineProperty(Object.prototype,'toString',{value:savedToString,writable:true,configurable:true});errors===2 && String({})==='[object Object]';")
	js_runtime_free(rt)
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_ordinary_coercion_test: OK")
	return 0
