# wbuild: name=javascript_modules_mutable_test
# wbuild: target=javascript_modules_mutable_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 --strict tests/javascript/modules_mutable_test.w -o bin/javascript_modules_mutable_test"
# wbuild: step="bin/javascript_modules_mutable_test" expect_stdout="javascript_modules_mutable_test: OK"
# wbuild: step="bin/javascript_modules_mutable_test memory-live" expect_stdout="javascript_modules_mutable_test: OK"
# wbuild: step="bin/javascript_modules_mutable_test memory-declarations" expect_stdout="javascript_modules_mutable_test: OK"
# wbuild: step="bin/javascript_modules_mutable_test memory-async" expect_stdout="javascript_modules_mutable_test: OK"
# wbuild: step="bin/javascript_modules_mutable_test memory-negative" expect_stdout="javascript_modules_mutable_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.modules

struct mutable_fixture:
	list[js_module_source*] sources

void mutable_add(mutable_fixture* fixture, char* name, char* source):
	js_module_source* record = new js_module_source()
	record.identifier = name
	record.source = source
	record.length = strlen(source)
	fixture.sources.push(record)

js_module_source* mutable_resolve(void* context, char* name, char* referrer):
	mutable_fixture* fixture = cast(mutable_fixture*, context)
	for i in range(fixture.sources.length):
		if (strcmp(fixture.sources[i].identifier, name) == 0): return fixture.sources[i]
	return 0

void mutable_free(mutable_fixture* fixture):
	for i in range(fixture.sources.length): free(fixture.sources[i])
	__w_list_free(cast(__w_list*, fixture.sources))

js_module* mutable_evaluate(js_modules* modules, char* name):
	js_module* entry = js_modules_evaluate(modules, name, c"", 10000)
	if (entry == 0): println(modules.runtime.completion.message)
	assert1(entry != 0)
	assert_equal(0, modules.runtime.completion.status)
	return entry

js_value* mutable_call(js_runtime* rt, js_value* callable):
	list[js_value*] args = new list[js_value*]
	js_completion* result = js_runtime_invoke(rt, callable, args, 10000)
	__w_list_free(cast(__w_list*, args))
	if (result.status != 0): println(result.message)
	assert_equal(0, result.status)
	return result.value

void mutable_eval(js_runtime* rt, char* source):
	js_runtime_collect(rt)
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 10000)
	if (result.status != 0): println(result.message)
	assert_equal(0, result.status)
	assert1(result.value.number == 1.0)

void test_mutable_live():
	mutable_fixture fixture
	fixture.sources = new list[js_module_source*]
	mutable_add(&fixture, c"dep", c"export let count=0;export var value=1;export let box={n:1};export function inc(){count++;value+=2;box={n:count+1};}export function f(){return 1;}export function replace(){f=()=>2;}")
	mutable_add(&fixture, c"mid", c"import {count as n,value,box,inc,f,replace} from 'dep';export {n as count,value,box,inc,f,replace};")
	mutable_add(&fixture, c"root", c"import {count,value,box,inc,f,replace} from 'mid';export {inc,box,replace};export function read(){return count*100+value;}export function call(){return f();}export function readonly(){let n=0;try{count=99;}catch(e){n++;}try{count++;}catch(e){n++;}try{count+=1;}catch(e){n++;}return n===3 && count===1;}")
	js_runtime* rt = js_runtime_new()
	js_modules* modules = js_modules_new(rt, mutable_resolve, &fixture)
	js_module* root = mutable_evaluate(modules, c"root")
	js_module* dep = mutable_evaluate(modules, c"dep")
	js_value* read = js_modules_export(modules, root, c"read")
	js_value* inc = js_modules_export(modules, root, c"inc")
	assert1(mutable_call(rt, read).number == 1.0)
	js_value* old_box = js_modules_export(modules, root, c"box")
	js_runtime_root(rt, old_box)
	mutable_call(rt, inc)
	js_runtime_collect(rt)
	assert1(mutable_call(rt, read).number == 103.0)
	assert1(js_modules_export(modules, root, c"box") == js_modules_export(modules, dep, c"box"))
	assert1(js_modules_export(modules, root, c"box") != old_box)
	assert1(js_runtime_get(rt, old_box, c"n").number == 1.0)
	assert1(mutable_call(rt, js_modules_export(modules, root, c"readonly")).number == 1.0)
	assert1(mutable_call(rt, js_modules_export(modules, root, c"call")).number == 1.0)
	mutable_call(rt, js_modules_export(modules, root, c"replace"))
	assert1(mutable_call(rt, js_modules_export(modules, root, c"call")).number == 2.0)
	js_runtime_unroot(rt, old_box)
	# Reexport chains retain the existing alias-depth bound.
	js_runtime_begin(rt, 100)
	rt.max_depth = 1
	js_modules_export(modules, root, c"box")
	assert_equal(5, rt.completion.status)
	rt.max_depth = 256
	# Borrowed live bindings remain valid through rooted importing closures.
	js_runtime_root(rt, read)
	js_runtime_root(rt, inc)
	js_modules_free(modules)
	js_runtime_collect(rt)
	mutable_call(rt, inc)
	js_runtime_collect(rt)
	assert1(mutable_call(rt, read).number == 205.0)
	js_runtime_unroot(rt, read)
	js_runtime_unroot(rt, inc)
	js_runtime_free(rt)
	mutable_free(&fixture)

void test_mutable_declarations():
	mutable_fixture fixture
	fixture.sources = new list[js_module_source*]
	mutable_add(&fixture, c"dep", c"export let {a,b}={a:1,b:2};export var [x]=[3];export class Box{value(){return 4;}}if(true){var nested=5;}export {nested};export function change(){a=10;b=20;x=30;Box=class {value(){return 40;}};nested=50;}")
	mutable_add(&fixture, c"root", c"import {a,b,x,Box,nested,change} from 'dep';export {change};export function read(){return a+b+x+new Box().value()+nested;}")
	js_runtime* rt = js_runtime_new()
	js_modules* modules = js_modules_new(rt, mutable_resolve, &fixture)
	js_module* root = mutable_evaluate(modules, c"root")
	assert1(mutable_call(rt, js_modules_export(modules, root, c"read")).number == 15.0)
	mutable_call(rt, js_modules_export(modules, root, c"change"))
	assert1(mutable_call(rt, js_modules_export(modules, root, c"read")).number == 150.0)
	js_modules_free(modules)
	js_runtime_free(rt)
	mutable_free(&fixture)

void test_mutable_async():
	mutable_fixture fixture
	fixture.sources = new list[js_module_source*]
	mutable_add(&fixture, c"dep", c"export let count=1;await pending;count=2;export function inc(){count++;}")
	mutable_add(&fixture, c"root", c"import {count,inc} from 'dep';export {inc};export function read(){return count;}")
	js_runtime* rt = js_runtime_new()
	mutable_eval(rt, c"let release;let pending=new Promise(r=>{release=r;});true;")
	js_modules* modules = js_modules_new(rt, mutable_resolve, &fixture)
	js_module* root = js_modules_evaluate_async(modules, c"root", c"", 10000)
	assert1(root != 0)
	assert_equal(2, root.state)
	assert1(js_modules_export(modules, root, c"read") == 0)
	js_runtime_collect(rt)
	mutable_eval(rt, c"release(0);true;")
	assert_equal(0, js_runtime_drain_microtasks(rt, 10000).status)
	assert_equal(3, root.state)
	assert1(mutable_call(rt, js_modules_export(modules, root, c"read")).number == 2.0)
	mutable_call(rt, js_modules_export(modules, root, c"inc"))
	js_runtime_collect(rt)
	assert1(mutable_call(rt, js_modules_export(modules, root, c"read")).number == 3.0)
	js_modules_free(modules)
	js_runtime_free(rt)
	mutable_free(&fixture)

void test_mutable_negative():
	mutable_fixture fixture
	fixture.sources = new list[js_module_source*]
	mutable_add(&fixture, c"missing", c"import 'dep';export {absent};")
	mutable_add(&fixture, c"duplicate", c"import 'dep';export let x=1;export {x};")
	mutable_add(&fixture, c"block", c"import 'dep';{let privateName=1;}export {privateName};")
	mutable_add(&fixture, c"dep", c"effects++;export let x=1;")
	mutable_add(&fixture, c"tdz", c"export {x};x;let x=1;")
	mutable_add(&fixture, c"hoisted", c"export var before=typeof x;if(true){var x=4;}export {x};")
	js_runtime* rt = js_runtime_new()
	mutable_eval(rt, c"let effects=0;true;")
	js_modules* modules = js_modules_new(rt, mutable_resolve, &fixture)
	assert1(js_modules_evaluate(modules, c"missing", c"", 10000) == 0)
	assert_equal(6, rt.completion.status)
	assert1(js_modules_evaluate(modules, c"duplicate", c"", 10000) == 0)
	assert_equal(6, rt.completion.status)
	assert1(js_modules_evaluate(modules, c"block", c"", 10000) == 0)
	assert_equal(6, rt.completion.status)
	mutable_eval(rt, c"effects===0; ")
	assert1(js_modules_evaluate(modules, c"tdz", c"", 10000) == 0)
	assert_equal(2, rt.completion.status)
	js_module* entry = mutable_evaluate(modules, c"hoisted")
	assert1(js_runtime_key_is(js_modules_export(modules, entry, c"before").text, c"undefined"))
	assert1(js_modules_export(modules, entry, c"x").number == 4.0)
	js_modules_free(modules)
	js_runtime_free(rt)
	mutable_free(&fixture)

int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	if (argc == 1 || strcmp(args_get(1), c"memory-live") == 0): test_mutable_live()
	if (argc == 1 || strcmp(args_get(1), c"memory-declarations") == 0): test_mutable_declarations()
	if (argc == 1 || strcmp(args_get(1), c"memory-async") == 0): test_mutable_async()
	if (argc == 1 || strcmp(args_get(1), c"memory-negative") == 0): test_mutable_negative()
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_modules_mutable_test: OK")
	return 0
