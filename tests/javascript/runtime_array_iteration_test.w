# wbuild: name=javascript_runtime_array_iteration_test
# wbuild: target=javascript_runtime_array_iteration_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 --strict tests/javascript/runtime_array_iteration_test.w -o bin/javascript_runtime_array_iteration_test"
# wbuild: step="bin/javascript_runtime_array_iteration_test" expect_stdout="javascript_runtime_array_iteration_test: OK"
# wbuild: step="bin/javascript_runtime_array_iteration_test memory-a" expect_stdout="javascript_runtime_array_iteration_test: OK"
# wbuild: step="bin/javascript_runtime_array_iteration_test memory-b" expect_stdout="javascript_runtime_array_iteration_test: OK"
# wbuild: step="bin/javascript_runtime_array_iteration_test memory-c" expect_stdout="javascript_runtime_array_iteration_test: OK"
# wbuild: step="bin/javascript_runtime_array_iteration_test memory-d" expect_stdout="javascript_runtime_array_iteration_test: OK"
# wbuild: step="bin/javascript_runtime_array_iteration_test memory-e" expect_stdout="javascript_runtime_array_iteration_test: OK"
# wbuild: step="bin/javascript_runtime_array_iteration_test memory-f" expect_stdout="javascript_runtime_array_iteration_test: OK"
# wbuild: step="bin/javascript_runtime_array_iteration_test memory-g" expect_stdout="javascript_runtime_array_iteration_test: OK"
# wbuild: step="bin/javascript_runtime_array_iteration_test memory-h" expect_stdout="javascript_runtime_array_iteration_test: OK"
# wbuild: step="bin/javascript_runtime_array_iteration_test memory-host" expect_stdout="javascript_runtime_array_iteration_test: OK"
# wbuild: step="bin/javascript_runtime_array_iteration_test memory-own" expect_stdout="javascript_runtime_array_iteration_test: OK"
# wbuild: step="bin/javascript_runtime_array_iteration_test memory-async" expect_stdout="javascript_runtime_array_iteration_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

int iteration_group = -1
int iteration_case = 0

void iteration_eval(js_runtime* rt, char* body, int status):
	int selected = iteration_group < 0 || iteration_case / 4 == iteration_group
	iteration_case = iteration_case + 1
	if (selected == 0): return
	js_runtime_collect(rt)
	string_builder* source = string_from(c"(function(){")
	string_append(source, body)
	string_append(source, c"})();")
	js_completion* result = js_runtime_eval(rt, source.data, source.length, 30000)
	if (result.status != status || (status == 0 && result.value.number != 1.0)):
		println(source.data)
		println(result.message)
	assert_equal(status, result.status)
	if (status == 0): assert1(result.value.number == 1.0)
	string_free(source)

void test_iteration():
	js_runtime* rt = js_runtime_new()
	iteration_eval(rt, c"return [].every(()=>false) && [1,2].every(x=>x>0) && ![1,0,2].every(x=>x>0);", 0)
	iteration_eval(rt, c"let calls=0;let a=[1,2,3];return a.every(x=>{calls++;return x<2;})===false && calls===2;", 0)
	iteration_eval(rt, c"let a=Array(3);a[1]=4;let b=a.map((v,i,o)=>v+i+o.length);return b.length===3 && !(0 in b) && b[1]===8 && !(2 in b);", 0)
	iteration_eval(rt, c"let a=Array(4);a[1]=3;a[3]=5;let b=a.filter((v,i)=>i>1);return b.length===1 && b[0]===5;", 0)
	iteration_eval(rt, c"let a=[1,2];let context={x:3};let b=a.map(function(v,i,o){'use strict';return this===context && o===a ? v+this.x+i : 0;},context);return b[0]===4 && b[1]===6;", 0)
	iteration_eval(rt, c"let sum=0;return [2,3].forEach((v,i)=>{sum+=v+i;})===undefined && sum===6;", 0)
	iteration_eval(rt, c"let a=[1,2];let b=a.map((v,i)=>{a.push(9);if(i===0)a[1]=8;return v;});return b.length===2 && b[1]===8;", 0)
	iteration_eval(rt, c"let a=[1,2,3];let b=a.map((v,i)=>{if(i===0)a.length=1;return v;});return b.length===3 && b[0]===1 && !(1 in b) && !(2 in b);", 0)
	iteration_eval(rt, c"let a=[1,2];let b=a.filter((v,i)=>{a[i]=9;return true;});return b[0]===1 && b[1]===2;", 0)
	iteration_eval(rt, c"let a=Array(3);a[1]=8;let seen='';let result=a.find((v,i)=>{seen+=i;return v===8;});return result===8 && seen==='01';", 0)
	iteration_eval(rt, c"let a=Array(3);return a.findIndex(v=>v===undefined)===0 && a.findLastIndex(v=>v===undefined)===2;", 0)
	iteration_eval(rt, c"let a=[1,2,1];return a.findLast(v=>v===1)===1 && a.findLastIndex(v=>v===1)===2 && a.findIndex(v=>v===7)===-1 && a.findLast(v=>v===7)===undefined;", 0)
	iteration_eval(rt, c"let a=[1,2,3];let visits=0;a.find((v,i)=>{visits++;a.length=0;return false;});return visits===3;", 0)
	iteration_eval(rt, c"let a=Array(4);a[1]=2;a[3]=4;let order='';let sum=a.reduce((p,v,i,o)=>{order+=i;return p+v;});return sum===6 && order==='3';", 0)
	iteration_eval(rt, c"return [1,2,3].reduce((p,v)=>p-v)===-4 && [1,2,3].reduceRight((p,v)=>p-v)===0;", 0)
	iteration_eval(rt, c"let a=[1,2];let seen=0;let sum=a.reduce(function(p,v,i,o){'use strict';if(this===undefined && o===a)seen++;return p+v+i;},10);return sum===14 && seen===2;", 0)
	iteration_eval(rt, c"return [].reduce(()=>1,undefined)===undefined && Array(2).reduceRight(()=>1,9)===9;", 0)
	iteration_eval(rt, c"Array(3).reduce(()=>0);", 2)
	iteration_eval(rt, c"[].reduceRight(()=>0);", 2)
	iteration_eval(rt, c"[].map(null);", 2)
	iteration_eval(rt, c"Array.prototype.find.call(null,()=>true);", 2)
	iteration_eval(rt, c"Array.prototype.every.call({length:1n},()=>true);", 2)
	iteration_eval(rt, c"let a=[1];a.constructor=2;return a.map(v=>v);", 2)
	iteration_eval(rt, c"let a=[1];a.constructor=undefined;return a.filter(v=>v)[0]===1;", 0)
	iteration_eval(rt, c"let proto=Array.prototype;let a=proto.map.call('ab',(v,i,o)=>v+i);return a[0]==='a0' && a[1]==='b1' && proto.reduce.call('ab',(p,v)=>p+v,'')==='ab';", 0)
	iteration_eval(rt, c"function P(){}P.prototype[1]=7;let a=new P();a.length='3';let b=Array.prototype.map.call(a,(v,i)=>v+i);return b.length===3 && !(0 in b) && b[1]===8;", 0)
	iteration_eval(rt, c"let caught=0;try{[1,2].map(()=>{throw 17;});}catch(e){caught=e;}return caught===17;", 0)
	iteration_eval(rt, c"return Array.prototype.reduce.name==='reduce' && Array.prototype.map.length===1 && Array.prototype.findLastIndex.name==='findLastIndex';", 0)
	iteration_eval(rt, c"Array.prototype.forEach.call({length:1/0},()=>{});", 5)
	char* source = c"Array.prototype.find.call({length:1000},()=>false);"
	assert_equal(5, js_runtime_eval(rt, source, strlen(source), 40).status)
	rt.max_depth = 20
	iteration_eval(rt, c"function recurse(){return [1].map(recurse);}recurse();", 5)
	assert_equal(0, rt.depth)
	js_runtime_free(rt)

struct iteration_host:
	list[int] log
	js_value* object
	int has_throws
	int length_throws

js_value* iteration_get(void* runtime, void* context, js_value* receiver, js_text* key):
	js_runtime* rt = cast(js_runtime*, runtime)
	iteration_host* state = cast(iteration_host*, context)
	assert1(receiver == state.object)
	if (js_runtime_key_is(key, c"length")):
		state.log.push(10)
		if (state.length_throws): js_runtime_fail(rt, 2, c"length before callable validation")
		return js_runtime_number(rt, 2.0)
	int index = js_runtime_array_index(key)
	state.log.push(30 + index)
	return js_runtime_number(rt, cast(float64, index + 5))

int iteration_has(void* runtime, void* context, js_value* receiver, js_text* key):
	js_runtime* rt = cast(js_runtime*, runtime)
	iteration_host* state = cast(iteration_host*, context)
	assert1(receiver == state.object)
	int index = js_runtime_array_index(key)
	state.log.push(20 + index)
	if (state.has_throws): js_runtime_fail(rt, 2, c"presence failure")
	return index == 1

void test_iteration_host():
	js_runtime* rt = js_runtime_new()
	iteration_host state
	state.log = new list[int]
	state.object = js_runtime_alloc(rt, 5)
	state.has_throws = 0
	state.length_throws = 0
	js_runtime_set(rt, rt.global, c"native", state.object)
	js_runtime_set_host_hooks(rt, state.object, &state, iteration_get, 0)
	js_runtime_set_host_has(rt, state.object, iteration_has)
	iteration_eval(rt, c"let a=Array.prototype.map.call(native,x=>x);return a.length===2 && !(0 in a) && a[1]===6;", 0)
	assert_equal(4, state.log.length)
	assert_equal(10, state.log[0])
	assert_equal(20, state.log[1])
	assert_equal(21, state.log[2])
	assert_equal(31, state.log[3])
	state.log.clear()
	iteration_eval(rt, c"return Array.prototype.findLast.call(native,()=>false)===undefined;", 0)
	assert_equal(3, state.log.length)
	assert_equal(10, state.log[0])
	assert_equal(31, state.log[1])
	assert_equal(30, state.log[2])
	state.log.clear()
	state.has_throws = 1
	iteration_eval(rt, c"Array.prototype.reduce.call(native,()=>1,0);", 2)
	assert_equal(2, state.log.length)
	state.has_throws = 0
	state.length_throws = 1
	state.log.clear()
	iteration_eval(rt, c"Array.prototype.map.call(native,null);", 2)
	assert_equal(1, state.log.length)
	assert1(strcmp(rt.completion.message, c"length before callable validation") == 0)
	js_runtime_free(rt)
	__w_list_free(cast(__w_list*, state.log))

# These programs share top-level bindings across checkpoints, unlike the
# isolated expression cases above. GC between async suspension and resume
# must retain both callbacks' original value/index/object argument records.
void iteration_checkpoint(js_runtime* rt, char* source):
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 30000)
	if (result.status != 0 || result.value.number != 1.0):
		println(source)
		println(result.message)
	assert_equal(0, result.status)
	assert1(result.value.number == 1.0)

void test_iteration_own_data():
	js_runtime* rt = js_runtime_new()
	iteration_checkpoint(rt, c"let setter=function(){throw 73;};true;")
	js_text* key = js_runtime_key(c"0")
	assert1(js_runtime_define_accessor(rt, rt.array_prototype, key, 0, js_runtime_get(rt, rt.global, c"setter"), 1, 1))
	iteration_checkpoint(rt, c"let mapped=Array.prototype.map.call({'0':7,length:1},x=>x+1);let filtered=Array.prototype.filter.call({'0':9,length:1},()=>true);mapped[0]===8 && filtered[0]===9;")
	js_value* mapped = js_runtime_get(rt, rt.global, c"mapped")
	js_value* filtered = js_runtime_get(rt, rt.global, c"filtered")
	js_value* property = js_runtime_property(mapped, key)
	assert1(property != 0 && property.writable && property.enumerable && property.configurable && property.accessor == 0)
	property = js_runtime_property(filtered, key)
	assert1(property != 0 && property.writable && property.enumerable && property.configurable && property.accessor == 0)
	assert_equal(1, mapped.array_length)
	assert_equal(1, filtered.array_length)
	js_text_free(key)
	js_runtime_free(rt)

void test_iteration_async():
	js_runtime* rt = js_runtime_new()
	iteration_checkpoint(rt, c"let calls='';let gateResolve;const gate=new Promise(r=>{gateResolve=r;});const promises=[10,20].map(async function(v,i,o){calls+=i;await gate;return v+i+o.length;});let a=0;let b=0;promises[0].then(x=>{a=x;});promises[1].then(x=>{b=x;});calls==='01' && a===0 && b===0;")
	assert_equal(2, rt.async_tasks.length)
	js_runtime_collect(rt)
	iteration_checkpoint(rt, c"gateResolve(1);a===0 && b===0;")
	assert_equal(0, js_runtime_drain_microtasks(rt, 30000).status)
	iteration_checkpoint(rt, c"a===12 && b===23;")
	assert_equal(0, rt.async_tasks.length)
	assert_equal(0, rt.async_stack_bytes)
	assert_equal(0, rt.async_root_count)
	# Synchronous predicate methods test the returned promise's truthiness;
	# they must not await an async callback's eventual false result.
	iteration_checkpoint(rt, c"[1,2].filter(async()=>false).length===2 && [1].every(async()=>false) && [1].find(async()=>false)===1;")
	assert_equal(0, js_runtime_drain_microtasks(rt, 30000).status)
	js_runtime_free(rt)

int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	if (argc == 1 || strcmp(args_get(1), c"memory-host") != 0 && strcmp(args_get(1), c"memory-own") != 0 && strcmp(args_get(1), c"memory-async") != 0):
		if (argc > 1): iteration_group = args_get(1)[7] - 'a'
		test_iteration()
	if (argc == 1 || strcmp(args_get(1), c"memory-host") == 0):
		iteration_group = -1
		test_iteration_host()
	if (argc == 1 || strcmp(args_get(1), c"memory-own") == 0): test_iteration_own_data()
	if (argc == 1 || strcmp(args_get(1), c"memory-async") == 0): test_iteration_async()
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_array_iteration_test: OK")
	return 0
