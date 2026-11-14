# wbuild: name=javascript_runtime_object_integrity_test
# wbuild: target=javascript_runtime_object_integrity_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 tests/javascript/runtime_object_integrity_test.w -o bin/javascript_runtime_object_integrity_test"
# wbuild: step="bin/javascript_runtime_object_integrity_test" expect_stdout="javascript_runtime_object_integrity_test: OK"
# wbuild: step="bin/javascript_runtime_object_integrity_test memory" expect_stdout="javascript_runtime_object_integrity_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

void integrity_eval(js_runtime* rt, char* source):
	js_runtime_collect(rt)
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 100000)
	if (result.status != 0 || result.value.number != 1.0):
		println(source)
		println(result.message)
	assert_equal(0, result.status)
	assert1(result.value.number == 1.0)

js_value* integrity_hook(void* runtime, void* context, js_value* receiver, js_text* key):
	int* calls = cast(int*, context)
	*calls = *calls + 1
	return 0

int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	js_runtime* rt = js_runtime_new()
	integrity_eval(rt, c"let primitives=[undefined,null,true,false,0,NaN,Infinity,'x',1n];let valid=true;for(let i=0;i<primitives.length;i++){let x=primitives[i];if(!Object.is(Object.seal(x),x)||!Object.is(Object.freeze(x),x)||!Object.isSealed(x)||!Object.isFrozen(x))valid=false;}valid && Object.seal()===undefined && Object.freeze()===undefined && Object.isSealed() && Object.isFrozen();")
	integrity_eval(rt, c"let object={x:1};!Object.isSealed(object) && !Object.isFrozen(object) && Object.seal(object)===object && !Object.isExtensible(object) && Object.isSealed(object) && !Object.isFrozen(object) && !Object.getOwnPropertyDescriptor(object,'x').configurable && Object.getOwnPropertyDescriptor(object,'x').writable;")
	integrity_eval(rt, c"object.x=2;object.extra=3;object.x===2 && !Object.hasOwn(object,'extra') && !Reflect.deleteProperty(object,'x') && !Reflect.defineProperty(object,'x',{configurable:true}) && Object.freeze(object)===object && Object.isFrozen(object) && !Reflect.set(object,'x',3);")
	integrity_eval(rt, c"let errors=0;try{(function(){'use strict';object.x=3;})();}catch(e){if(e.constructor===TypeError)errors++;}try{(function(){'use strict';delete object.x;})();}catch(e){if(e.constructor===TypeError)errors++;}errors===2;")
	integrity_eval(rt, c"let empty={};Object.preventExtensions(empty);Object.isSealed(empty) && Object.isFrozen(empty) && Object.freeze(empty)===empty && Object.seal(empty)===empty;")
	integrity_eval(rt, c"let calls=0;let accessed={};let getter=function(){calls++;throw 71;};let setter=function(v){calls+=v;};Object.defineProperty(accessed,'x',{get:getter,set:setter,enumerable:true,configurable:true});Object.freeze(accessed);let descriptor=Object.getOwnPropertyDescriptor(accessed,'x');Object.isFrozen(accessed) && Object.isSealed(accessed) && descriptor.get===getter && descriptor.set===setter && descriptor.enumerable && !descriptor.configurable && calls===0;")
	integrity_eval(rt, c"accessed.x=2;calls===2 && Object.isFrozen(accessed);")
	integrity_eval(rt, c"let nested={value:1};let shallow={nested:nested};shallow.self=shallow;Object.freeze(shallow);nested.value=2;Object.isFrozen(shallow) && !Object.isFrozen(nested) && shallow.nested.value===2 && shallow.self===shallow;")
	integrity_eval(rt, c"let array=[1,2];Object.seal(array);Object.isSealed(array) && !Object.isFrozen(array) && Object.getOwnPropertyDescriptor(array,'length').writable && !Reflect.set(array,'length',0) && array.length===2 && array[1]===2;")
	integrity_eval(rt, c"Object.freeze(array);let coerced=0;let size={valueOf:function(){coerced++;return 0;}};Object.isFrozen(array) && !Object.getOwnPropertyDescriptor(array,'length').writable && !Reflect.set(array,'length',size) && coerced===0 && !Reflect.set(array,'0',3);")
	integrity_eval(rt, c"let sparse=[];sparse[4]=9;Object.seal(sparse);!Reflect.set(sparse,'1',2) && Reflect.set(sparse,'length',7) && sparse.length===7 && !Reflect.set(sparse,'length',0) && sparse.length===5 && Object.isSealed(sparse);")
	integrity_eval(rt, c"let emptyArray=[];Object.preventExtensions(emptyArray);Object.isSealed(emptyArray) && !Object.isFrozen(emptyArray) && Object.freeze(emptyArray)===emptyArray && Object.isFrozen(emptyArray);")
	integrity_eval(rt, c"function frozenArguments(x){x=2;Object.freeze(arguments);x=3;return arguments[0]===2 && x===3 && Object.isFrozen(arguments);}frozenArguments(1);")
	integrity_eval(rt, c"function sealedArguments(x){Object.seal(arguments);x=4;arguments[0]=5;return x===5 && Object.isSealed(arguments) && !Object.isFrozen(arguments);}sealedArguments(1);")
	integrity_eval(rt, c"function strictArguments(x){'use strict';Object.freeze(arguments);x=4;return arguments[0]===1 && Object.isFrozen(arguments);}strictArguments(1);")
	integrity_eval(rt, c"let boxed=Object('ab');Object.freeze(boxed);Object.isFrozen(boxed) && boxed[0]==='a' && boxed.length===2 && !Reflect.set(boxed,'0','x');")
	integrity_eval(rt, c"function F(){}Object.freeze(F);F.prototype.x=8;Object.isFrozen(F) && !Object.isFrozen(F.prototype) && new F().x===8;")
	integrity_eval(rt, c"let methods=['seal','freeze','isSealed','isFrozen'];valid=true;for(let i=0;i<methods.length;i++){let m=Object[methods[i]];let d=Object.getOwnPropertyDescriptor(Object,methods[i]);if(m.name!==methods[i]||m.length!==1||Object.hasOwn(m,'prototype')||!d.writable||d.enumerable||!d.configurable)valid=false;}valid;")
	js_value* constructor = js_runtime_get(rt, rt.global, c"Object")
	js_value* freeze = js_runtime_get(rt, constructor, c"freeze")
	js_value* native = js_runtime_alloc(rt, 5)
	assert1(js_runtime_root(rt, native))
	assert1(js_runtime_set(rt, native, c"x", rt.undefined_value))
	list[js_value*] arguments = new list[js_value*]
	arguments.push(native)
	js_runtime_begin(rt, 0)
	js_runtime_call_receiver(rt, freeze, constructor, arguments)
	assert_equal(5, rt.completion.status)
	assert_equal(1, native.non_extensible)
	js_text* key = js_runtime_key(c"x")
	assert_equal(1, js_runtime_property(native, key).configurable)
	js_text_free(key)
	js_runtime_begin(rt, 1000)
	js_runtime_call_receiver(rt, freeze, constructor, arguments)
	assert_equal(0, rt.completion.status)
	js_value* host = js_runtime_alloc(rt, 5)
	int hook_calls = 0
	assert1(js_runtime_set_host_hooks(rt, host, &hook_calls, integrity_hook, 0))
	arguments[0] = host
	js_runtime_call_receiver(rt, freeze, constructor, arguments)
	assert_equal(6, rt.completion.status)
	assert_equal(0, host.non_extensible)
	assert_equal(0, hook_calls)
	js_runtime* foreign = js_runtime_new()
	js_runtime_begin(rt, 1000)
	arguments[0] = foreign.global
	js_runtime_call_receiver(rt, freeze, constructor, arguments)
	assert_equal(2, rt.completion.status)
	assert_equal(0, foreign.global.non_extensible)
	js_runtime_free(foreign)
	__w_list_free(cast(__w_list*, arguments))
	js_runtime_free(rt)
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_object_integrity_test: OK")
	return 0
