# wbuild: name=javascript_runtime_string_case_test
# wbuild: target=javascript_runtime_string_case_test tag=tests dep=javascript_parser
# wbuild: step="python3 tools/javascript_unicode_case.py --check"
# wbuild: step="bin/wv2 x64 tests/javascript/runtime_string_case_test.w -o bin/javascript_runtime_string_case_test"
# wbuild: step="bin/javascript_runtime_string_case_test" expect_stdout="javascript_runtime_string_case_test: OK"
# wbuild: step="bin/javascript_runtime_string_case_test memory-basic" expect_stdout="javascript_runtime_string_case_test: OK"
# wbuild: step="bin/javascript_runtime_string_case_test memory-context" expect_stdout="javascript_runtime_string_case_test: OK"
# wbuild: step="bin/javascript_runtime_string_case_test memory-limits" expect_stdout="javascript_runtime_string_case_test: OK"
# wbuild: step="bin/wv2 x64 tests/javascript/string_case_probe.w -o bin/javascript_string_case_probe"
# wbuild: step="python3 tools/javascript_string_case_compare.py bin/javascript_string_case_probe"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

void case_eval(js_runtime* rt, char* source):
	js_runtime_collect(rt)
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 100000)
	if (result.status != 0 || js_runtime_truth(result.value) == 0):
		println(source)
		println(result.message)
	assert_equal(0, result.status)
	assert1(js_runtime_truth(result.value))

void case_basic():
	js_runtime* rt = js_runtime_new()
	case_eval(rt, c"'onClick'.toLowerCase()==='onclick' && 'aZ09'.toUpperCase()==='AZ09' && ''.toLowerCase()==='' && 'éÉ'.toUpperCase()==='ÉÉ';")
	case_eval(rt, c"'Straße ﬃ ŉ'.toUpperCase()==='STRASSE FFI ʼN' && 'İ'.toLowerCase()==='i\\u0307' && 'iı'.toUpperCase()==='II' && 'I'.toLowerCase()==='i';")
	case_eval(rt, c"'𐐀𐐨'.toLowerCase()==='𐐨𐐨' && '𐐀𐐨'.toUpperCase()==='𐐀𐐀' && '😀中文'.toUpperCase()==='😀中文';")
	case_eval(rt, c"'A\\u0000B\\ud800C\\udfff'.toLowerCase()==='a\\u0000b\\ud800c\\udfff' && 'a\\u0000b\\ud800c\\udfff'.toUpperCase()==='A\\u0000B\\ud800C\\udfff';")
	case_eval(rt, c"''.toLowerCase===String.prototype.toLowerCase && 'x'.constructor===String && ''.toUpperCase.name==='toUpperCase' && ''.toLowerCase.length===0;")
	case_eval(rt, c"let order='';let object={toString(){order+='s';return {};},valueOf(){order+='v';return 'ABC';}};''.toLowerCase.call(object)==='abc' && order==='sv';")
	case_eval(rt, c"let reason={};let caught=false;try{''.toUpperCase.call({toString(){throw reason;}});}catch(e){caught=e===reason;}caught;")
	case_eval(rt, c"let count=0;try{''.toLowerCase.call(null);}catch(e){if(e.name==='TypeError')count++;}try{''.toUpperCase.call(undefined);}catch(e){if(e.name==='TypeError')count++;}count===2 && ''.toLowerCase.call(12)==='12' && ''.toUpperCase.call(true)==='TRUE';")
	js_runtime_free(rt)

void case_context():
	js_runtime* rt = js_runtime_new()
	case_eval(rt, c"'ΟΣ'.toLowerCase()==='ος' && 'ΟΣΑ'.toLowerCase()==='οσα' && 'Σ'.toLowerCase()==='σ' && '1Σ'.toLowerCase()==='1σ';")
	case_eval(rt, c"'AΣ\\u0301'.toLowerCase()==='aς\\u0301' && 'AΣ\\u0301A'.toLowerCase()==='aσ\\u0301a' && 'A\\u0301Σ'.toLowerCase()==='a\\u0301ς';")
	case_eval(rt, c"'AΣ\\u0027'.toLowerCase()==='aς\\u0027' && 'AΣ\\u0027A'.toLowerCase()==='aσ\\u0027a' && 'A Σ'.toLowerCase()==='a σ';")
	case_eval(rt, c"'\\u0345Σ'.toLowerCase()==='\\u0345σ' && 'A\\u0345Σ'.toLowerCase()==='a\\u0345ς' && 'AΣ\\u0345A'.toLowerCase()==='aσ\\u0345a';")
	case_eval(rt, c"'𐐀Σ'.toLowerCase()==='𐐨ς' && 'AΣ𐐀'.toLowerCase()==='aσ𐐨' && 'AΣ\\ud800'.toLowerCase()==='aς\\ud800';")
	case_eval(rt, c"'AΣΣ'.toLowerCase()==='aσς' && 'ΐ'.toUpperCase()==='Ι\\u0308\\u0301' && 'ᾀ'.toUpperCase()==='ἈΙ';")
	js_runtime_free(rt)

void case_limits():
	js_runtime* rt = js_runtime_new()
	case_eval(rt, c"const expand='ßß';const context='AΣ\\u0301\\u0301\\u0301\\u0301\\u0301';true;")
	js_value* expand = js_runtime_get(rt, rt.global, c"expand")
	js_value* context = js_runtime_get(rt, rt.global, c"context")
	list[js_value*] args = new list[js_value*]
	rt.max_properties = 3
	js_runtime_begin(rt, 1000)
	rt.running = 1
	js_string_case(rt, cast(void*, 1), expand, args)
	assert_equal(5, rt.completion.status)
	rt.max_properties = 10000
	js_runtime_begin(rt, 3)
	js_string_case(rt, 0, context, args)
	assert_equal(5, rt.completion.status)
	rt.running = 0
	js_runtime_collect(rt)
	js_runtime_begin(rt, 1000)
	rt.running = 1
	rt.max_values = rt.heap.length
	js_string_case(rt, 0, expand, args)
	assert_equal(5, rt.completion.status)
	rt.running = 0
	__w_list_free(cast(__w_list*, args))
	js_runtime_free(rt)

int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	if (argc == 1 || strcmp(args_get(1), c"memory-basic") == 0): case_basic()
	if (argc == 1 || strcmp(args_get(1), c"memory-context") == 0): case_context()
	if (argc == 1 || strcmp(args_get(1), c"memory-limits") == 0): case_limits()
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_string_case_test: OK")
	return 0
