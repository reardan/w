# wbuild: name=javascript_runtime_string_replace_test
# wbuild: target=javascript_runtime_string_replace_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 --strict tests/javascript/runtime_string_replace_test.w -o bin/javascript_runtime_string_replace_test"
# wbuild: step="bin/javascript_runtime_string_replace_test" expect_stdout="javascript_runtime_string_replace_test: OK"
# wbuild: step="bin/javascript_runtime_string_replace_test memory" expect_stdout="javascript_runtime_string_replace_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

void string_replace_eval(js_runtime* rt, char* source, int status):
	js_runtime_collect(rt)
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 100000)
	if (result.status != status || (status == 0 && result.value.number != 1.0)):
		println(source)
		println(result.message)
	assert_equal(status, result.status)
	if (status == 0): assert1(result.value.number == 1.0)

int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	js_runtime* rt = js_runtime_new()
	js_value* window = js_runtime_alloc(rt, 5)
	js_runtime_set(rt, window, c"self", window)
	assert1(js_runtime_set_global_object(rt, window))
	string_replace_eval(rt, c"'abcabc'.replace('a',function(m,index,input){'use strict';return this===undefined && m==='a' && index===0 && input==='abcabc' ? 'X' : 'bad';})==='Xbcabc' && String.prototype.replace.length===2;", 0)
	string_replace_eval(rt, c"let captures='';let output='ab'.replace(/(a)|(b)/g,function(m,a,b,index,input){captures+=(a===undefined?'_':a)+(b===undefined?'_':b)+index;return m+m;});output==='aabb' && captures==='a_0_b1';", 0)
	string_replace_eval(rt, c"let re=/a/g;let seen='';let out='aa'.replace(re,function(m,i){seen+=re.lastIndex;re.lastIndex=9;return i;});out==='01' && seen==='09' && re.lastIndex===9;", 0)
	string_replace_eval(rt, c"let empty=/(?:)/g;let positions='';'ab'.replace(empty,function(m,i){positions+=i;return '-';})==='-a-b-' && positions==='012' && empty.lastIndex===0;", 0)
	string_replace_eval(rt, c"let n=0;'abc'.replace('z',function(){n++;return 'x';})==='abc' && n===0;", 0)
	string_replace_eval(rt, c"String.prototype.replace.call(121,2,function(){return {toString:function(){return 'X';}};})==='1X1';", 0)
	string_replace_eval(rt, c"let log='';let rec={toString:function(){log+='r';return 'abc';}};let search={toString:function(){log+='s';return 'b';}};let replacement={toString:function(){log+='v';return 'X';}};String.prototype.replace.call(rec,search,replacement)==='aXc' && log==='rsv';", 0)
	string_replace_eval(rt, c"let rx=/a/g;let builtin=rx.exec;let stages='';Object.defineProperty(rx,'exec',{get:function(){stages+='e';return builtin;}});'aa'.replace(rx,function(){stages+='c';return 'b';})==='bb' && stages==='eeecc';", 0)
	string_replace_eval(rt, c"let ex=0;let callbacks=0;try{'aa'.replace(/a/g,function(){callbacks++;throw 81;});}catch(e){ex=e;}ex===81 && callbacks===1;", 0)
	string_replace_eval(rt, c"let conversionError=0;try{'a'.replace('a',function(){return {toString:function(){throw 82;}};});}catch(e){conversionError=e;}conversionError===82;", 0)
	string_replace_eval(rt, c"let nul=String.fromCharCode(0);(nul+'a').replace(nul,function(m,i){return m.length===1 && i===0 ? 'X' : 'bad';})==='Xa';", 0)
	string_replace_eval(rt, c"'a'.replace('a',function(){return '$&';})==='$&' && 'a'.replace(/a/,function(){return '$&';})==='$&';", 0)
	string_replace_eval(rt, c"'ab'.replace(/(a)(b)/,'$2$1')==='ba' && 'ab'.replace('a','$&$&')==='aab';", 0)
	string_replace_eval(rt, c"let globalRead='';let flags=/a/g;Object.defineProperty(flags,'flags',{get:function(){globalRead+='f';return 'g';}});'aa'.replace(flags,function(){globalRead+='c';return 'b';})==='bb' && globalRead==='fcc';", 0)
	string_replace_eval(rt, c"let noMatchCalls=0;let noMatch={toString:function(){noMatchCalls++;return 'b';}};'x'.replace(/a/g,noMatch)==='x' && noMatchCalls===1;", 0)
	string_replace_eval(rt, c"let invalid=0;try{String.prototype.replace.call(null,'x',function(){return 'y';});}catch(e){invalid=e.constructor===TypeError;}invalid;", 0)
	string_replace_eval(rt, c"let custom=/a/;custom.exec=function(){return null;};'a'.replace(custom,function(){return 'b';});", 6)
	string_replace_eval(rt, c"let bounded=/a/g;Object.defineProperty(bounded,'lastIndex',{writable:false});'a'.replace(bounded,function(){return 'b';});", 2)
	string_replace_eval(rt, c"let retainedResult='ab'.replace(/(a)|(b)/g,function(m,a,b,i){return {toString:function(){return m+i;}};});true;", 0)
	js_runtime_collect(rt)
	string_replace_eval(rt, c"retainedResult==='a0b1';", 0)
	string_replace_eval(rt, c"'a'.replace(/a/,function(){return this===self ? 'X' : 'bad';})==='X';", 0)
	rt.max_properties = 64
	string_replace_eval(rt, c"'aaaaaaaa'.replace(/a/g,function(){return '1234567890';});", 5)
	string_replace_eval(rt, c"var limitCallbacks=0;'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'.replace(/(?:)/g,function(){limitCallbacks++;return '';});", 5)
	rt.max_properties = 10000
	string_replace_eval(rt, c"limitCallbacks===0;", 0)
	js_runtime_free(rt)
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_string_replace_test: OK")
	return 0
