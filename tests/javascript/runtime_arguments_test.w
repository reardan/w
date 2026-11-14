# wbuild: name=javascript_runtime_arguments_test
# wbuild: target=javascript_runtime_arguments_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 --strict tests/javascript/runtime_arguments_test.w -o bin/javascript_runtime_arguments_test"
# wbuild: step="bin/javascript_runtime_arguments_test" expect_stdout="javascript_runtime_arguments_test: OK"
# wbuild: step="bin/javascript_runtime_arguments_test memory-arguments" expect_stdout="javascript_runtime_arguments_test: OK"
# wbuild: step="bin/javascript_runtime_arguments_test memory-closures" expect_stdout="javascript_runtime_arguments_test: OK"
# wbuild: step="bin/javascript_runtime_arguments_test memory-slice-children" expect_stdout="javascript_runtime_arguments_test: OK"
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

void test_slice_children():
	js_runtime* rt = js_runtime_new()
	arguments_eval(rt, c"let slice=Array.prototype.slice;true;", 0)
	arguments_eval(rt, c"function children(){'use strict';return slice.call(arguments,2);}true;", 0)
	arguments_eval(rt, c"let c=children('div',{},'a','b');c.length===2 && c[0]==='a' && c[1]==='b';", 0)
	arguments_eval(rt, c"function sloppy(){return slice.call(arguments,1);}let s=sloppy(1,2,3);s.length===2 && s[0]===2 && s[1]===3;", 0)
	arguments_eval(rt, c"function spread(){return [...arguments];}let sp=spread(4,5);sp.length===2 && sp[1]===5;", 0)
	arguments_eval(rt, c"function iterate(){let total=0;for(const v of arguments)total+=v;return total;}iterate(1,2,3)===6;", 0)
	arguments_eval(rt, c"function tag(){return Object.prototype.toString.call(arguments);}tag()==='[object Arguments]';", 0)
	js_runtime_free(rt)

void test_arguments_limits():
	js_runtime* rt = js_runtime_new()
	arguments_eval(rt, c"function f(){'use strict';return arguments;}true;", 0)
	rt.max_properties = 3
	arguments_eval(rt, c"f(1,2,3);", 5)
	rt.max_properties = 10000
	arguments_eval(rt, c"function g(){return arguments.length;}function many(){return g(1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20);}true;", 0)
	# Copying and materializing the vector charges the evaluation budget.
	char* source = c"many();"
	assert_equal(5, js_runtime_eval(rt, source, strlen(source), 30).status)
	assert_equal(0, js_runtime_eval(rt, source, strlen(source), 2000).status)
	js_runtime_free(rt)

int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	if (argc == 1 || strcmp(args_get(1), c"memory-arguments") == 0): test_arguments()
	if (argc == 1 || strcmp(args_get(1), c"memory-closures") == 0): test_arguments_closures()
	if (argc == 1 || strcmp(args_get(1), c"memory-slice-children") == 0): test_slice_children()
	if (argc == 1 || strcmp(args_get(1), c"memory-limits") == 0): test_arguments_limits()
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_arguments_test: OK")
	return 0
