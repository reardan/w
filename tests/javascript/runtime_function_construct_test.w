# wbuild: name=javascript_runtime_function_construct_test
# wbuild: target=javascript_runtime_function_construct_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 --strict tests/javascript/runtime_function_construct_test.w -o bin/javascript_runtime_function_construct_test"
# wbuild: step="bin/javascript_runtime_function_construct_test" expect_stdout="javascript_runtime_function_construct_test: OK"
# wbuild: step="bin/javascript_runtime_function_construct_test memory-basic" expect_stdout="javascript_runtime_function_construct_test: OK"
# wbuild: step="bin/javascript_runtime_function_construct_test memory-inherit" expect_stdout="javascript_runtime_function_construct_test: OK"
# wbuild: step="bin/javascript_runtime_function_construct_test memory-limits" expect_stdout="javascript_runtime_function_construct_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

void construct_eval(js_runtime* rt, char* source, int status):
	js_runtime_collect(rt)
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 10000)
	if (result.status != status || (status == 0 && result.value.number != 1.0)):
		println(source)
		println(result.message)
	assert_equal(status, result.status)
	if (status == 0): assert1(result.value.number == 1.0)

void test_construct_basic():
	js_runtime* rt = js_runtime_new()
	construct_eval(rt, c"function Point(x){this.x=x;}Point.prototype.read=function(){return this.x;};let point=new Point(7);point.read()===7 && point instanceof Point && point.constructor===Point;", 0)
	construct_eval(rt, c"let other=new Point(9);point!==other && point.x===7 && other.x===9 && Point.prototype.constructor===Point;", 0)
	construct_eval(rt, c"function Primitive(){this.x=1;return 99;}new Primitive().x===1;", 0)
	construct_eval(rt, c"function Replacement(){this.x=1;return {x:2};}let replacement=new Replacement();replacement.x===2 && !(replacement instanceof Replacement);", 0)
	construct_eval(rt, c"let Named=function Inner(x){this.x=x;this.same=Inner===Named;};let named=new Named(4);named.same && named.x===4 && named instanceof Named;", 0)
	construct_eval(rt, c"function Defaults(a,b=2,...rest){this.n=a+b+rest.length;}Defaults.length===1 && new Defaults(1,undefined,7,8).n===5;", 0)
	construct_eval(rt, c"function NoArgs(){this.value=3;}let call={go:NoArgs};call.go();call.value===3;", 0)
	construct_eval(rt, c"let names='';for(const key in Point)names+=key;names==='';", 0)
	js_value* point = js_runtime_get(rt, rt.global, c"Point")
	js_text* key = js_runtime_key(c"prototype")
	js_value* descriptor = js_runtime_property(point, key)
	assert1(descriptor.writable && descriptor.enumerable == 0 && descriptor.configurable == 0)
	js_text_free(key)
	key = js_runtime_key(c"constructor")
	descriptor = js_runtime_property(js_runtime_get(rt, point, c"prototype"), key)
	assert1(descriptor.writable && descriptor.enumerable == 0 && descriptor.configurable)
	js_text_free(key)
	js_runtime_free(rt)

void test_construct_inherit():
	js_runtime* rt = js_runtime_new()
	construct_eval(rt, c"function Base(x){this.x=x;}Base.prototype.read=function(){return this.x;};class Child extends Base{constructor(x){super(x);this.y=2;}}let child=new Child(4);child.read()===4 && child.y===2 && child instanceof Child && child instanceof Base;", 0)
	construct_eval(rt, c"class Default extends Base{}let value=new Default(9);value.read()===9 && value instanceof Default;", 0)
	construct_eval(rt, c"function Shared(){return {x:3};}class Derived extends Shared{constructor(){super();this.y=4;}}let returned=new Derived();returned.x+returned.y===7 && !(returned instanceof Derived);", 0)
	construct_eval(rt, c"function C(){this.tag=1;}let old=new C();let oldPrototype=C.prototype;C.prototype={value:7};let fresh=new C();old instanceof C===false && fresh instanceof C && fresh.value===7 && oldPrototype.constructor===C;", 0)
	construct_eval(rt, c"C.prototype=null;let fallback=new C();fallback.tag===1;", 0)
	construct_eval(rt, c"function Arrow(){this.get=()=>this;}let arrow=new Arrow();arrow.get()===arrow;", 0)
	construct_eval(rt, c"let arrowFunction=()=>1;async function asyncFunction(){}class Methods{method(){}}!('prototype' in arrowFunction) && !('prototype' in asyncFunction) && !('prototype' in Methods.prototype.method);", 0)
	construct_eval(rt, c"new arrowFunction();", 2)
	construct_eval(rt, c"new asyncFunction();", 2)
	construct_eval(rt, c"new Methods.prototype.method();", 2)
	js_runtime_free(rt)

void test_construct_limits():
	js_runtime* rt = js_runtime_new()
	construct_eval(rt, c"function Throwing(){throw 73;}let caught=0;try{new Throwing();}catch(e){caught=e;}caught===73;", 0)
	rt.max_depth = 24
	construct_eval(rt, c"function Recursive(){new Recursive();}new Recursive();", 5)
	js_runtime_free(rt)
	for extra in range(12):
		rt = js_runtime_new()
		rt.max_values = rt.heap.length + extra
		char* source = c"function C(x){this.x=x;}new C(1);"
		js_completion* result = js_runtime_eval(rt, source, strlen(source), 1000)
		assert1(result.status == 0 || result.status == 5)
		assert_equal(0, rt.running)
		js_runtime_free(rt)

int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	if (argc == 1 || strcmp(args_get(1), c"memory-basic") == 0): test_construct_basic()
	if (argc == 1 || strcmp(args_get(1), c"memory-inherit") == 0): test_construct_inherit()
	if (argc == 1 || strcmp(args_get(1), c"memory-limits") == 0): test_construct_limits()
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_function_construct_test: OK")
	return 0
