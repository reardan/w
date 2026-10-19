# wbuild: name=javascript_runtime_addition_test
# wbuild: target=javascript_runtime_addition_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 --strict tests/javascript/runtime_addition_test.w -o bin/javascript_runtime_addition_test"
# wbuild: step="bin/javascript_runtime_addition_test" expect_stdout="javascript_runtime_addition_test: OK"
# wbuild: step="bin/javascript_runtime_addition_test memory-primitives" expect_stdout="javascript_runtime_addition_test: OK"
# wbuild: step="bin/javascript_runtime_addition_test memory-objects" expect_stdout="javascript_runtime_addition_test: OK"
# wbuild: step="bin/javascript_runtime_addition_test memory-getters" expect_stdout="javascript_runtime_addition_test: OK"
# wbuild: step="bin/javascript_runtime_addition_test memory-limits" expect_stdout="javascript_runtime_addition_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

void addition_eval(js_runtime* rt, char* source, int status):
	js_runtime_collect(rt)
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 20000)
	if (result.status != status || (status == 0 && result.value.number != 1.0)):
		println(source)
		println(result.message)
	assert_equal(status, result.status)
	if (status == 0): assert1(result.value.number == 1.0)

void test_add_primitives():
	js_runtime* rt = js_runtime_new()
	addition_eval(rt, c"'HTTP '+503==='HTTP 503' && new Error('HTTP '+503).message==='HTTP 503';", 0)
	addition_eval(rt, c"'x'+true==='xtrue' && null+'x'==='nullx' && undefined+'x'==='undefinedx' && ''+-0==='0';", 0)
	addition_eval(rt, c"true+true===2 && null+false===0 && null+3===3 && false+2===2;", 0)
	addition_eval(rt, c"let n=undefined+1;n!==n && 1/(-0+-0)===-1/0 && 1/(null+-0)===1/0;", 0)
	addition_eval(rt, c"'n='+NaN==='n=NaN' && 'i='+Infinity==='i=Infinity' && 'e='+1e21==='e=1e+21';", 0)
	addition_eval(rt, c"1n+2n===3n && 'x'+9007199254740993n==='x9007199254740993' && 1n+'2'==='12';", 0)
	addition_eval(rt, c"9007199254740992+1===9007199254740992 && 'x'+18446744073709551615n==='x18446744073709551615';", 0)
	addition_eval(rt, c"'\\uD800'+0+'\\u0000'==='\\uD8000\\u0000';", 0)
	addition_eval(rt, c"let value='HTTP ';value+=503;value==='HTTP 503';", 0)
	addition_eval(rt, c"1n+true;", 2)
	addition_eval(rt, c"1+1n;", 2)
	addition_eval(rt, c"let update='1';update++;", 6)
	addition_eval(rt, c"let count=1;count++;let big=1n;big++;count===2 && big===2n;", 0)
	js_runtime_free(rt)

void test_add_objects():
	js_runtime* rt = js_runtime_new()
	addition_eval(rt, c"let order='';let left={valueOf:function(){order+='a';return 2;}};true;", 0)
	addition_eval(rt, c"let right={valueOf:function(){order+='b';return '3';}};true;", 0)
	addition_eval(rt, c"function L(){order+='l';return left;}function R(){order+='r';return right;}L()+R()==='23' && order==='lrab';", 0)
	addition_eval(rt, c"let fallback={valueOf:function(){return this;},toString:function(){return 's';}};fallback+4==='s4';", 0)
	addition_eval(rt, c"let custom={valueOf:3,toString:function(){return 9;}};custom+true===10;", 0)
	addition_eval(rt, c"let big={valueOf:function(){return 9007199254740993n;}};big+1n===9007199254740994n && 'x'+big==='x9007199254740993';", 0)
	addition_eval(rt, c"let stopped=0;let bad={valueOf:function(){throw 7;}};let later={valueOf:function(){stopped++;return 1;}};true;", 0)
	addition_eval(rt, c"let caught=0;try{bad+later;}catch(e){caught=e;}caught===7 && stopped===0;", 0)
	addition_eval(rt, c"({valueOf:function(){return {};},toString:function(){return {};}})+1;", 2)
	addition_eval(rt, c"({})+'x'==='[object Object]x';", 0)
	addition_eval(rt, c"new Error('detail')+''==='Error: detail';", 0)
	js_runtime_free(rt)

struct addition_getter:
	list[int] log
	js_value* object
	js_value* method
	int event
	int throws

js_value* addition_get(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	addition_getter* state = cast(addition_getter*, context)
	assert1(receiver == state.object)
	assert_equal(0, args.length)
	state.log.push(state.event)
	if (state.throws): js_runtime_fail(rt, 2, c"addition conversion getter throw")
	return state.method

js_value* addition_value(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	addition_getter* state = cast(addition_getter*, context)
	assert1(receiver == state.object)
	assert_equal(0, args.length)
	state.log.push(state.event + 1)
	return js_runtime_number(rt, cast(float64, state.event))

void test_add_getters():
	js_runtime* rt = js_runtime_new()
	addition_getter left
	left.log = new list[int]
	left.object = js_runtime_alloc(rt, 5)
	left.method = js_runtime_host_callable(rt, &left, addition_value)
	left.event = 1
	left.throws = 0
	addition_getter right
	right.log = left.log
	right.object = js_runtime_alloc(rt, 5)
	right.method = js_runtime_host_callable(rt, &right, addition_value)
	right.event = 3
	right.throws = 0
	js_runtime_set(rt, rt.global, c"left", left.object)
	js_runtime_set(rt, rt.global, c"right", right.object)
	js_text* key = js_runtime_key(c"valueOf")
	js_runtime_define_accessor(rt, left.object, key, js_runtime_host_callable(rt, &left, addition_get), 0, 1, 1)
	js_runtime_define_accessor(rt, right.object, key, js_runtime_host_callable(rt, &right, addition_get), 0, 1, 1)
	js_text_free(key)
	# Methods live in native contexts, so the embedding must root them itself.
	js_runtime_root(rt, left.method)
	js_runtime_root(rt, right.method)
	addition_eval(rt, c"left+right===4;", 0)
	assert_equal(4, left.log.length)
	for i in range(4): assert_equal(i + 1, left.log[i])
	left.log.clear()
	left.throws = 1
	addition_eval(rt, c"left+right;", 2)
	assert_equal(1, left.log.length)
	js_runtime_free(rt)
	__w_list_free(cast(__w_list*, left.log))

void test_add_limits():
	js_runtime* rt = js_runtime_new()
	rt.max_properties = 4
	addition_eval(rt, c"'four'+0;", 5)
	rt.max_properties = 10000
	char* source = c"'abcdefgh'+'ijklmnop';"
	assert_equal(5, js_runtime_eval(rt, source, strlen(source), 8).status)
	addition_eval(rt, c"18446744073709551615n+1n;", 2)
	addition_eval(rt, c"let recursive={valueOf:function(){return recursive+1;}};true;", 0)
	rt.max_depth = 20
	addition_eval(rt, c"recursive+1;", 5)
	js_runtime_free(rt)

int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	if (argc == 1 || strcmp(args_get(1), c"memory-primitives") == 0): test_add_primitives()
	if (argc == 1 || strcmp(args_get(1), c"memory-objects") == 0): test_add_objects()
	if (argc == 1 || strcmp(args_get(1), c"memory-getters") == 0): test_add_getters()
	if (argc == 1 || strcmp(args_get(1), c"memory-limits") == 0): test_add_limits()
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_addition_test: OK")
	return 0
