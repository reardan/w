# wbuild: name=javascript_runtime_json_test
# wbuild: target=javascript_runtime_json_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 tests/javascript/runtime_json_test.w -o bin/javascript_runtime_json_test"
# wbuild: step="bin/javascript_runtime_json_test" expect_stdout="javascript_runtime_json_test: OK"
# wbuild: step="bin/javascript_runtime_json_test memory" expect_stdout="javascript_runtime_json_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime_json

void json_eval(js_runtime* rt, char* source, int status):
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 100000)
	if (result.status != status): println(result.message)
	assert_equal(status, result.status)
	if (status == 0): assert1(result.value.number == 1.0)

int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	js_runtime* rt = js_runtime_new()
	js_runtime_install_json(rt)
	json_eval(rt, c"JSON.parse.name==='parse' && JSON.parse.length===2 && JSON.stringify.name==='stringify' && JSON.stringify.length===3;", 0)
	json_eval(rt, c"let pd=Object.getOwnPropertyDescriptor(JSON,'parse');let sd=Object.getOwnPropertyDescriptor(JSON,'stringify');pd.writable && pd.configurable && !pd.enumerable && sd.writable && sd.configurable && !sd.enumerable && Object.keys(JSON).length===0;", 0)
	json_eval(rt, c"let len=Object.getOwnPropertyDescriptor(JSON.parse,'length');let name=Object.getOwnPropertyDescriptor(JSON.stringify,'name');!len.writable && !len.enumerable && len.configurable && !name.writable && !name.enumerable && name.configurable && !Object.hasOwn(JSON.parse,'prototype');", 0)
	json_eval(rt, c"let x=JSON.parse('{\"n\":1,\"b\":true,\"none\":null,\"a\":[false,2.5]}'); x.n===1 && x.b===true && x.none===null && x.a[0]===false && x.a[1]===2.5;", 0)
	json_eval(rt, c"JSON.parse(' \\t\\r\\n-0 ' )===0 && 1/JSON.parse('-0')===-Infinity && JSON.parse('1e400')===Infinity && JSON.parse(true)===true && JSON.parse(null)===null;", 0)
	json_eval(rt, c"let dup=JSON.parse('{\"x\":1,\"x\":2,\"__proto__\":{\"safe\":3}}'); dup.x===2 && dup.__proto__.safe===3 && typeof dup.safe==='undefined';", 0)
	json_eval(rt, c"let utf=JSON.parse('\"\\\\u0000\\\\ud800\\\\ud83d\\\\ude00\"'); utf.length===4 && utf[0]==='\\u0000' && utf[1]==='\\ud800' && utf[2]==='\\ud83d' && utf[3]==='\\ude00';", 0)
	json_eval(rt, c"let nul=JSON.parse('{\"\\\\u0000\":7}'); nul['\\u0000']===7 && JSON.parse('1',null)===1;", 0)
	char*[15] invalid
	invalid[0] = c""
	invalid[1] = c"01"
	invalid[2] = c"+1"
	invalid[3] = c"1."
	invalid[4] = c"1e"
	invalid[5] = c"NaN"
	invalid[6] = c"[1,]"
	invalid[7] = c"{\"a\":1,}"
	invalid[8] = c"{'a':1}"
	invalid[9] = c"true false"
	invalid[10] = c"/*x*/1"
	invalid[11] = c"\"\\x20\""
	invalid[12] = c"\"\\u123\""
	invalid[13] = c"\"raw\nline\""
	invalid[14] = c"["
	for i in range(15):
		js_runtime_begin(rt, 100000)
		js_text* text = js_runtime_key(invalid[i])
		js_runtime_json_parse(rt, text)
		js_text_free(text)
		assert_equal(2, rt.completion.status)
		assert_strings_equal(c"SyntaxError", rt.completion.value.intrinsic_error_name)
		assert1(rt.completion.value.prototype == rt.syntax_error_prototype)
	json_eval(rt, c"JSON.stringify({a:1,b:true,c:null,s:'x'})==='{\"a\":1,\"b\":true,\"c\":null,\"s\":\"x\"}' && JSON.stringify([undefined,NaN,Infinity,-Infinity])==='[null,null,null,null]' && JSON.stringify({a:undefined,b:function(){},c:1})==='{\"c\":1}' && JSON.stringify(undefined)===undefined;", 0)
	json_eval(rt, c"JSON.stringify(utf)==='\"\\\\u0000\\\\ud800😀\"' && JSON.stringify('\\b\\t\\n\\f\\r\\\"\\\\')==='\"\\\\b\\\\t\\\\n\\\\f\\\\r\\\\\"\\\\\\\\\"';", 0)
	json_eval(rt, c"let keys={z:0,'10':10,'2':2,a:1,'01':1}; JSON.stringify(keys)==='{\"2\":2,\"10\":10,\"z\":0,\"a\":1,\"01\":1}';", 0)
	json_eval(rt, c"let converted={toJSON:function(key){return key==='v'?3:4;}}; JSON.stringify({v:converted})==='{\"v\":3}' && JSON.stringify(converted)==='4';", 0)
	json_eval(rt, c"let cyclic={}; cyclic.self=cyclic; let cycle=false; try {JSON.stringify(cyclic);} catch(e) {cycle=e.name==='TypeError';} cycle;", 0)
	json_eval(rt, c"let big=false; try {JSON.stringify(1n);} catch(e) {big=e.name==='TypeError';} big;", 0)
	json_eval(rt, c"JSON.parse('1',function(k,v){return v;});", 6)
	json_eval(rt, c"JSON.stringify({},null,2);", 6)
	js_runtime_collect(rt)
	json_eval(rt, c"JSON.stringify(x)==='{\"n\":1,\"b\":true,\"none\":null,\"a\":[false,2.5]}' && JSON.parse(JSON.stringify(utf))===utf;", 0)
	js_runtime_begin(rt, 100000)
	js_text* deep = js_text_new()
	for i in range(130): deep.units.push('[')
	deep.units.push('0')
	for i in range(130): deep.units.push(']')
	js_runtime_json_parse(rt, deep)
	assert_equal(5, rt.completion.status)
	js_text_free(deep)
	js_runtime_begin(rt, 1)
	js_text* more = js_runtime_key(c"[0]")
	js_runtime_json_parse(rt, more)
	assert_equal(5, rt.completion.status)
	js_text_free(more)
	js_value* undefined_prototype = rt.undefined_value.prototype
	char* undefined_name = rt.undefined_value.intrinsic_error_name
	js_runtime_begin(rt, 100000)
	rt.max_properties = 13
	js_json_error(rt, c"SyntaxError", c"x")
	assert_equal(5, rt.completion.status)
	assert1(rt.undefined_value.prototype == undefined_prototype)
	assert1(rt.undefined_value.intrinsic_error_name == undefined_name)
	js_runtime_begin(rt, 100000)
	rt.max_properties = 16
	js_json_error(rt, c"SyntaxError", c"this error message exceeds the property budget")
	assert_equal(5, rt.completion.status)
	assert1(rt.undefined_value.prototype == undefined_prototype)
	assert1(rt.undefined_value.intrinsic_error_name == undefined_name)
	js_runtime_free(rt)
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_json_test: OK")
	return 0
