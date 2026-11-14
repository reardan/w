# wbuild: name=javascript_runtime_array_some_test
# wbuild: target=javascript_runtime_array_some_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 --strict tests/javascript/runtime_array_some_test.w -o bin/javascript_runtime_array_some_test"
# wbuild: step="bin/javascript_runtime_array_some_test" expect_stdout="javascript_runtime_array_some_test: OK"
# wbuild: step="bin/javascript_runtime_array_some_test memory-basic" expect_stdout="javascript_runtime_array_some_test: OK"
# wbuild: step="bin/javascript_runtime_array_some_test memory-mutation" expect_stdout="javascript_runtime_array_some_test: OK"
# wbuild: step="bin/javascript_runtime_array_some_test memory-host" expect_stdout="javascript_runtime_array_some_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

void some_eval(js_runtime* rt, char* source, int status):
	js_runtime_collect(rt)
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 20000)
	if (result.status != status || (status == 0 && result.value.number != 1.0)):
		println(source)
		println(result.message)
	assert_equal(status, result.status)
	if (status == 0): assert1(result.value.number == 1.0)

void test_some_basic():
	js_runtime* rt = js_runtime_new()
	some_eval(rt, c"let count=0;[].some(()=>{count++;})===false && count===0 && Array.prototype.some.length===1;", 0)
	some_eval(rt, c"let some=Array.prototype.some;some.name==='some' && [1,2,3].some(x=>x===2) && ![1,2].some(x=>x===3);", 0)
	some_eval(rt, c"let visits=0;Array(3).some(()=>{visits++;return true;})===false && visits===0;", 0)
	some_eval(rt, c"let a=[2,4];let context={x:4};let seen=0;true;", 0)
	some_eval(rt, c"function check(v,i,o){'use strict';seen++;return this===context && o===a && i===1 && v===4;}a.some(check,context) && seen===2;", 0)
	some_eval(rt, c"some.call({'1':8,length:'3'},(v,i)=>v===8 && i===1) && some.call('ab',(v,i,o)=>v==='b' && i===1 && o.length===2);", 0)
	some_eval(rt, c"function Parent(){}Parent.prototype[1]=9;let inherited=new Parent();inherited.length=3;some.call(inherited,v=>v===9);", 0)
	some_eval(rt, c"[1].some(()=>({})) && ![1].some(()=>0n) && [1].some(()=>1n);", 0)
	some_eval(rt, c"[].some(null);", 2)
	some_eval(rt, c"some.call(null,()=>true);", 2)
	some_eval(rt, c"some.call({length:1n},()=>true);", 2)
	js_runtime_free(rt)

void test_some_mutation():
	js_runtime* rt = js_runtime_new()
	some_eval(rt, c"let g=[1,2];let visited=0;!g.some((v,i)=>{visited++;g.push(3);return false;}) && visited===2;", 0)
	some_eval(rt, c"let h=[1,2,3];let count=0;!h.some((v,i)=>{count++;if(i===0)h.length=1;return false;}) && count===1;", 0)
	some_eval(rt, c"let c=[1,2];let order='';c.some((v,i)=>{if(i===0){c[1]=9;return false;}return v===9;});", 0)
	some_eval(rt, c"let d=[1,2,3];let calls=0;d.some(v=>{calls++;return v===2;}) && calls===2;", 0)
	some_eval(rt, c"let caught=0;try{d.some(()=>{throw 8;});}catch(e){caught=e;}caught===8;", 0)
	some_eval(rt, c"let resolve;let pending=new Promise(r=>{resolve=r;});let later=0;true;", 0)
	some_eval(rt, c"[4].some(async function(v){await pending;later=v;}) && later===0;", 0)
	js_runtime_collect(rt)
	some_eval(rt, c"resolve();true;", 0)
	assert_equal(0, js_runtime_drain_microtasks(rt, 20000).status)
	some_eval(rt, c"later===4;", 0)
	some_eval(rt, c"Array.prototype.some.call({length:1/0},()=>true);", 5)
	char* source = c"Array.prototype.some.call({length:1000},()=>false);"
	assert_equal(5, js_runtime_eval(rt, source, strlen(source), 40).status)
	js_runtime_free(rt)

struct some_host:
	list[int] log
	js_value* object
	js_value* callback
	js_value* method
	int length_throws
	int recurse

js_value* some_get(void* runtime, void* context, js_value* receiver, js_text* key):
	js_runtime* rt = cast(js_runtime*, runtime)
	some_host* state = cast(some_host*, context)
	assert1(receiver == state.object)
	if (js_runtime_key_is(key, c"length")):
		state.log.push(10)
		if (state.length_throws): js_runtime_fail(rt, 2, c"length getter before callback validation")
		return js_runtime_number(rt, 3.0)
	int index = js_runtime_array_index(key)
	state.log.push(30 + index)
	return js_runtime_number(rt, cast(float64, index))

js_value* some_callback(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	some_host* state = cast(some_host*, context)
	assert1(receiver == state.object)
	assert_equal(3, args.length)
	assert1(args[2] == state.object)
	state.log.push(40 + cast(int, args[1].number))
	if (state.recurse):
		list[js_value*] nested = new list[js_value*]
		nested.push(state.callback)
		nested.push(state.object)
		js_value* value = js_runtime_call_receiver(rt, state.method, state.object, nested)
		__w_list_free(cast(__w_list*, nested))
		return value
	return js_runtime_boolean(rt, 1)

void test_some_host():
	js_runtime* rt = js_runtime_new()
	some_host state
	state.log = new list[int]
	state.object = js_runtime_alloc(rt, 5)
	state.callback = js_runtime_host_callable(rt, &state, some_callback)
	state.method = js_runtime_get(rt, rt.array_prototype, c"some")
	state.length_throws = 0
	state.recurse = 0
	js_runtime_set(rt, rt.global, c"native", state.object)
	js_runtime_set(rt, rt.global, c"callback", state.callback)
	js_runtime_set_host_hooks(rt, state.object, &state, some_get, 0)
	# Native objects expose Get only: presence is assumed, then the value read.
	some_eval(rt, c"Array.prototype.some.call(native,callback,native);", 0)
	assert_equal(3, state.log.length)
	assert_equal(10, state.log[0])
	assert_equal(30, state.log[1])
	assert_equal(40, state.log[2])
	state.log.clear()
	state.length_throws = 1
	some_eval(rt, c"Array.prototype.some.call(native,null);", 2)
	assert_equal(1, state.log.length)
	assert1(strcmp(rt.completion.message, c"length getter before callback validation") == 0)
	state.length_throws = 0
	state.recurse = 1
	rt.max_depth = 20
	some_eval(rt, c"Array.prototype.some.call(native,callback,native);", 5)
	assert_equal(0, rt.depth)
	js_runtime_free(rt)
	__w_list_free(cast(__w_list*, state.log))

int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	if (argc == 1 || strcmp(args_get(1), c"memory-basic") == 0): test_some_basic()
	if (argc == 1 || strcmp(args_get(1), c"memory-mutation") == 0): test_some_mutation()
	if (argc == 1 || strcmp(args_get(1), c"memory-host") == 0): test_some_host()
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_array_some_test: OK")
	return 0
