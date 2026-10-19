# wbuild: name=javascript_runtime_array_last_index_of_test
# wbuild: target=javascript_runtime_array_last_index_of_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 --strict tests/javascript/runtime_array_last_index_of_test.w -o bin/javascript_runtime_array_last_index_of_test"
# wbuild: step="bin/javascript_runtime_array_last_index_of_test" expect_stdout="javascript_runtime_array_last_index_of_test: OK"
# wbuild: step="bin/javascript_runtime_array_last_index_of_test memory" expect_stdout="javascript_runtime_array_last_index_of_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

void last_index_eval(js_runtime* rt, char* source):
	js_runtime_collect(rt)
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 100000)
	if (result.status != 0 || result.value.number != 1.0):
		println(source)
		println(result.message)
	assert_equal(0, result.status)
	assert1(result.value.number == 1.0)

js_value* last_index_get(void* runtime, void* context, js_value* receiver, js_text* key):
	js_runtime* rt = cast(js_runtime*, runtime)
	int* trace = cast(int*, context)
	assert_equal(-1, js_runtime_collect(rt))
	if (js_runtime_key_is(key, c"length")): return js_runtime_number(rt, 3.0)
	if (js_runtime_key_is(key, c"2")):
		*trace = *trace * 10 + 2
		return js_runtime_boolean(rt, 0)
	if (js_runtime_key_is(key, c"0")):
		*trace = *trace * 10 + 4
		return js_runtime_boolean(rt, 1)
	return 0

int last_index_has(void* runtime, void* context, js_value* receiver, js_text* key):
	int* trace = cast(int*, context)
	if (js_runtime_key_is(key, c"2")):
		*trace = *trace * 10 + 1
		return 1
	if (js_runtime_key_is(key, c"1")):
		*trace = *trace * 10 + 3
		return 0
	if (js_runtime_key_is(key, c"0")): return 1
	return 0

int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	js_runtime* rt = js_runtime_new()
	last_index_eval(rt, c"[1,2,1].lastIndexOf(1)===2 && [1,2,1].lastIndexOf(1,1)===0 && [1,2,1].lastIndexOf(1,undefined)===0 && [1,2].lastIndexOf(3)===-1;")
	last_index_eval(rt, c"[1,2,1].lastIndexOf(1,-1)===2 && [1,2].lastIndexOf(1,-Infinity)===-1 && [1,2].lastIndexOf(2,Infinity)===1 && [1,2].lastIndexOf(2,NaN)===-1 && [1].lastIndexOf(1,-0.9)===0;")
	last_index_eval(rt, c"[1,2].lastIndexOf(1,-2.9)===0 && [1,2].lastIndexOf(1,-3)===-1 && [1,2].lastIndexOf(2,1.9)===1 && [1,2].lastIndexOf(1,-0)===0 && [1,2].lastIndexOf(2,99999999999999999)===1;")
	last_index_eval(rt, c"[NaN].lastIndexOf(NaN)===-1 && [-0].lastIndexOf(0)===0 && [0].lastIndexOf(-0)===0 && ['1'].lastIndexOf(1)===-1 && [1n].lastIndexOf(1n)===0;")
	last_index_eval(rt, c"let identity={};[identity].lastIndexOf(identity)===0 && [identity].lastIndexOf({})===-1 && Array(2).lastIndexOf(undefined)===-1 && [undefined].lastIndexOf()===0;")
	last_index_eval(rt, c"Array.prototype.lastIndexOf.call('ababa','b')===3 && Array.prototype.lastIndexOf.call({1:'x',length:3},'x')===1 && Array.prototype.lastIndexOf.call({0:1,length:1.9},1)===0;")
	last_index_eval(rt, c"let inherited=Object.create({1:'x'});inherited.length=2;Array.prototype.lastIndexOf.call(inherited,'x')===1;")
	last_index_eval(rt, c"let log='';let obj={};Object.defineProperty(obj,'length',{get:function(){log+='l';return 3;}});Object.defineProperty(obj,'0',{get:function(){log+='0';return 1;}});Object.defineProperty(obj,'1',{get:function(){log+='1';return 2;}});Object.defineProperty(obj,'2',{get:function(){log+='2';return 3;}});let start={valueOf:function(){log+='s';return 2;}};Array.prototype.lastIndexOf.call(obj,1,start)===0 && log==='ls210';")
	last_index_eval(rt, c"let empty={valueOf:function(){throw 1;}};[].lastIndexOf(1,empty)===-1 && Array.prototype.lastIndexOf.call({length:-1},1,empty)===-1;")
	last_index_eval(rt, c"let live={0:1,1:2,length:2};let from={valueOf:function(){live[1]=3;live.length=0;return 1;}};Array.prototype.lastIndexOf.call(live,3,from)===1;")
	last_index_eval(rt, c"let mutation={length:3};Object.defineProperty(mutation,'2',{get:function(){mutation[0]=7;return 0;}});Array.prototype.lastIndexOf.call(mutation,7)===0;")
	last_index_eval(rt, c"Number.prototype.length=1;Number.prototype[0]='x';let boxed=Array.prototype.lastIndexOf.call(7,'x');delete Number.prototype.length;delete Number.prototype[0];boxed===0;")
	last_index_eval(rt, c"let thrown=0;let target={length:2};Object.defineProperty(target,'1',{get:function(){throw 19;}});try{Array.prototype.lastIndexOf.call(target,1);}catch(e){thrown=e;}thrown===19;")
	last_index_eval(rt, c"let errors=0;try{Array.prototype.lastIndexOf.call(null,1);}catch(e){if(e.constructor===TypeError)errors++;}try{[1].lastIndexOf(1,1n);}catch(e){if(e.constructor===TypeError)errors++;}try{Array.prototype.lastIndexOf.call({length:1n},1);}catch(e){if(e.constructor===TypeError)errors++;}errors===3;")
	last_index_eval(rt, c"let order='';let lengthError={};Object.defineProperty(lengthError,'length',{get:function(){order+='l';throw 21;}});let badStart={valueOf:function(){order+='s';throw 22;}};thrown=0;try{Array.prototype.lastIndexOf.call(lengthError,1,badStart);}catch(e){thrown=e;}thrown===21 && order==='l';")
	last_index_eval(rt, c"order='';thrown=0;try{Array.prototype.lastIndexOf.call(obj,1,badStart);}catch(e){thrown=e;}thrown===22 && order==='s';")
	last_index_eval(rt, c"let method=Array.prototype.lastIndexOf;let descriptor=Object.getOwnPropertyDescriptor(Array.prototype,'lastIndexOf');method.name==='lastIndexOf' && method.length===1 && !method.hasOwnProperty('prototype') && descriptor.writable && !descriptor.enumerable && descriptor.configurable;")
	last_index_eval(rt, c"let constructorError=false;try{new method();}catch(e){constructorError=e.constructor===TypeError;}constructorError;")
	js_value* method = js_runtime_get(rt, rt.global, c"method")
	assert1(js_runtime_root(rt, method))
	js_value* host = js_runtime_alloc(rt, 5)
	int trace = 0
	assert1(js_runtime_set_host_hooks(rt, host, &trace, last_index_get, 0))
	assert1(js_runtime_set_host_has(rt, host, last_index_has))
	assert1(js_runtime_root(rt, host))
	list[js_value*] arguments = new list[js_value*]
	arguments.push(js_runtime_boolean(rt, 1))
	js_runtime_begin(rt, 1000)
	js_value* result = js_runtime_call_receiver(rt, method, host, arguments)
	assert_equal(0, rt.completion.status)
	assert1(result.number == 0.0)
	assert_equal(1234, trace)
	trace = 0
	js_runtime_invoke_receiver(rt, method, host, arguments, 2)
	assert_equal(5, rt.completion.status)
	assert_equal(0, trace)
	js_runtime* foreign = js_runtime_new()
	js_runtime_begin(rt, 1000)
	arguments[0] = foreign.undefined_value
	js_runtime_call_receiver(rt, method, host, arguments)
	assert_equal(2, rt.completion.status)
	assert_equal(0, trace)
	js_runtime_begin(rt, 1000)
	arguments[0] = rt.undefined_value
	js_runtime_call_receiver(rt, method, foreign.global, arguments)
	assert_equal(2, rt.completion.status)
	js_runtime_free(foreign)
	__w_list_free(cast(__w_list*, arguments))
	js_runtime_free(rt)
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_array_last_index_of_test: OK")
	return 0
