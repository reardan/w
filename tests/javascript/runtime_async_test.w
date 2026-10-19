# wbuild: name=javascript_runtime_async_test
# wbuild: target=javascript_runtime_async_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 tests/javascript/runtime_async_test.w -o bin/javascript_runtime_async_test"
# wbuild: step="bin/javascript_runtime_async_test" expect_stdout="javascript_runtime_async_test: OK"
# wbuild: step="bin/javascript_runtime_async_test memory" expect_stdout="javascript_runtime_async_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime


void async_test_eval(js_runtime* rt, char* source):
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 10000)
	if (result.status != 0):
		println(source)
		println(result.message)
	assert_equal(0, result.status)
	assert1(result.value.number == 1.0)


void async_test_lifetime():
	js_runtime* rt = js_runtime_new()
	async_test_eval(rt, c"let log=''; let resolve; const pending=new Promise(r=>{resolve=r;}); async function f(){const object={x:7}; log+='a'; const value=await pending; log+='b'; return object.x+value;} let result=0; f().then(x=>{result=x;}); log==='a' && result===0;")
	assert_equal(1, rt.async_tasks.length)
	js_runtime_collect(rt)
	async_test_eval(rt, c"resolve(5); log==='a';")
	assert_equal(0, js_runtime_drain_microtasks(rt, 10000).status)
	async_test_eval(rt, c"log==='ab' && result===12;")
	assert_equal(0, rt.async_tasks.length)
	assert_equal(0, rt.async_stack_bytes)
	assert_equal(0, rt.async_root_count)
	js_runtime_free(rt)


void async_test_semantics():
	js_runtime* rt = js_runtime_new()
	async_test_eval(rt, c"let order=''; let value=0; async function f(){order+='a'; await 1; order+='b'; return 7;} f().then(x=>{value=x;order+='d';}); order+='c'; order==='ac' && value===0;")
	assert_equal(0, js_runtime_drain_microtasks(rt, 10000).status)
	async_test_eval(rt, c"order==='acbd' && value===7;")
	async_test_eval(rt, c"let final=''; async function g(){try {await Promise.reject(3);}catch(e){final+=String(e);}finally{await 0;final+='f';}return 9;} let answer=0; g().then(v=>{answer=v;}); final==='';")
	assert_equal(0, js_runtime_drain_microtasks(rt, 10000).status)
	async_test_eval(rt, c"final==='3f' && answer===9;")
	async_test_eval(rt, c"let rejected=0; async function bad(){throw 12;} bad().catch(e=>{rejected=e;}); rejected===0;")
	assert_equal(0, js_runtime_drain_microtasks(rt, 10000).status)
	async_test_eval(rt, c"rejected===12;")
	async_test_eval(rt, c"let nested=0; const arrow=async x=>{return (await x)+2;}; async function h(){return await arrow(await 3);} h().then(v=>{nested=v;}); true;")
	assert_equal(0, js_runtime_drain_microtasks(rt, 10000).status)
	async_test_eval(rt, c"nested===5;")
	async_test_eval(rt, c"let labels=0; async function labelled(){outer: for(let i=0;i<3;i++){await 0;for(let j=0;j<3;j++){if(j===1)continue outer;labels++;}} return labels;} labelled();true;")
	assert_equal(0, js_runtime_drain_microtasks(rt, 10000).status)
	async_test_eval(rt, c"labels===3;")
	js_runtime_free(rt)


void async_test_cancel():
	js_runtime* rt = js_runtime_new()
	async_test_eval(rt, c"let release; let ran=0; const p=new Promise(r=>{release=r;}); async function f(){try{await p;ran++;}finally{ran+=10;}} f(); true;")
	assert_equal(1, js_runtime_async_cancel(rt))
	assert_equal(0, rt.async_tasks.length)
	js_runtime_collect(rt)
	async_test_eval(rt, c"release(1);ran===0;")
	assert_equal(0, js_runtime_drain_microtasks(rt, 10000).status)
	async_test_eval(rt, c"ran===0;")
	js_runtime_free(rt)


void async_test_limits():
	js_runtime* rt = js_runtime_new()
	char* loop = c"async function loop(){while(true){await 1;}} loop();"
	assert_equal(0, js_runtime_eval(rt, loop, strlen(loop), 100).status)
	# A fresh, larger checkpoint must not replenish the task's original fuel.
	assert_equal(5, js_runtime_drain_microtasks(rt, 10000).status)
	assert_equal(0, rt.async_tasks.length)
	assert_equal(0, rt.async_root_count)
	js_runtime_free(rt)
	rt = js_runtime_new()
	rt.max_async_tasks = 1
	char* tasks = c"const p=new Promise(r=>{}); async function f(){await p;} f(); f();"
	assert_equal(5, js_runtime_eval(rt, tasks, strlen(tasks), 10000).status)
	assert_equal(0, rt.async_tasks.length)
	js_runtime_free(rt)
	rt = js_runtime_new()
	rt.max_async_roots = 1
	char* roots = c"async function f(){await 1;} f();"
	assert_equal(5, js_runtime_eval(rt, roots, strlen(roots), 10000).status)
	assert_equal(0, rt.async_tasks.length)
	js_runtime_free(rt)
	rt = js_runtime_new()
	rt.max_async_stack_bytes = 262143
	assert_equal(5, js_runtime_eval(rt, roots, strlen(roots), 10000).status)
	assert_equal(0, rt.async_stack_bytes)
	js_runtime_free(rt)


void async_test_native_temporaries():
	js_runtime* rt = js_runtime_new()
	# Suspend with an object and argument list still live only in evaluator locals.
	async_test_eval(rt, c"let resolve; const p=new Promise(r=>{resolve=r;}); let answer=0; function sum(a,b){return a.x+b;} async function f(){return sum({x:9},await p);} f().then(v=>{answer=v;});true;")
	js_runtime_collect(rt)
	async_test_eval(rt, c"resolve(3);true;")
	assert_equal(0, js_runtime_drain_microtasks(rt, 10000).status)
	async_test_eval(rt, c"answer===12;")
	js_runtime_free(rt)
	rt = js_runtime_new()
	async_test_eval(rt, c"const p=new Promise(r=>{}); function sum(a,b){return a+b;} async function f(){return sum({x:9},await p);} f();true;")
	js_runtime_collect(rt)
	assert_equal(1, js_runtime_async_cancel(rt))
	js_runtime_free(rt)


int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	async_test_lifetime()
	async_test_native_temporaries()
	if (argc == 1):
		async_test_semantics()
		async_test_cancel()
		async_test_limits()
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_async_test: OK")
	return 0
