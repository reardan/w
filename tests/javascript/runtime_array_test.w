# wbuild: name=javascript_runtime_array_test
# wbuild: target=javascript_runtime_array_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 --strict tests/javascript/runtime_array_test.w -o bin/javascript_runtime_array_test"
# wbuild: step="bin/javascript_runtime_array_test" expect_stdout="javascript_runtime_array_test: OK"
# wbuild: step="bin/javascript_runtime_array_test memory-basic" expect_stdout="javascript_runtime_array_test: OK"
# wbuild: step="bin/javascript_runtime_array_test memory-prototype" expect_stdout="javascript_runtime_array_test: OK"
# wbuild: step="bin/javascript_runtime_array_test memory-limits" expect_stdout="javascript_runtime_array_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

void array_eval(js_runtime* rt, char* source, int status):
	js_runtime_collect(rt)
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 10000)
	if (result.status != status || (status == 0 && result.value.number != 1.0)):
		println(source)
		println(result.message)
	assert_equal(status, result.status)
	if (status == 0):
		assert_equal(2, result.value.kind)
		assert1(result.value.number == 1.0)

void test_array_basic():
	js_runtime* rt = js_runtime_new()
	array_eval(rt, c"let empty=Array();let also=new Array();Array.isArray(empty) && Array.isArray(also) && empty!==also && empty.length===0 && also.length===0;", 0)
	array_eval(rt, c"let holes=Array(3);holes.length===3 && !(0 in holes) && !(1 in holes) && !(2 in holes) && holes[0]===undefined;", 0)
	array_eval(rt, c"let dense=new Array(undefined);dense.length===1 && 0 in dense && dense[0]===undefined;", 0)
	array_eval(rt, c"let object={valueOf:function(){throw 99;}};let one=Array(object);one.length===1 && one[0]===object && Array('3')[0]==='3' && Array(3n)[0]===3n && Array(null)[0]===null;", 0)
	array_eval(rt, c"let items=Array(3,4,5);items.length===3 && items[0]===3 && items[2]===5 && new Array(-0).length===0;", 0)
	array_eval(rt, c"Array.isArray([]) && Array.isArray(Array.prototype) && !Array.isArray({}) && !Array.isArray({length:0}) && !Array.isArray(new Uint8Array(0)) && !Array.isArray(null) && !Array.isArray();", 0)
	array_eval(rt, c"let check=Array.isArray;let fake={constructor:Array};check(empty) && !check(fake) && !check('[]') && !check(1n);", 0)
	array_eval(rt, c"let f=Array;let array=f(2);array instanceof Array && array.constructor===Array && Array.prototype.constructor===Array && Array.name==='Array' && Array.length===1 && Array.isArray.length===1;", 0)
	js_runtime_free(rt)

void test_array_prototype():
	js_runtime* rt = js_runtime_new()
	array_eval(rt, c"let array=new Array(2);Array.prototype.extra=7;array.extra===7 && [].extra===7 && Array.prototype.length===0;", 0)
	array_eval(rt, c"Array.prototype[0]=42;array[0]===42 && 0 in array && Array.prototype.length===1;", 0)
	array_eval(rt, c"array[0]=9;array[0]===9 && Array.prototype[0]===42 && array.length===2;", 0)
	array_eval(rt, c"let names='';for(const key in Array)names+=key;names==='';", 0)
	array_eval(rt, c"'use strict';let caught=false;try{Array.prototype={};}catch(e){caught=e.name==='TypeError';}caught;", 0)
	array_eval(rt, c"let setter=function(){throw 73;};true;", 0)
	js_text* key = js_runtime_key(c"0")
	assert1(js_runtime_define_accessor(rt, rt.array_prototype, key, 0, js_runtime_get(rt, rt.global, c"setter"), 1, 1))
	js_text_free(key)
	array_eval(rt, c"let own=Array('x','y');own[0]==='x' && own.length===2;", 0)
	js_value* own = js_runtime_get(rt, rt.global, c"own")
	key = js_runtime_key(c"0")
	js_value* property = js_runtime_property(own, key)
	assert1(property != 0 && property.writable && property.enumerable && property.configurable && property.accessor == 0)
	js_text_free(key)
	# The brand does not depend on the current prototype or its constructor.
	assert1(js_runtime_set_prototype(rt, own, 0))
	array_eval(rt, c"Array.isArray(own);", 0)
	js_value* fake = js_runtime_alloc(rt, 5)
	assert1(js_runtime_set_prototype(rt, fake, rt.array_prototype))
	js_runtime_set(rt, rt.global, c"fake", fake)
	array_eval(rt, c"fake instanceof Array && !Array.isArray(fake);", 0)
	js_runtime_free(rt)

void test_array_limits():
	js_runtime* rt = js_runtime_new()
	array_eval(rt, c"let count=0;try{Array(-1);}catch(e){if(e.name==='RangeError')count++;}try{new Array(1.5);}catch(e){if(e.name==='RangeError')count++;}try{Array(0/0);}catch(e){if(e.name==='RangeError')count++;}try{Array(1/0);}catch(e){if(e.name==='RangeError')count++;}try{Array(4294967296);}catch(e){if(e.name==='RangeError')count++;}count===5;", 0)
	array_eval(rt, c"Array(4294967295);", 5)
	array_eval(rt, c"new Array.isArray([]);", 6)
	array_eval(rt, c"class Unsupported extends Array{}", 6)
	rt.max_properties = 8
	array_eval(rt, c"Array(8).length===8;", 0)
	array_eval(rt, c"Array(9);", 5)
	char* source = c"Array(1,2,3,4);"
	assert_equal(5, js_runtime_eval(rt, source, strlen(source), 8).status)
	rt.max_properties = 10000
	js_runtime_collect(rt)
	rt.max_values = rt.heap.length
	source = c"Array();"
	assert_equal(5, js_runtime_eval(rt, source, strlen(source), 100).status)
	js_runtime_free(rt)

int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	if (argc == 1 || strcmp(args_get(1), c"memory-basic") == 0): test_array_basic()
	if (argc == 1 || strcmp(args_get(1), c"memory-prototype") == 0): test_array_prototype()
	if (argc == 1 || strcmp(args_get(1), c"memory-limits") == 0): test_array_limits()
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_array_test: OK")
	return 0
