# wbuild: name=javascript_runtime_has_test
# wbuild: target=javascript_runtime_has_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 tests/javascript/runtime_has_test.w -o bin/javascript_runtime_has_test"
# wbuild: step="bin/javascript_runtime_has_test" expect_stdout="javascript_runtime_has_test: OK"
# wbuild: step="bin/javascript_runtime_has_test memory-basic" expect_stdout="javascript_runtime_has_test: OK"
# wbuild: step="bin/javascript_runtime_has_test memory-limits" expect_stdout="javascript_runtime_has_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

void has_eval(js_runtime* rt, char* source, int status):
	js_runtime_collect(rt)
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 10000)
	if (result.status != status || (status == 0 && result.value.number != 1.0)):
		println(source)
		println(result.message)
	assert_equal(status, result.status)
	if (status == 0):
		assert_equal(2, result.value.kind)
		assert1(result.value.number == 1.0)

void test_has_basic():
	js_runtime* rt = js_runtime_new()
	has_eval(rt, c"let object={present:undefined};'present' in object && !('missing' in object);", 0)
	has_eval(rt, c"let array=[];array[2]=undefined;'length' in array && 2 in array && !(0 in array) && !(3 in array);", 0)
	has_eval(rt, c"let keys={'null':0,'undefined':0,'true':0,'false':0,'NaN':0,'Infinity':0,'0':0,'-1':0,'1.5':0,'18446744073709551615':0};null in keys && undefined in keys && true in keys && false in keys && (0/0) in keys && (1/0) in keys && -0 in keys && -1 in keys && 1.5 in keys && 18446744073709551615n in keys;", 0)
	has_eval(rt, c"let log='';let key={toString:function(){log+='t';return 'present';},valueOf:function(){throw 99;}};key in object && log==='t';", 0)
	has_eval(rt, c"key={toString:function(){log+='t';return {};},valueOf:function(){log+='v';return 'present';}};log='';key in object && log==='tv';", 0)
	has_eval(rt, c"let called=0;key={toString:function(){called++;throw 99;}};let type=false;try{key in 1;}catch(e){type=e.name==='TypeError';}type && called===0;", 0)
	has_eval(rt, c"let caught=0;try{key in object;}catch(e){caught=e;}caught===99 && called===1;", 0)
	has_eval(rt, c"class Parent{method(){return 1;}}class Child extends Parent{}'method' in new Child();", 0)
	has_eval(rt, c"let parent={inherited:undefined};let child={own:1};let getter=function(){throw 42;};true;", 0)
	js_value* parent = js_runtime_get(rt, rt.global, c"parent")
	js_value* child = js_runtime_get(rt, rt.global, c"child")
	assert1(js_runtime_set_prototype(rt, child, parent))
	js_text* name = js_runtime_key(c"hidden")
	assert1(js_runtime_define_accessor(rt, parent, name, js_runtime_get(rt, rt.global, c"getter"), 0, 0, 1))
	js_text_free(name)
	has_eval(rt, c"'own' in child && 'inherited' in child && 'hidden' in child && !('missing' in child);", 0)
	name = js_text_new()
	# UTF-16 keys retain embedded NUL and lone surrogates.
	name.units.push(0)
	name.units.push(0xd800)
	assert1(js_runtime_define_data(rt, child, name, rt.undefined_value, 1, 1, 1))
	js_text_free(name)
	has_eval(rt, c"'\\0\\ud800' in child;", 0)
	has_eval(rt, c"Reflect.has(object,'present') && !Reflect.has(object,'missing') && Reflect.has(object,'toString') && Reflect.has(array,'length') && 'hasOwnProperty' in object;", 0)
	js_runtime_free(rt)

void test_has_limits():
	js_runtime* rt = js_runtime_new()
	has_eval(rt, c"'x' in null;", 2)
	has_eval(rt, c"'length' in 'text';", 2)
	has_eval(rt, c"'x' in false;", 2)
	has_eval(rt, c"'x' in 1n;", 2)
	has_eval(rt, c"let object={};true;", 0)
	js_value* object = js_runtime_get(rt, rt.global, c"object")
	js_value* current = object
	for i in range(8):
		js_value* parent = js_runtime_alloc(rt, 5)
		assert1(js_runtime_set_prototype(rt, current, parent))
		current = parent
	rt.max_depth = 4
	has_eval(rt, c"'missing' in object;", 5)
	rt.max_depth = 256
	char* source = c"'missing' in object;"
	assert_equal(5, js_runtime_eval(rt, source, strlen(source), 6).status)
	rt.max_properties = 3
	assert_equal(5, js_runtime_eval(rt, source, strlen(source), 100).status)
	rt.max_properties = 10000
	rt.max_depth = 4
	char* reflected = c"Reflect.has(object,'missing');"
	assert_equal(5, js_runtime_eval(rt, reflected, strlen(reflected), 100000).status)
	rt.max_depth = 256
	assert_equal(5, js_runtime_eval(rt, reflected, strlen(reflected), 6).status)
	js_runtime_free(rt)

int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	if (argc == 1 || strcmp(args_get(1), c"memory-basic") == 0): test_has_basic()
	if (argc == 1 || strcmp(args_get(1), c"memory-limits") == 0): test_has_limits()
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_has_test: OK")
	return 0
