# wbuild: name=javascript_runtime_string_coercion_test
# wbuild: target=javascript_runtime_string_coercion_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 --strict tests/javascript/runtime_string_coercion_test.w -o bin/javascript_runtime_string_coercion_test"
# wbuild: step="bin/javascript_runtime_string_coercion_test" expect_stdout="javascript_runtime_string_coercion_test: OK"
# wbuild: step="bin/javascript_runtime_string_coercion_test memory" expect_stdout="javascript_runtime_string_coercion_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

void string_coercion_eval(js_runtime* rt, char* source, int status):
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 10000)
	if (result.status != status):
		println(source)
		println(result.message)
	assert_equal(status, result.status)
	if (status == 0):
		if (result.value.kind != 2 || result.value.number != 1.0): println(source)
		assert_equal(2, result.value.kind)
		assert1(result.value.number == 1.0)

void string_coercion_source(char* source):
	js_runtime* rt = js_runtime_new()
	string_coercion_eval(rt, source, 0)
	js_runtime_free(rt)

void string_coercion_semantics():
	string_coercion_source(c"String(new Error('broken'))==='Error: broken' && String(new Error())==='Error' && String(new ReferenceError('missing'))==='ReferenceError: missing';")
	string_coercion_source(c"class WasiExit extends Error {constructor(code){super(`proc_exit(${code})`);this.code=code;}} String(new WasiExit(7))==='Error: proc_exit(7)';")
	string_coercion_source(c"let e=new Error('x');e.name='';String(e)==='x';")
	string_coercion_source(c"let e=new Error('');e.name='';String(e)==='';")
	string_coercion_source(c"let e=new Error();e.name=null;e.message=42;String(e)==='null: 42';")
	string_coercion_source(c"let e=new Error();e.name=undefined;e.message=undefined;String(e)==='Error';")
	string_coercion_source(c"let o={tag:'ok',toString:function(){return this.tag;},valueOf:function(){throw 9;}};String(o)==='ok';")
	string_coercion_source(c"let log='';let o={toString:function(){log+='t';return {};},valueOf:function(){log+='v';return 7;}};String(o)==='7' && log==='tv';")
	string_coercion_source(c"let o={toString:undefined,valueOf:function(){return 42;}};String(o)==='42';")
	string_coercion_source(c"let o={toString:3,valueOf:function(){return false;}};String(o)==='false';")
	string_coercion_source(c"let o={toString:function(){return null;}};String(o)==='null';")
	string_coercion_source(c"let o={toString:function(){return undefined;}};String(o)==='undefined';")
	string_coercion_source(c"let o={toString:function(){return 9007199254740993n;}};String(o)==='9007199254740993';")
	string_coercion_source(c"let o={toString:function(){return '\\0\\ud800';}};String(o)==='\\0\\ud800';")
	string_coercion_source(c"let count=0;let o={toString:function(){throw 42;},valueOf:function(){count++;return 9;}};let caught=0;try{String(o);}catch(e){caught=e;} caught===42 && count===0;")
	string_coercion_source(c"let o={toString:function(){return {};},valueOf:function(){return {};}};let caught=false;try{String(o);}catch(e){caught=e.name==='TypeError';}caught;")
	string_coercion_source(c"let o={toString:0,valueOf:0};let caught=false;try{String(o);}catch(e){caught=e.name==='TypeError';}caught;")
	string_coercion_source(c"class Base{toString(){return this.x;}}class Child extends Base{constructor(){super();this.x='inherited';}}String(new Child())==='inherited';")
	string_coercion_source(c"let log='';let e=new Error();e.name={toString:function(){log+='n';return 'N';}};e.message={toString:function(){log+='m';return 'M';}};String(e)==='N: M' && log==='nm';")
	string_coercion_source(c"let e=new Error({toString:function(){return 'custom';}});e.message==='custom' && String(e)==='Error: custom';")
	string_coercion_source(c"let o={name:'N',message:'M',toString:Error.prototype.toString};String(o)==='N: M';")
	string_coercion_source(c"String()==='' && String(undefined)==='undefined' && String(null)==='null' && String(-0)==='0' && String(true)==='true';")

struct string_coercion_getter_context:
	js_value* receiver
	js_value* result
	list[int] log
	int event
	int throws

js_value* string_coercion_getter(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	string_coercion_getter_context* state = cast(string_coercion_getter_context*, context)
	assert1(receiver == state.receiver)
	assert_equal(0, args.length)
	state.log.push(state.event)
	if (state.throws):
		js_runtime_fail(rt, 2, c"getter exception")
		rt.completion.value = state.result
	return state.result

void string_coercion_getters():
	js_runtime* rt = js_runtime_new()
	list[int] log = new list[int]
	js_value* value = js_runtime_alloc(rt, 5)
	js_runtime_set(rt, rt.global, c"object", value)
	string_coercion_getter_context first
	first.receiver = value
	first.result = js_class_string(rt, c"N")
	first.log = log
	first.event = 1
	first.throws = 0
	string_coercion_getter_context second
	second.receiver = value
	second.result = js_class_string(rt, c"M")
	second.log = log
	second.event = 2
	second.throws = 0
	js_text* key = js_runtime_key(c"name")
	js_runtime_define_accessor(rt, value, key, js_runtime_host_callable(rt, &first, string_coercion_getter), 0, 0, 1)
	js_text_free(key)
	key = js_runtime_key(c"message")
	js_runtime_define_accessor(rt, value, key, js_runtime_host_callable(rt, &second, string_coercion_getter), 0, 0, 1)
	js_text_free(key)
	js_runtime_set(rt, value, c"toString", js_runtime_get(rt, rt.error_prototype, c"toString"))
	string_coercion_eval(rt, c"String(object)==='N: M';", 0)
	assert_equal(2, log.length)
	assert_equal(1, log[0])
	assert_equal(2, log[1])
	first.throws = 1
	string_coercion_eval(rt, c"let caught='';try{String(object);}catch(e){caught=e;} caught==='N';", 0)
	assert_equal(3, log.length)
	assert_equal(1, log[2])
	# A generic toString accessor is called with the original receiver.
	first.throws = 0
	first.result = js_runtime_get(rt, rt.error_prototype, c"toString")
	key = js_runtime_key(c"toString")
	js_runtime_define_accessor(rt, value, key, js_runtime_host_callable(rt, &first, string_coercion_getter), 0, 0, 1)
	js_text_free(key)
	# Restore a plain name: the shared first context now returns a callable.
	key = js_runtime_key(c"name")
	js_runtime_define_data(rt, value, key, js_class_string(rt, c"N"), 1, 0, 1)
	js_text_free(key)
	string_coercion_eval(rt, c"String(object)==='N: M';", 0)
	assert_equal(5, log.length)
	assert_equal(1, log[3])
	assert_equal(2, log[4])
	js_runtime_free(rt)
	__w_list_free(cast(__w_list*, log))

void string_coercion_limits():
	js_runtime* rt = js_runtime_new()
	rt.max_depth = 24
	string_coercion_eval(rt, c"let o={toString:function(){return String(o);}};String(o);", 5)
	string_coercion_eval(rt, c"let e=new Error();e.name=e;String(e);", 5)
	string_coercion_eval(rt, c"String({})==='[object Object]';", 0)
	string_coercion_eval(rt, c"String(/a/);", 6)
	string_coercion_eval(rt, c"String(new Uint8Array(1));", 6)
	# Deliberately primitive-only helper still rejects objects for other APIs.
	js_runtime_begin(rt, 100)
	js_value* value = js_runtime_alloc(rt, 5)
	assert1(js_runtime_primitive_text(rt, value) == 0)
	assert_equal(6, rt.completion.status)
	js_runtime_free(rt)

int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	if (argc == 1):
		string_coercion_semantics()
		string_coercion_limits()
	string_coercion_getters()
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_string_coercion_test: OK")
	return 0
