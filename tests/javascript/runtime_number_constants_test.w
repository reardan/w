# wbuild: name=javascript_runtime_number_constants_test
# wbuild: target=javascript_runtime_number_constants_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 --strict tests/javascript/runtime_number_constants_test.w -o bin/javascript_runtime_number_constants_test"
# wbuild: step="bin/javascript_runtime_number_constants_test" expect_stdout="javascript_runtime_number_constants_test: OK"
# wbuild: step="bin/javascript_runtime_number_constants_test memory" expect_stdout="javascript_runtime_number_constants_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

void constants_eval(js_runtime* rt, char* source):
	js_runtime_collect(rt)
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 100000)
	if (result.status != 0 || result.value.number != 1.0): println(source)
	assert_equal(0, result.status)
	assert1(result.value.number == 1.0)

int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	js_runtime* rt = js_runtime_new()
	constants_eval(rt, c"Number.MAX_VALUE===1.7976931348623157e308 && Number.MIN_VALUE===5e-324 && Number.MIN_VALUE/2===0 && Number.MAX_VALUE*2===Infinity;")
	constants_eval(rt, c"Number.MAX_SAFE_INTEGER===9007199254740991 && Number.MIN_SAFE_INTEGER===-9007199254740991 && Number.EPSILON===2.220446049250313e-16 && Number.POSITIVE_INFINITY===Infinity && Number.NEGATIVE_INFINITY===-Infinity && Object.is(Number.NaN,NaN);")
	constants_eval(rt, c"let names=['MAX_VALUE','MIN_VALUE','MAX_SAFE_INTEGER','MIN_SAFE_INTEGER','EPSILON','NaN','POSITIVE_INFINITY','NEGATIVE_INFINITY'];let correct=true;for(let i=0;i<names.length;i++){let name=names[i];let descriptor=Object.getOwnPropertyDescriptor(Number,name);if(!descriptor||descriptor.writable||descriptor.enumerable||descriptor.configurable||!Object.is(descriptor.value,Number[name]))correct=false;let old=Number[name];Number[name]=19;if(!Object.is(Number[name],old)||Reflect.deleteProperty(Number,name)||Reflect.defineProperty(Number,name,{value:19}))correct=false;}correct;")
	constants_eval(rt, c"let rejected=0;for(let i=0;i<names.length;i++){try{(function(){'use strict';Number[names[i]]=17;})();}catch(e){if(e.constructor===TypeError)rejected++;}}rejected===8;")
	constants_eval(rt, c"Object.getOwnPropertyNames(Number).indexOf('MAX_VALUE')>=0 && Object.keys(Number).length===0 && !Object.hasOwn(Number.prototype,'MAX_VALUE');")
	js_value* number = js_runtime_get(rt, rt.global, c"Number")
	assert1(float64_bits(js_runtime_get(rt, number, c"MAX_VALUE").number) == (0x7ff << 52) - 1)
	assert_equal(1, float64_bits(js_runtime_get(rt, number, c"MIN_VALUE").number))
	js_runtime_free(rt)
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_number_constants_test: OK")
	return 0
