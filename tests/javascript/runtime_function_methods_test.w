# wbuild: name=javascript_runtime_function_methods_test
# wbuild: target=javascript_runtime_function_methods_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 --strict tests/javascript/runtime_function_methods_test.w -o bin/javascript_runtime_function_methods_test"
# wbuild: step="bin/javascript_runtime_function_methods_test" expect_stdout="javascript_runtime_function_methods_test: OK"
# wbuild: step="bin/javascript_runtime_function_methods_test memory-basic" expect_stdout="javascript_runtime_function_methods_test: OK"
# wbuild: step="bin/javascript_runtime_function_methods_test memory-bound" expect_stdout="javascript_runtime_function_methods_test: OK"
# wbuild: step="bin/javascript_runtime_function_methods_test memory-getters" expect_stdout="javascript_runtime_function_methods_test: OK"
# wbuild: step="bin/javascript_runtime_function_methods_test memory-limits" expect_stdout="javascript_runtime_function_methods_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

void methods_eval(js_runtime* rt, char* source, int status):
	js_runtime_collect(rt)
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 10000)
	if (result.status != status || (status == 0 && result.value.number != 1.0)):
		println(source)
		println(result.message)
	assert_equal(status, result.status)
	if (status == 0): assert1(result.value.number == 1.0)

void test_methods_basic():
	js_runtime* rt = js_runtime_new()
	methods_eval(rt, c"function sum(a,b){return this.x+a+b;}let object={x:3};sum.call(object,4,5)===12 && sum.apply(object,[4,5])===12;", 0)
	methods_eval(rt, c"function receiver(){'use strict';return this;}receiver.call(null)===null && receiver.apply(7,[])===7 && receiver.call()===undefined;", 0)
	methods_eval(rt, c"function zero(){return 9;}zero.apply(null,null)===9 && zero.apply(null,undefined)===9 && zero.apply(null,{length:-1})===9 && Function.prototype()===undefined;", 0)
	methods_eval(rt, c"sum.apply(object,{'0':4,'1':5,length:'2.9'})===12 && sum.apply(object,{'0':4,'1':5,length:{valueOf:function(){return 2;}}})===12;", 0)
	methods_eval(rt, c"function holes(a,b){return a===undefined && b===8;}holes.apply(null,{'1':8,length:2});", 0)
	methods_eval(rt, c"let invoke=Function.prototype.call;invoke.call(sum,object,4,5)===12 && Math.abs.call(null,-8)===8 && [].push===Array.prototype.push;", 0)
	methods_eval(rt, c"let thisObject={arrow:()=>7};thisObject.arrow.call({x:4})===7 && Function.prototype.call.length===1 && Function.prototype.apply.length===2 && Function.prototype.bind.length===1;", 0)
	methods_eval(rt, c"class C{}C.call===Function.prototype.call && C instanceof Function && sum instanceof Function && Function instanceof Function;", 0)
	methods_eval(rt, c"Function.prototype.call.call({},null);", 2)
	methods_eval(rt, c"sum.apply(object,'45');", 2)
	methods_eval(rt, c"sum.apply(object,{length:1n});", 2)
	methods_eval(rt, c"Object.getPrototypeOf(Function.prototype)===Object.prototype && Object.getPrototypeOf(Function)===Function.prototype && Object.getPrototypeOf(sum)===Function.prototype && Object.prototype.isPrototypeOf(sum);", 0)
	methods_eval(rt, c"sum.hasOwnProperty('length') && Number.hasOwnProperty('MAX_VALUE') && !Number.propertyIsEnumerable('MAX_VALUE') && String.prototype.charCodeAt.hasOwnProperty('name') && sum.valueOf()===sum;", 0)
	methods_eval(rt, c"let rendering=Object.getOwnPropertyDescriptor(Function.prototype,'toString');rendering.writable && !rendering.enumerable && rendering.configurable && rendering.value.name==='toString' && rendering.value.length===0 && !rendering.value.hasOwnProperty('prototype');", 0)
	methods_eval(rt, c"let rejected=0;let invalid=[undefined,null,1,true,'x',{},[]];for(let i=0;i<invalid.length;i++){try{Function.prototype.toString.call(invalid[i]);}catch(e){if(e.constructor===TypeError)rejected++;}}rejected===7;", 0)
	methods_eval(rt, c"Object.prototype.toString.call(sum)==='[object Function]' && Object.prototype.toString.call(Function.prototype)==='[object Function]';", 0)
	methods_eval(rt, c"sum.toString();", 6)
	methods_eval(rt, c"String(sum);", 6)
	methods_eval(rt, c"Function.prototype.toString.call(Error.isError)==='function isError() { [native code] }' && Function.prototype.toString.call(Math.abs).indexOf('[native code]')>0 && Function.prototype.toString.call(sum.bind(null))==='function () { [native code] }' && Function.prototype.toString.call(Function.prototype)==='function () { [native code] }';", 0)
	methods_eval(rt, c"Function.prototype.hasOwnProperty('toString') && Function.prototype.toString!==Object.prototype.toString;", 0)
	js_runtime_free(rt)

void test_methods_bound():
	js_runtime* rt = js_runtime_new()
	methods_eval(rt, c"function sum(a,b,c){return this.x+a+b+c;}let object={x:1};let bound=sum.bind(object,2);bound(3,4)===10 && bound.length===2 && bound.name==='bound sum' && !('prototype' in bound);", 0)
	methods_eval(rt, c"let twice=bound.bind({x:99},3);twice(4)===10 && twice.length===1 && twice.name==='bound bound sum' && twice.call(null,4)===10;", 0)
	methods_eval(rt, c"function C(x,y){this.value=x+y;}C.prototype.read=function(){return this.value;};let B=C.bind({bad:true},2);let instance=new B(5);instance.read()===7 && instance instanceof C && instance instanceof B && instance.constructor===C;", 0)
	methods_eval(rt, c"class Base{constructor(x){this.x=x;}}let Bound=Base.bind(null,7);new Bound().x===7;", 0)
	methods_eval(rt, c"let ArrayTwo=Array.bind(null,2);let sparse=new ArrayTwo();sparse.length===2 && !(0 in sparse) && sparse instanceof ArrayTwo;", 0)
	methods_eval(rt, c"let B2=B.bind(null,3);let inst=new B2();inst.value===5 && inst instanceof B2 && inst instanceof B;", 0)
	methods_eval(rt, c"let Arrow=(()=>1).bind(null);new Arrow();", 2)
	methods_eval(rt, c"let result=0;const schedule=Promise.prototype.then.bind(Promise.resolve());schedule(()=>{result=42;});result===0;", 0)
	js_runtime_collect(rt)
	assert_equal(0, js_runtime_drain_microtasks(rt, 10000).status)
	methods_eval(rt, c"result===42;", 0)
	# The bound record, not incidental globals, keeps target/receiver/args alive.
	methods_eval(rt, c"let saved;{let receiver={x:10};let arg={y:20};saved=(function(a){return this.x+a.y;}).bind(receiver,arg);}true;", 0)
	js_runtime_collect(rt)
	methods_eval(rt, c"saved()===30;", 0)
	js_runtime_free(rt)

struct methods_getter_state:
	int event
	int throws
	list[int] log
	js_value* target
	js_value* prototype

js_value* methods_getter(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	methods_getter_state* state = cast(methods_getter_state*, context)
	assert1(receiver == state.target)
	assert_equal(0, args.length)
	state.log.push(state.event)
	if (state.throws):
		js_runtime_fail(rt, 2, c"callable metadata getter exception")
		rt.completion.value = js_runtime_number(rt, 99.0)
		return rt.undefined_value
	if (state.event == 1):
		state.target.prototype = state.prototype
		return js_runtime_number(rt, 3.9)
	if (state.event == 2): return js_runtime_string_value(rt, c"Read")
	if (state.event == 3): return js_runtime_number(rt, 2.0)
	if (state.event == 4): return js_runtime_number(rt, 4.0)
	return js_runtime_number(rt, 5.0)

void methods_accessor(js_runtime* rt, js_value* object, char* name, methods_getter_state* state):
	js_text* key = js_runtime_key(name)
	js_runtime_define_accessor(rt, object, key, js_runtime_host_callable(rt, state, methods_getter), 0, 0, 1)
	js_text_free(key)

void test_methods_getters():
	js_runtime* rt = js_runtime_new()
	methods_eval(rt, c"function target(a,b,c){return a+b;}let replacement={};let arrayLike={};true;", 0)
	list[int] log = new list[int]
	methods_getter_state length
	length.event = 1
	length.throws = 0
	length.log = log
	length.target = js_runtime_get(rt, rt.global, c"target")
	length.prototype = js_runtime_get(rt, rt.global, c"replacement")
	methods_getter_state name = length
	name.event = 2
	methods_accessor(rt, length.target, c"length", &length)
	methods_accessor(rt, name.target, c"name", &name)
	methods_eval(rt, c"let bound=target.bind(null,4);bound.length===2 && bound.name==='bound Read' && bound(5)===9;", 0)
	assert_equal(2, log.length)
	assert_equal(1, log[0])
	assert_equal(2, log[1])
	assert1(js_runtime_get(rt, rt.global, c"bound").prototype == rt.function_prototype)
	length.throws = 1
	methods_eval(rt, c"let caught=0;try{Function.prototype.bind.call(target,null);}catch(e){caught=e;}caught===99;", 0)
	assert_equal(3, log.length)
	assert_equal(1, log[2])
	methods_getter_state size = length
	size.throws = 0
	size.event = 3
	size.target = js_runtime_get(rt, rt.global, c"arrayLike")
	methods_getter_state first = size
	first.event = 4
	methods_getter_state second = size
	second.event = 5
	methods_accessor(rt, size.target, c"length", &size)
	methods_accessor(rt, size.target, c"0", &first)
	methods_accessor(rt, size.target, c"1", &second)
	methods_eval(rt, c"Function.prototype.apply.call(target,null,arrayLike)===9;", 0)
	assert_equal(6, log.length)
	assert_equal(3, log[3])
	assert_equal(4, log[4])
	assert_equal(5, log[5])
	first.throws = 1
	methods_eval(rt, c"caught=0;try{Function.prototype.apply.call(target,null,arrayLike);}catch(e){caught=e;}caught===99;", 0)
	assert_equal(8, log.length)
	assert_equal(3, log[6])
	assert_equal(4, log[7])
	length.throws = 0
	name.throws = 1
	methods_eval(rt, c"caught=0;try{Function.prototype.bind.call(target,null);}catch(e){caught=e;}caught===99;", 0)
	assert_equal(10, log.length)
	assert_equal(1, log[8])
	assert_equal(2, log[9])
	name.throws = 0
	length.throws = 1
	js_text* key = js_runtime_key(c"length")
	assert1(js_runtime_delete(rt, length.target, key))
	js_text_free(key)
	methods_getter_state inherited = length
	inherited.target = length.target
	methods_accessor(rt, length.prototype, c"length", &inherited)
	methods_eval(rt, c"let noOwnLength=Function.prototype.bind.call(target,null);noOwnLength.length===0;", 0)
	assert_equal(11, log.length)
	assert_equal(2, log[10])
	js_runtime_free(rt)
	__w_list_free(cast(__w_list*, log))

void test_methods_limits():
	js_runtime* rt = js_runtime_new()
	methods_eval(rt, c"function f(){return 1;}let chain=f;for(let i=0;i<25;i++)chain=chain.bind(null);true;", 0)
	rt.max_depth = 12
	methods_eval(rt, c"chain();", 5)
	methods_eval(rt, c"new chain();", 5)
	methods_eval(rt, c"({}) instanceof chain;", 5)
	rt.max_depth = 256
	methods_eval(rt, c"Function('return 1');", 6)
	methods_eval(rt, c"f.apply(null,{length:1/0});", 5)
	methods_eval(rt, c"let bound=f.bind(null,1,2);true;", 0)
	rt.max_properties = 3
	methods_eval(rt, c"bound(3,4);", 5)
	methods_eval(rt, c"f.apply(null,{length:4});", 5)
	rt.max_properties = 10000
	char* source = c"bound(1,2);"
	assert_equal(5, js_runtime_eval(rt, source, strlen(source), 5).status)
	js_runtime_free(rt)

int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	if (argc == 1 || strcmp(args_get(1), c"memory-basic") == 0): test_methods_basic()
	if (argc == 1 || strcmp(args_get(1), c"memory-bound") == 0): test_methods_bound()
	if (argc == 1 || strcmp(args_get(1), c"memory-getters") == 0): test_methods_getters()
	if (argc == 1 || strcmp(args_get(1), c"memory-limits") == 0): test_methods_limits()
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_function_methods_test: OK")
	return 0
