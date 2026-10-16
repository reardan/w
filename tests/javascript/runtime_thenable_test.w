# wbuild: name=javascript_runtime_thenable_test
# wbuild: target=javascript_runtime_thenable_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 tests/javascript/runtime_thenable_test.w -o bin/javascript_runtime_thenable_test"
# wbuild: step="bin/javascript_runtime_thenable_test" expect_stdout="javascript_runtime_thenable_test: OK"
# wbuild: step="bin/javascript_runtime_thenable_test memory-order" expect_stdout="javascript_runtime_thenable_test: OK"
# wbuild: step="bin/javascript_runtime_thenable_test memory-await" expect_stdout="javascript_runtime_thenable_test: OK"
# wbuild: step="bin/javascript_runtime_thenable_test memory-finally" expect_stdout="javascript_runtime_thenable_test: OK"
# wbuild: step="bin/javascript_runtime_thenable_test memory-getters" expect_stdout="javascript_runtime_thenable_test: OK"
# wbuild: step="bin/javascript_runtime_thenable_test memory-pending" expect_stdout="javascript_runtime_thenable_test: OK"
# wbuild: step="bin/javascript_runtime_thenable_test memory-limits" expect_stdout="javascript_runtime_thenable_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

void thenable_eval(js_runtime* rt, char* source):
	js_runtime_collect(rt)
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 10000)
	if (result.status != 0): println(result.message)
	assert_equal(0, result.status)
	assert1(result.value.number == 1.0)

void test_thenable_order():
	js_runtime* rt = js_runtime_new()
	thenable_eval(rt, c"let log='';let result=0;const obj={then(resolve,reject){log+='t';resolve({then(r){r(7);}});reject(9);throw 10;}};Promise.resolve(obj).then(x=>{result=x;log+='r';});log+='s';log==='s' && result===0;")
	js_runtime_collect(rt)
	assert_equal(0, js_runtime_drain_microtasks(rt, 10000).status)
	thenable_eval(rt, c"log==='str' && result===7;")
	thenable_eval(rt, c"let receiver=false;const t={then(resolve){receiver=this===t;resolve(3);resolve(4);}};Promise.resolve(t).then(x=>{result=x;});true;")
	assert_equal(0, js_runtime_drain_microtasks(rt, 10000).status)
	thenable_eval(rt, c"receiver && result===3;")
	js_runtime_free(rt)

void test_thenable_await():
	js_runtime* rt = js_runtime_new()
	thenable_eval(rt, c"let answer=0;async function f(){return await {then(resolve){resolve(42);}};}f().then(v=>{answer=v;});answer===0;")
	js_runtime_collect(rt)
	assert_equal(0, js_runtime_drain_microtasks(rt, 10000).status)
	thenable_eval(rt, c"answer===42;")
	thenable_eval(rt, c"let error=0;Promise.resolve({then(){throw 13;}}).catch(e=>{error=e;});true;")
	assert_equal(0, js_runtime_drain_microtasks(rt, 10000).status)
	thenable_eval(rt, c"error===13;")
	js_runtime_free(rt)

void test_finally():
	js_runtime* rt = js_runtime_new()
	thenable_eval(rt, c"let log='';let value=0;let release;const p=new Promise(r=>{release=r;});Promise.resolve(7).finally(()=>{log+='f';return p;}).then(x=>{value=x;});true;")
	assert_equal(0, js_runtime_drain_microtasks(rt, 10000).status)
	thenable_eval(rt, c"log==='f' && value===0;")
	thenable_eval(rt, c"release(99);true;")
	js_runtime_collect(rt)
	assert_equal(0, js_runtime_drain_microtasks(rt, 10000).status)
	thenable_eval(rt, c"value===7;")
	js_runtime_free(rt)
	rt = js_runtime_new()
	thenable_eval(rt, c"let value=0;Promise.reject(8).finally(()=>({then(r){r(9);}})).catch(e=>{value=e;});true;")
	assert_equal(0, js_runtime_drain_microtasks(rt, 10000).status)
	thenable_eval(rt, c"value===8;")
	js_runtime_free(rt)
	rt = js_runtime_new()
	thenable_eval(rt, c"let value=0;Promise.resolve(1).finally(()=>{throw 5;}).catch(e=>{value=e;});true;")
	assert_equal(0, js_runtime_drain_microtasks(rt, 10000).status)
	thenable_eval(rt, c"value===5;")
	thenable_eval(rt, c"Promise.reject(2).finally(()=>Promise.reject(6)).catch(e=>{value=e;});true;")
	assert_equal(0, js_runtime_drain_microtasks(rt, 10000).status)
	thenable_eval(rt, c"value===6;")
	js_runtime_free(rt)
	rt = js_runtime_new()
	thenable_eval(rt, c"let value=0;Promise.resolve(11).finally(99).then(x=>{value=x;});true;")
	assert_equal(0, js_runtime_drain_microtasks(rt, 10000).status)
	thenable_eval(rt, c"value===11;")
	js_runtime_free(rt)

void thenable_accessor(js_runtime* rt, char* source):
	js_completion* compiled = js_runtime_eval(rt, source, strlen(source), 10000)
	assert_equal(0, compiled.status)
	js_value* getter = compiled.value
	js_value* object = js_runtime_get(rt, rt.global, c"object")
	js_text* key = js_runtime_key(c"then")
	assert1(js_runtime_define_accessor(rt, object, key, getter, 0, 1, 1))
	js_text_free(key)

void test_thenable_getters():
	js_runtime* rt = js_runtime_new()
	thenable_eval(rt, c"let log='';let value=0;let resolve;let reject;const object={};const p=new Promise((r,j)=>{resolve=r;reject=j;});p.then(x=>{value=x;},e=>{value=-e;});true;")
	thenable_accessor(rt, c"(function(){log+='g';reject(99);return function(r){log+='t';r(8);};});")
	thenable_eval(rt, c"resolve(object);log+='s';log==='gs' && value===0;")
	js_runtime_collect(rt)
	assert_equal(0, js_runtime_drain_microtasks(rt, 10000).status)
	thenable_eval(rt, c"log==='gst' && value===8;")
	js_runtime_free(rt)
	rt = js_runtime_new()
	thenable_eval(rt, c"let log='';let value=0;const object={};true;")
	thenable_accessor(rt, c"(function(){log+='g';throw 17;});")
	thenable_eval(rt, c"Promise.resolve(object).catch(e=>{value=e;});log==='g' && value===0;")
	js_runtime_collect(rt)
	assert_equal(0, js_runtime_drain_microtasks(rt, 10000).status)
	thenable_eval(rt, c"value===17;")
	js_runtime_free(rt)
	rt = js_runtime_new()
	thenable_eval(rt, c"let value=0;const inner=Promise.resolve(5);inner.then=r=>r(9);new Promise(r=>r(inner)).then(x=>{value=x;});true;")
	assert_equal(0, js_runtime_drain_microtasks(rt, 10000).status)
	thenable_eval(rt, c"value===9;")
	thenable_eval(rt, c"let cycle;let name='';cycle=Promise.resolve().then(()=>cycle);cycle.catch(e=>{name=e.name;});true;")
	assert_equal(0, js_runtime_drain_microtasks(rt, 10000).status)
	thenable_eval(rt, c"name==='TypeError';")
	js_runtime_free(rt)


void test_thenable_pending():
	js_runtime* rt = js_runtime_new()
	thenable_eval(rt, c"let release;let reject;let answer=0;Promise.resolve({then(r,j){release=r;reject=j;}}).then(x=>{answer=x;});true;")
	assert_equal(0, js_runtime_drain_microtasks(rt, 10000).status)
	js_runtime_collect(rt)
	thenable_eval(rt, c"let innerRelease;const inner=new Promise(r=>{innerRelease=r;});release(inner);reject(99);answer===0;")
	assert_equal(0, js_runtime_drain_microtasks(rt, 10000).status)
	thenable_eval(rt, c"innerRelease(7);answer===0;")
	js_runtime_collect(rt)
	assert_equal(0, js_runtime_drain_microtasks(rt, 10000).status)
	thenable_eval(rt, c"answer===7;")
	js_runtime_free(rt)
	rt = js_runtime_new()
	thenable_eval(rt, c"let count=0;let same=false;const object={};true;")
	thenable_accessor(rt, c"(function(){count++;return 17;});")
	thenable_eval(rt, c"Promise.resolve(object).then(x=>{same=x===object;});count===1;")
	assert_equal(0, js_runtime_drain_microtasks(rt, 10000).status)
	thenable_eval(rt, c"same && count===1;")
	js_runtime_free(rt)


void test_thenable_limits():
	js_runtime* rt = js_runtime_new()
	thenable_eval(rt, c"const t={then(resolve){resolve(t);}};Promise.resolve(t);true;")
	assert_equal(5, js_runtime_drain_microtasks(rt, 100).status)
	assert1(rt.microtasks.length <= 1)
	js_runtime_free(rt)
	rt = js_runtime_new()
	rt.max_microtasks = 0
	char* source = c"Promise.resolve({then(resolve){resolve(1);}});"
	assert_equal(5, js_runtime_eval(rt, source, strlen(source), 10000).status)
	js_runtime_free(rt)

# Separate debug processes bound allocator bookkeeping/guard-map pressure while
# preserving every semantic case and asserting zero leaks for each group.
int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	if (argc == 1 || strcmp(args_get(1), c"memory-order") == 0): test_thenable_order()
	if (argc == 1 || strcmp(args_get(1), c"memory-await") == 0): test_thenable_await()
	if (argc == 1 || strcmp(args_get(1), c"memory-finally") == 0): test_finally()
	if (argc == 1 || strcmp(args_get(1), c"memory-getters") == 0): test_thenable_getters()
	if (argc == 1 || strcmp(args_get(1), c"memory-pending") == 0): test_thenable_pending()
	if (argc == 1 || strcmp(args_get(1), c"memory-limits") == 0): test_thenable_limits()
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_thenable_test: OK")
	return 0
