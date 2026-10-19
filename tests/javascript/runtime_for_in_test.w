# wbuild: name=javascript_runtime_for_in_test
# wbuild: target=javascript_runtime_for_in_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 tests/javascript/runtime_for_in_test.w -o bin/javascript_runtime_for_in_test"
# wbuild: step="bin/javascript_runtime_for_in_test" expect_stdout="javascript_runtime_for_in_test: OK"
# wbuild: step="bin/javascript_runtime_for_in_test memory-basic" expect_stdout="javascript_runtime_for_in_test: OK"
# wbuild: step="bin/javascript_runtime_for_in_test memory-prototype" expect_stdout="javascript_runtime_for_in_test: OK"
# wbuild: step="bin/javascript_runtime_for_in_test memory-async" expect_stdout="javascript_runtime_for_in_test: OK"
# wbuild: step="bin/javascript_runtime_for_in_test memory-limits" expect_stdout="javascript_runtime_for_in_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

void for_in_eval(js_runtime* rt, char* source):
	js_runtime_collect(rt)
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 10000)
	if (result.status != 0):
		println(source)
		println(result.message)
	assert_equal(0, result.status)
	assert1(result.value.number == 1.0)

void test_for_in_basic():
	js_runtime* rt = js_runtime_new()
	# Exact production Preact helper, not a source rewrite of the bundle.
	for_in_eval(rt, c"function d(n,l){for(var u in l)n[u]=l[u];return n} const copy=d({}, {a:1,b:2});copy.a===1 && copy.b===2;")
	for_in_eval(rt, c"let key;let out='';for(key in {a:1,b:2})out+=key;out==='ab' && key==='b';")
	for_in_eval(rt, c"let target={};out='';for(target.key in {x:1,y:2})out+=target.key;out==='xy';")
	for_in_eval(rt, c"let callbacks=[];for(let k in {a:1,b:2})callbacks.push(()=>k);callbacks[0]()==='a' && callbacks[1]()==='b';")
	for_in_eval(rt, c"function hoisted(){const before=typeof k;for(var k in {a:1}){}return before==='undefined' && k==='a';}hoisted();")
	js_runtime_free(rt)
	rt = js_runtime_new()
	for_in_eval(rt, c"const object={};object.z=1;object[2]=2;object.a=3;object[1]=4;object['01']=5;let keys='';for(const k in object)keys+=k+',';keys==='1,2,z,a,01,';")
	for_in_eval(rt, c"let count=0;for(var k in null)count++;for(k in undefined)count++;for(k in 7)count++;count===0;")
	for_in_eval(rt, c"keys='';for(const k in 'abc')keys+=k;keys==='012';")
	for_in_eval(rt, c"keys='';outer:for(const k in {a:1,b:2,c:3}){if(k==='b')continue outer;keys+=k;if(k==='c')break;}keys==='ac';")
	char* source = c"let tdzObject={};for(let tdzObject in tdzObject){}"
	assert_equal(2, js_runtime_eval(rt, source, strlen(source), 1000).status)
	source = c"for(const k in {a:1})k='x';"
	assert_equal(2, js_runtime_eval(rt, source, strlen(source), 1000).status)
	js_runtime_free(rt)

js_value* for_in_mutate(void* runtime, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	js_value* child = js_runtime_get(rt, rt.global, c"child")
	if (args.length > 0 && js_runtime_key_is(args[0].text, c"a")):
		js_text* key = js_runtime_key(c"b")
		js_runtime_delete(rt, child, key)
		js_text_free(key)
		js_runtime_set(rt, child, c"late", rt.undefined_value)
		key = js_runtime_key(c"c")
		js_runtime_define_data(rt, child, key, rt.undefined_value, 1, 0, 1)
		js_text_free(key)
		js_runtime_set(rt, child.prototype, c"added", rt.undefined_value)
	return rt.undefined_value

void test_for_in_prototype():
	js_runtime* rt = js_runtime_new()
	for_in_eval(rt, c"const parent={b:1,p:2,hidden:3};const child={a:1,b:2,c:3,hidden:4};let keys='';true;")
	js_value* parent = js_runtime_get(rt, rt.global, c"parent")
	js_value* child = js_runtime_get(rt, rt.global, c"child")
	assert1(js_runtime_set_prototype(rt, child, parent))
	js_text* key = js_runtime_key(c"hidden")
	assert1(js_runtime_define_data(rt, child, key, rt.undefined_value, 1, 0, 1))
	js_text_free(key)
	js_runtime_bind(rt, c"mutate", for_in_mutate)
	for_in_eval(rt, c"for(const k in child){keys+=k+',';mutate(k);}keys==='a,b,p,added,';")
	# Descriptor enumeration must not invoke property getters.
	char* source = c"(function(){throw 99;});"
	assert_equal(0, js_runtime_eval(rt, source, strlen(source), 1000).status)
	js_value* getter = rt.completion.value
	key = js_runtime_key(c"accessor")
	assert1(js_runtime_define_accessor(rt, parent, key, getter, 0, 1, 1))
	js_text_free(key)
	for_in_eval(rt, c"keys='';for(const k in parent)keys+=k+',';keys==='b,p,hidden,added,accessor,';")
	js_runtime_free(rt)

void test_for_in_async():
	js_runtime* rt = js_runtime_new()
	for_in_eval(rt, c"let release;const pending=new Promise(r=>{release=r;});let keys='';async function f(){for(const k in {a:1,b:2}){await pending;keys+=k;}}f();keys==='';")
	js_runtime_collect(rt)
	for_in_eval(rt, c"release(0);true;")
	assert_equal(0, js_runtime_drain_microtasks(rt, 10000).status)
	for_in_eval(rt, c"keys==='ab';")
	js_runtime_free(rt)
	rt = js_runtime_new()
	for_in_eval(rt, c"const pending=new Promise(r=>{});async function f(){for(const k in {a:1,b:2})await pending;}f();true;")
	js_runtime_collect(rt)
	assert_equal(1, js_runtime_async_cancel(rt))
	js_runtime_free(rt)

void test_for_in_limits():
	js_runtime* rt = js_runtime_new()
	for_in_eval(rt, c"let key;const object={a:1,b:2,c:3};true;")
	rt.max_properties = 2
	char* source = c"for(key in object){}"
	assert_equal(5, js_runtime_eval(rt, source, strlen(source), 1000).status)
	rt.max_properties = 10000
	assert_equal(5, js_runtime_eval(rt, source, strlen(source), 5).status)
	js_runtime_free(rt)
	rt = js_runtime_new()
	source = c"for(const [key] in {a:1}){}"
	assert_equal(6, js_runtime_eval(rt, source, strlen(source), 1000).status)
	source = c"for(var key in new Uint8Array(2)){}"
	assert_equal(6, js_runtime_eval(rt, source, strlen(source), 1000).status)
	js_runtime_free(rt)

int main(int argc, int argv):
	args_init(argc, argv)
	assert1(argc == 1 || strcmp(args_get(1), c"memory-basic") == 0 || strcmp(args_get(1), c"memory-prototype") == 0 || strcmp(args_get(1), c"memory-async") == 0 || strcmp(args_get(1), c"memory-limits") == 0)
	if (argc > 1): malloc_force_debug_mode()
	if (argc == 1 || strcmp(args_get(1), c"memory-basic") == 0): test_for_in_basic()
	if (argc == 1 || strcmp(args_get(1), c"memory-prototype") == 0): test_for_in_prototype()
	if (argc == 1 || strcmp(args_get(1), c"memory-async") == 0): test_for_in_async()
	if (argc == 1 || strcmp(args_get(1), c"memory-limits") == 0): test_for_in_limits()
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_for_in_test: OK")
	return 0
