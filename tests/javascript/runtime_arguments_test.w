# wbuild: name=javascript_runtime_arguments_test
# wbuild: target=javascript_runtime_arguments_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 --strict tests/javascript/runtime_arguments_test.w -o bin/javascript_runtime_arguments_test"
# wbuild: step="bin/javascript_runtime_arguments_test" expect_stdout="javascript_runtime_arguments_test: OK"
# wbuild: step="bin/javascript_runtime_arguments_test memory-arguments" expect_stdout="javascript_runtime_arguments_test: OK"
# wbuild: step="bin/javascript_runtime_arguments_test memory-closures" expect_stdout="javascript_runtime_arguments_test: OK"
# wbuild: step="bin/javascript_runtime_arguments_test memory-slice-children" expect_stdout="javascript_runtime_arguments_test: OK"
# wbuild: step="bin/javascript_runtime_arguments_test memory-slice-sparse" expect_stdout="javascript_runtime_arguments_test: OK"
# wbuild: step="bin/javascript_runtime_arguments_test memory-slice-string" expect_stdout="javascript_runtime_arguments_test: OK"
# wbuild: step="bin/javascript_runtime_arguments_test memory-conversion" expect_stdout="javascript_runtime_arguments_test: OK"
# wbuild: step="bin/javascript_runtime_arguments_test memory-host" expect_stdout="javascript_runtime_arguments_test: OK"
# wbuild: step="bin/javascript_runtime_arguments_test memory-limits" expect_stdout="javascript_runtime_arguments_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

void arguments_eval(js_runtime* rt, char* source, int status):
	js_runtime_collect(rt)
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 20000)
	if (result.status != status || (status == 0 && result.value.number != 1.0)):
		println(source)
		println(result.message)
	assert_equal(status, result.status)
	if (status == 0): assert1(result.value.number == 1.0)

void test_arguments():
	js_runtime* rt = js_runtime_new()
	arguments_eval(rt, c"function f(a){'use strict';let x=arguments;a=9;x[1]=7;return x===arguments && x.length===2 && x[0]===2 && x[1]===7 && !Array.isArray(x);}f(2,3);", 0)
	arguments_eval(rt, c"function rest(...items){let a=arguments;items[0]=9;return a[0]===2 && a.length===2;}rest(2,3);", 0)
	arguments_eval(rt, c"function defaults(a=arguments[1]){return a===4 && arguments[0]===undefined;}defaults(undefined,4);", 0)
	arguments_eval(rt, c"function varArgs(a=1){var arguments;return arguments.length===2;}varArgs(1,2);", 0)
	arguments_eval(rt, c"function reassigned(a=1){arguments=7;return arguments;}reassigned()===7;", 0)
	arguments_eval(rt, c"function param(arguments){return arguments;}function local(){let arguments=8;return arguments;}param(3)===3 && local()===8;", 0)
	arguments_eval(rt, c"function localFunction(){return arguments();function arguments(){return 9;}}localFunction()===9;", 0)
	js_runtime_free(rt)

void test_arguments_closures():
	js_runtime* rt = js_runtime_new()
	arguments_eval(rt, c"let saved;{let value={x:12};saved=(function(a){'use strict';return ()=>arguments[0].x;})(value);}true;", 0)
	js_runtime_collect(rt)
	arguments_eval(rt, c"saved()===12;", 0)
	arguments_eval(rt, c"function C(x){'use strict';this.x=arguments[0];}new C(7).x===7;", 0)
	arguments_eval(rt, c"function poison(){'use strict';return arguments.callee;}poison();", 2)
	arguments_eval(rt, c"function poisonSet(){'use strict';arguments.callee=3;}poisonSet();", 2)
	arguments_eval(rt, c"function mapped(a){return arguments[0];}mapped(1);", 0)
	arguments_eval(rt, c"function unsupported(a=1){let arguments=2;return arguments;}unsupported();", 6)
	arguments_eval(rt, c"let resolve;let pending=new Promise(r=>{resolve=r;});let answer=0;async function later(x){'use strict';await pending;answer=arguments[0].x;}later({x:33});true;", 0)
	js_runtime_collect(rt)
	arguments_eval(rt, c"resolve();true;", 0)
	assert_equal(0, js_runtime_drain_microtasks(rt, 20000).status)
	arguments_eval(rt, c"answer===33;", 0)
	arguments_eval(rt, c"function descriptors(){'use strict';return arguments;}let inspected=descriptors(4);true;", 0)
	js_value* inspected = js_runtime_get(rt, rt.global, c"inspected")
	js_text* key = js_runtime_key(c"length")
	js_value* property = js_runtime_property(inspected, key)
	assert1(property.writable && property.configurable && property.enumerable == 0)
	js_text_free(key)
	key = js_runtime_key(c"callee")
	property = js_runtime_property(inspected, key)
	assert1(property.accessor == 1 && property.enumerable == 0 && property.configurable == 0 && property.getter == property.setter)
	js_text_free(key)
	js_runtime_free(rt)

void test_slice(int group):
	js_runtime* rt = js_runtime_new()
	arguments_eval(rt, c"let slice=Array.prototype.slice;true;", 0)
	if (group == 0 || group == 1):
		arguments_eval(rt, c"function children(){'use strict';return slice.call(arguments,2);}true;", 0)
		arguments_eval(rt, c"let c=children('div',{},'a','b');c.length===2 && c[0]==='a' && c[1]==='b';", 0)
	if (group == 0 || group == 2):
		arguments_eval(rt, c"let a=slice.call({'1':8,length:'3.9'},0,3);a.length===3 && !(0 in a) && a[1]===8 && !(2 in a);", 0)
	if (group == 0 || group == 3):
		arguments_eval(rt, c"let a2=slice.call('A\\uD83D\\uDE00',1);true;", 0)
		arguments_eval(rt, c"a2.length===2 && a2[0]==='\\uD83D' && a2[1]==='\\uDE00' && slice.call(7).length===0;", 0)
	js_runtime_free(rt)

void test_slice_conversion():
	js_runtime* rt = js_runtime_new()
	arguments_eval(rt, c"let slice=Array.prototype.slice;true;", 0)
	arguments_eval(rt, c"let order='';let start={valueOf:function(){order+='s';return -2;}};true;", 0)
	arguments_eval(rt, c"let end={valueOf:function(){order+='e';return 3;}};true;", 0)
	arguments_eval(rt, c"let input={'0':1,'1':2,'2':3,length:{valueOf:function(){order+='l';return 3;}}};true;", 0)
	arguments_eval(rt, c"let a3=slice.call(input,start,end);order==='lse' && a3.length===2 && a3[0]===2 && a3[1]===3;", 0)
	arguments_eval(rt, c"slice.call([1,2],-1/0,1/0).length===2 && slice.call([1,2],0,undefined).length===2 && slice.call([1,2],2,-2).length===0;", 0)
	arguments_eval(rt, c"function Parent(){}Parent.prototype[1]=6;let inherited=new Parent();inherited.length=3;let a4=slice.call(inherited);a4.length===3 && a4[1]===6 && !(0 in a4) && !(2 in a4);", 0)
	arguments_eval(rt, c"slice.call(null);", 2)
	arguments_eval(rt, c"slice.call([1],1n);", 2)
	arguments_eval(rt, c"let bad=[1];bad.constructor=null;bad.slice();", 2)
	arguments_eval(rt, c"slice.call({length:1/0});", 5)
	js_runtime_free(rt)

struct array_like_host:
	list[int] log
	js_value* object
	int throws

js_value* array_like_get(void* runtime, void* context, js_value* receiver, js_text* key):
	js_runtime* rt = cast(js_runtime*, runtime)
	array_like_host* state = cast(array_like_host*, context)
	assert1(receiver == state.object)
	if (js_runtime_key_is(key, c"length")):
		state.log.push(10)
		return js_runtime_number(rt, 3.0)
	int index = js_runtime_array_index(key)
	if (index >= 0):
		state.log.push(30 + index)
		if (state.throws): js_runtime_fail(rt, 2, c"native index getter throw")
		if (index == 0): js_runtime_set(rt, receiver, c"1", js_runtime_number(rt, 9.0))
		if (index == 0): return js_runtime_number(rt, 7.0)
	return 0

int array_like_has(void* runtime, void* context, js_value* receiver, js_text* key):
	array_like_host* state = cast(array_like_host*, context)
	assert1(receiver == state.object)
	int index = js_runtime_array_index(key)
	state.log.push(20 + index)
	return index == 0

void test_host_slice():
	js_runtime* rt = js_runtime_new()
	array_like_host state
	state.log = new list[int]
	state.object = js_runtime_alloc(rt, 5)
	state.throws = 0
	js_runtime_set(rt, rt.global, c"native", state.object)
	js_runtime_set_host_hooks(rt, state.object, &state, array_like_get, 0)
	js_runtime_set_host_has(rt, state.object, array_like_has)
	arguments_eval(rt, c"let result=Array.prototype.slice.call(native);result.length===3 && result[0]===7 && result[1]===9 && !(2 in result);", 0)
	assert_equal(6, state.log.length)
	assert_equal(10, state.log[0])
	assert_equal(20, state.log[1])
	assert_equal(30, state.log[2])
	assert_equal(21, state.log[3])
	assert_equal(31, state.log[4])
	assert_equal(22, state.log[5])
	state.log.clear()
	state.throws = 1
	arguments_eval(rt, c"Array.prototype.slice.call(native);", 2)
	assert_equal(3, state.log.length)
	js_runtime_free(rt)
	__w_list_free(cast(__w_list*, state.log))

void test_arguments_limits():
	js_runtime* rt = js_runtime_new()
	arguments_eval(rt, c"function f(){'use strict';return arguments;}true;", 0)
	rt.max_properties = 3
	arguments_eval(rt, c"f(1,2,3);", 5)
	arguments_eval(rt, c"Array.prototype.slice.call({length:4});", 5)
	rt.max_properties = 10000
	char* source = c"Array.prototype.slice.call({length:1000});"
	assert_equal(5, js_runtime_eval(rt, source, strlen(source), 30).status)
	js_runtime_free(rt)

int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	if (argc == 1 || strcmp(args_get(1), c"memory-arguments") == 0): test_arguments()
	if (argc == 1 || strcmp(args_get(1), c"memory-closures") == 0): test_arguments_closures()
	if (argc == 1): test_slice(0)
	if (argc > 1 && strcmp(args_get(1), c"memory-slice-children") == 0): test_slice(1)
	if (argc > 1 && strcmp(args_get(1), c"memory-slice-sparse") == 0): test_slice(2)
	if (argc > 1 && strcmp(args_get(1), c"memory-slice-string") == 0): test_slice(3)
	if (argc == 1 || strcmp(args_get(1), c"memory-conversion") == 0): test_slice_conversion()
	if (argc == 1 || strcmp(args_get(1), c"memory-host") == 0): test_host_slice()
	if (argc == 1 || strcmp(args_get(1), c"memory-limits") == 0): test_arguments_limits()
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_arguments_test: OK")
	return 0
