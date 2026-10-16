# wbuild: name=javascript_runtime_classes_test
# wbuild: target=javascript_runtime_classes_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 tests/javascript/runtime_classes_test.w -o bin/javascript_runtime_classes_test"
# wbuild: step="bin/javascript_runtime_classes_test" expect_stdout="javascript_runtime_classes_test: OK"
# wbuild: step="bin/javascript_runtime_classes_test memory" expect_stdout="javascript_runtime_classes_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime


void class_test_eval(js_runtime* rt, char* source, int status):
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 10000)
	if (result.status != status):
		println(source)
		println(result.message)
	assert_equal(status, result.status)
	if (status == 0): assert1(result.value.number == 1.0)


void class_test_source(char* source):
	js_runtime* rt = js_runtime_new()
	class_test_eval(rt, source, 0)
	js_runtime_free(rt)


void class_test_semantics():
	# Unchanged constructor and matching runStart catch from tools/web/wasi_lite.mjs.
	class_test_source(c"class WasiExit extends Error { constructor(code) { super(`proc_exit(${code})`); this.code = code; } } let code=-1; try{throw new WasiExit(7);}catch(e){if(e instanceof WasiExit && e instanceof Error && e.message==='proc_exit(7)')code=e.code;} code===7;")
	class_test_source(c"class A { constructor(x){this.x=x;} f(){return this.x;} static answer(){return 42;} } class B extends A {} class C extends B {} const c=new C(7); c.f()===7 && c instanceof A && c instanceof B && c instanceof C && c.constructor===C && C.answer()===42;")
	class_test_source(c"class A {} const a=new A(); a instanceof A && a.constructor===A && A.name==='A' && A.length===0;")
	class_test_source(c"class A { constructor(x,y=1,...rest){} } A.length===1;")
	class_test_source(c"const A=class Inner { self(){return Inner;} }; const a=new A(); a.self()===A && A.name==='Inner';")
	class_test_source(c"class A { constructor(){return {x:8};} } class B extends A {constructor(){super();this.y=2;}} let b=new B(); b.x+b.y===10 && !(b instanceof B);")
	class_test_source(c"class A{constructor(){return 9;}} class B extends A{constructor(){super();return undefined;}} new B() instanceof B;")
	class_test_source(c"class A{} class B extends A {constructor(){return {x:9};}} (new B()).x===9;")
	class_test_source(c"class A{} class B extends A {constructor(){const init=()=>super();init();const get=()=>this;this.get=get;}} const b=new B(); b.get()===b;")
	class_test_source(c"class A{} let n=0; try{A();}catch(e){if(e.name==='TypeError')n++;} try{new (A.prototype.constructor.prototype)();}catch(e){} n===1;")
	class_test_source(c"class A{} class B extends A {constructor(){this.x=1;super();}} let n=0;try{new B();}catch(e){if(e.name==='ReferenceError')n++;} n===1;")
	class_test_source(c"class A{} class B extends A {constructor(){}} let n=0;try{new B();}catch(e){if(e.name==='ReferenceError')n++;} n===1;")
	class_test_source(c"let n=0; class A{constructor(){n++;}} class B extends A{constructor(){super();super();}} try{new B();}catch(e){if(e.name==='ReferenceError')n+=10;} n===12;")
	class_test_source(c"class A{} class B extends A{constructor(){return 3;}} let n=0;try{new B();}catch(e){if(e.name==='TypeError')n++;} n===1;")
	class_test_source(c"let n=0;try{new A();}catch(e){if(e.name==='ReferenceError')n++;} class A{} try{class B extends B{}}catch(e){if(e.name==='ReferenceError')n++;} n===2;")
	class_test_source(c"let n=0;try{class A extends 1 {}}catch(e){if(e.name==='TypeError')n++;} class B extends null{} try{new B();}catch(e){if(e.name==='TypeError')n++;} n===2;")
	class_test_source(c"class A { f(){return this;} } let f=(new A()).f; f()===undefined;")
	class_test_source(c"class A { self(){return A;} } let old=A; A=9; (new old()).self()===old;")
	class_test_source(c"class A { mutate(){A=3;} } let n=0;try{(new A()).mutate();}catch(e){if(e.name==='TypeError')n++;} n===1;")
	class_test_source(c"class A{} let n=0;try{({}) instanceof 3;}catch(e){if(e.name==='TypeError')n++;} !(1 instanceof A) && !({} instanceof A) && n===1;")
	class_test_source(c"let saved=Error; Error=9; const e=new saved('ok'); e.message==='ok' && e.name==='Error' && e instanceof saved;")
	class_test_source(c"class A{} let n=0; try{missing;}catch(e){if(e instanceof Error && e instanceof ReferenceError)n++;} n===1;")


js_value* class_test_native(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	js_value* value = js_runtime_alloc(rt, 5)
	if (args.length > 0): js_runtime_set(rt, value, c"x", args[0])
	return value


void class_test_lifetime():
	js_runtime* rt = js_runtime_new()
	js_value* native = js_runtime_host_callable(rt, 0, class_test_native)
	native.host_construct = 2
	js_runtime_set(rt, rt.global, c"Native", native)
	class_test_eval(rt, c"let n=0;try{Native(7);}catch(e){if(e.name==='TypeError')n++;} (new Native(8)).x===8 && n===1;", 0)
	class_test_eval(rt, c"class Parent{constructor(x){this.x=x;} read(){return this.x;}} class Child extends Parent{constructor(x){super(x);this.get=()=>this;}} let child=new Child(12); child.read()===12;", 0)
	js_runtime_collect(rt)
	class_test_eval(rt, c"child.get()===child && child.read()===12 && child instanceof Child && child instanceof Parent;", 0)
	js_value* child = js_runtime_get(rt, rt.global, c"child")
	js_value* constructor = js_runtime_get(rt, rt.global, c"Child")
	js_value* prototype = js_runtime_get(rt, constructor, c"prototype")
	assert1(child.prototype == prototype)
	js_text* key = js_runtime_key(c"prototype")
	js_value* descriptor = js_runtime_property(constructor, key)
	assert_equal(0, descriptor.writable)
	assert_equal(0, descriptor.enumerable)
	assert_equal(0, descriptor.configurable)
	js_text_free(key)
	key = js_runtime_key(c"read")
	descriptor = js_runtime_property(js_runtime_get(rt, js_runtime_get(rt, rt.global, c"Parent"), c"prototype"), key)
	assert_equal(1, descriptor.writable)
	assert_equal(0, descriptor.enumerable)
	assert_equal(1, descriptor.configurable)
	js_text_free(key)
	js_runtime_free(rt)


void class_test_unsupported():
	js_runtime* rt = js_runtime_new()
	class_test_eval(rt, c"let side=0; true;", 0)
	class_test_eval(rt, c"side=1;class A{get x(){return 1;}}", 6)
	class_test_eval(rt, c"side=1;class A{['x'](){return 1;}}", 6)
	class_test_eval(rt, c"side=1;class A{f(){return super.x;}}", 6)
	class_test_eval(rt, c"side===0;", 0)
	js_runtime_free(rt)


void class_test_limits():
	js_runtime* rt = js_runtime_new()
	class_test_eval(rt, c"let C=class{}; for(let i=0;i<40;i++) C=class extends C{}; true;", 0)
	rt.max_depth = 16
	class_test_eval(rt, c"new C();", 5)
	js_runtime_free(rt)
	for extra in range(25):
		rt = js_runtime_new()
		rt.max_values = rt.heap.length + extra
		char* source = c"class A{constructor(x){this.x=x;} f(){return this.x;}} new A(1);"
		int status = js_runtime_eval(rt, source, strlen(source), 1000).status
		assert1(status == 0 || status == 5)
		assert1(rt.heap.length <= rt.max_values)
		if (status == 0): assert_equal(5, rt.completion.value.kind)
		js_runtime_free(rt)


int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	if (argc == 1):
		class_test_semantics()
		class_test_unsupported()
		class_test_limits()
	class_test_lifetime()
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_classes_test: OK")
	return 0
