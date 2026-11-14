# wbuild: name=javascript_runtime_string_replace_test
# wbuild: target=javascript_runtime_string_replace_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 tests/javascript/runtime_string_replace_test.w -o bin/javascript_runtime_string_replace_test"
# wbuild: step="bin/javascript_runtime_string_replace_test" expect_stdout="javascript_runtime_string_replace_test: OK"
# wbuild: step="bin/javascript_runtime_string_replace_test memory" expect_stdout="javascript_runtime_string_replace_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

# String.prototype.replace with string patterns is origin's (regexp_methods.w).
# These cross-check it against the earlier local suite; RegExp-specific cases
# are covered by javascript_runtime_string_regexp_test.
void string_replace_eval(js_runtime* rt, char* source, int status, int budget):
	js_runtime_collect(rt)
	js_completion* result = js_runtime_eval(rt, source, strlen(source), budget)
	if (result.status != status || (status == 0 && js_runtime_truth(result.value) == 0)):
		println(source)
		println(result.message)
	assert_equal(status, result.status)
	if (status == 0): assert1(js_runtime_truth(result.value))

int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	js_runtime* rt = js_runtime_new()
	string_replace_eval(rt, c"'abcabc'.replace('a',function(m,index,input){'use strict';return this===undefined && m==='a' && index===0 && input==='abcabc' ? 'X' : 'bad';})==='Xbcabc' && String.prototype.replace.length===2;", 0, 100000)
	string_replace_eval(rt, c"let n=0;'abc'.replace('z',function(){n++;return 'x';})==='abc' && n===0;", 0, 100000)
	string_replace_eval(rt, c"String.prototype.replace.call(121,2,function(){return {toString:function(){return 'X';}};})==='1X1';", 0, 100000)
	string_replace_eval(rt, c"let log='';let rec={toString:function(){log+='r';return 'abc';}};let search={toString:function(){log+='s';return 'b';}};let replacement={toString:function(){log+='v';return 'X';}};String.prototype.replace.call(rec,search,replacement)==='aXc' && log==='rsv';", 0, 100000)
	string_replace_eval(rt, c"let conversionError=0;try{'a'.replace('a',function(){return {toString:function(){throw 82;}};});}catch(e){conversionError=e;}conversionError===82;", 0, 100000)
	string_replace_eval(rt, c"let nul=String.fromCharCode(0);(nul+'a').replace(nul,function(m,i){return m.length===1 && i===0 ? 'X' : 'bad';})==='Xa';", 0, 100000)
	string_replace_eval(rt, c"'a'.replace('a',function(){return '$&';})==='$&' && 'ab'.replace('a','$&$&')==='aab';", 0, 100000)
	string_replace_eval(rt, c"'aaa'.replace('a','b')==='baa' && 'abc'.replace('','X')==='Xabc' && ''.replace('','X')==='X' && 'abc'.replace('c','')==='ab';", 0, 100000)
	string_replace_eval(rt, c"let invalid=0;try{String.prototype.replace.call(null,'x',function(){return 'y';});}catch(e){invalid=e.constructor===TypeError;}invalid;", 0, 100000)
	# Budget exhaustion is reported (status 5) for scans and copies.
	string_replace_eval(rt, c"'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'.replace('b','c');", 5, 20)
	rt.max_properties = 64
	string_replace_eval(rt, c"'aaaaaaaa'.replace('a','1234567890123456789012345678901234567890123456789012345678901234567890');", 5, 100000)
	rt.max_properties = 10000
	js_runtime_free(rt)
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_string_replace_test: OK")
	return 0
