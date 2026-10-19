# wbuild: name=javascript_runtime_equality_test
# wbuild: target=javascript_runtime_equality_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 --strict tests/javascript/runtime_equality_test.w -o bin/javascript_runtime_equality_test"
# wbuild: step="bin/javascript_runtime_equality_test" expect_stdout="javascript_runtime_equality_test: OK"
# wbuild: step="bin/javascript_runtime_equality_test memory-primitive" expect_stdout="javascript_runtime_equality_test: OK"
# wbuild: step="bin/javascript_runtime_equality_test memory-bigint" expect_stdout="javascript_runtime_equality_test: OK"
# wbuild: step="bin/javascript_runtime_equality_test memory-object" expect_stdout="javascript_runtime_equality_test: OK"
# wbuild: step="bin/javascript_runtime_equality_test memory-getters" expect_stdout="javascript_runtime_equality_test: OK"
# wbuild: step="bin/javascript_runtime_equality_test memory-limits" expect_stdout="javascript_runtime_equality_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

void equality_eval(js_runtime* rt, char* source, int status):
	js_runtime_collect(rt)
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 10000)
	if (result.status != status || (status == 0 && result.value.number != 1.0)):
		println(source)
		println(result.message)
	assert_equal(status, result.status)
	if (status == 0):
		assert_equal(2, result.value.kind)
		assert1(result.value.number == 1.0)

void test_equality_primitive():
	js_runtime* rt = js_runtime_new()
	equality_eval(rt, c"'key'=='key' && 'key'!='ref' && null==undefined && !(null==0) && !(undefined==false) && !(null=='');", 0)
	equality_eval(rt, c"'1'==1 && 1=='1' && false=='' && true=='1' && true!=2 && false==0n && true==1n;", 0)
	equality_eval(rt, c"'\\u00a0\\ufeff\\u20280\\u3000'==0 && ''==0 && '   '==0 && '-0'==0 && '+.5e1'==5 && '5.'==5;", 0)
	equality_eval(rt, c"'1e'!=1 && '1x'!=1 && '1_0'!=10 && '1\\0'!=1 && '\\ud800'!=0 && '+0x1'!=1 && '0b2'!=0 && '0x'!=0;", 0)
	equality_eval(rt, c"'Infinity'==(1/0) && '-Infinity'==(-1/0) && '+Infinity'==(1/0) && 'infinity'!=(1/0) && 'Infinityjunk'!=(1/0) && 'NaN'!=(0/0) && ''!=(0/0);", 0)
	equality_eval(rt, c"'0xff'==255 && '0o10'==8 && '0B101'==5 && '0x20000000000001'==9007199254740992 && '0x20000000000003'==9007199254740996;", 0)
	equality_eval(rt, c"'0x2000000000000101'==2305843009213694464 && '1.00000000000000011102230246251565404236316680908203125'==1 && '5e-324'==5e-324;", 0)
	equality_eval(rt, c"let a={};let b=[];a==a && b==b && a!=b && a!=null && a!=undefined && '1'!==1;", 0)
	js_runtime_free(rt)

void test_equality_bigint():
	js_runtime* rt = js_runtime_new()
	equality_eval(rt, c"9007199254740993n!=9007199254740992 && 9007199254740992n==9007199254740992 && 1n!=1.5 && 0n!=-0.5 && 0n==-0;", 0)
	equality_eval(rt, c"18446744073709551615n!=18446744073709551616 && 18446744073709549568n==18446744073709549568 && -9223372036854775808n==-9223372036854775808;", 0)
	equality_eval(rt, c"1n!=(1/0) && 0n!=(0/0) && 9007199254740993n=='9007199254740993' && '9007199254740993'==9007199254740993n;", 0)
	equality_eval(rt, c"0n=='' && 0n==' \\t' && 0n=='-0' && 1n=='+0001' && 16n=='0x10' && 8n=='0o10' && 2n=='0b10';", 0)
	equality_eval(rt, c"1n!='1n' && 1n!='1.0' && 100n!='1e2' && 1n!='+0x1' && 1n!='1\\0' && 0n!='+';", 0)
	equality_eval(rt, c"0n!='18446744073709551616' && -1n!='18446744073709551615' && 18446744073709551615n=='18446744073709551615' && -9223372036854775808n=='-9223372036854775808';", 0)
	equality_eval(rt, c"0n!='99999999999999999999999999999999999999999999999999999999999999999999999999999' && 0n!='-18446744073709551616';", 0)
	js_runtime_free(rt)

void test_equality_object():
	js_runtime* rt = js_runtime_new()
	equality_eval(rt, c"let log='';let o={tag:7,valueOf:function(){log+='v';return this.tag;},toString:function(){throw 99;}};o=='7' && log==='v';", 0)
	equality_eval(rt, c"o={valueOf:function(){log+='v';return {};},toString:function(){log+='t';return '8';}};log='';8==o && log==='vt';", 0)
	equality_eval(rt, c"o={valueOf:4,toString:function(){return 9n;}};o==9 && 9n==o && o!=8;", 0)
	equality_eval(rt, c"o={valueOf:function(){return undefined;}};o!=null && o!=undefined && o!=0;", 0)
	equality_eval(rt, c"o={valueOf:function(){throw 42;}};let caught=0;try{o!=1;}catch(e){caught=e;}caught===42;", 0)
	equality_eval(rt, c"o={valueOf:function(){return {};},toString:function(){return {};}};let type=false;try{o==1;}catch(e){type=e.name==='TypeError';}type;", 0)
	equality_eval(rt, c"class Base{valueOf(){return this.x;}}class Child extends Base{constructor(){super();this.x=12;}}new Child()=='12';", 0)
	equality_eval(rt, c"log='';function left(){log+='l';return {valueOf:function(){log+='v';return 3;}};}function right(){log+='r';return 3;}left()==right() && log==='lrv';", 0)
	equality_eval(rt, c"let arrow=()=>1;arrow.valueOf=()=>5;arrow==5 && arrow==arrow && arrow!={};", 0)
	js_runtime_free(rt)

struct equality_getter_state:
	js_value* receiver
	js_value* result
	int calls
	int throws

js_value* equality_getter(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	equality_getter_state* state = cast(equality_getter_state*, context)
	assert1(receiver == state.receiver)
	assert_equal(0, args.length)
	state.calls = state.calls + 1
	if (state.throws):
		js_runtime_fail(rt, 2, c"equality getter throws")
		rt.completion.value = js_runtime_number(rt, 73.0)
	return state.result

void test_equality_getters():
	js_runtime* rt = js_runtime_new()
	equality_eval(rt, c"let object={toString:function(){throw 99;}};let method=function(){return this===object?7:8;};true;", 0)
	equality_getter_state state
	state.receiver = js_runtime_get(rt, rt.global, c"object")
	state.result = js_runtime_get(rt, rt.global, c"method")
	state.calls = 0
	state.throws = 0
	js_text* key = js_runtime_key(c"valueOf")
	assert1(js_runtime_define_accessor(rt, state.receiver, key, js_runtime_host_callable(rt, &state, equality_getter), 0, 1, 1))
	js_text_free(key)
	equality_eval(rt, c"object==7;", 0)
	assert_equal(1, state.calls)
	state.throws = 1
	equality_eval(rt, c"let caught=0;try{object==7;}catch(e){caught=e;}caught===73;", 0)
	assert_equal(2, state.calls)
	equality_eval(rt, c"object!=null && object!=undefined && object==object && object!={};", 0)
	assert_equal(2, state.calls)
	# First method can replace the second, which must be read only afterwards.
	equality_eval(rt, c"let changed={valueOf:function(){this.toString=()=>11;return {};},toString:function(){throw 66;}};changed==11;", 0)
	js_runtime_free(rt)

void test_equality_limits():
	js_runtime* rt = js_runtime_new()
	equality_eval(rt, c"!(({})==1);", 0)
	equality_eval(rt, c"[]=='';", 0)
	equality_eval(rt, c"new Uint8Array(1)==0;", 6)
	equality_eval(rt, c"let explicit={valueOf:0,toString:undefined};let caught=false;try{explicit==0;}catch(e){caught=e.name==='TypeError';}caught;", 0)
	rt.max_depth = 20
	equality_eval(rt, c"let recursive={valueOf:function(){return recursive==0;}};recursive==0;", 5)
	rt.max_depth = 256
	char* source = c"'12345678901234567890'==0;"
	assert_equal(5, js_runtime_eval(rt, source, strlen(source), 10).status)
	rt.max_properties = 8
	assert_equal(5, js_runtime_eval(rt, source, strlen(source), 100).status)
	js_runtime_free(rt)

int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	if (argc == 1 || strcmp(args_get(1), c"memory-primitive") == 0): test_equality_primitive()
	if (argc == 1 || strcmp(args_get(1), c"memory-bigint") == 0): test_equality_bigint()
	if (argc == 1 || strcmp(args_get(1), c"memory-object") == 0): test_equality_object()
	if (argc == 1 || strcmp(args_get(1), c"memory-getters") == 0): test_equality_getters()
	if (argc == 1 || strcmp(args_get(1), c"memory-limits") == 0): test_equality_limits()
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_equality_test: OK")
	return 0
