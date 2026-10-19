# wbuild: name=javascript_runtime_error_brand_test
# wbuild: target=javascript_runtime_error_brand_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 --strict tests/javascript/runtime_error_brand_test.w -o bin/javascript_runtime_error_brand_test"
# wbuild: step="bin/javascript_runtime_error_brand_test" expect_stdout="javascript_runtime_error_brand_test: OK"
# wbuild: step="bin/javascript_runtime_error_brand_test memory" expect_stdout="javascript_runtime_error_brand_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

void error_brand_eval(js_runtime* rt, char* source):
	js_runtime_collect(rt)
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 100000)
	if (result.status != 0 || result.value.number != 1.0):
		println(source)
		println(result.message)
	assert_equal(0, result.status)
	assert1(result.value.number == 1.0)

js_value* error_brand_hook(void* runtime, void* context, js_value* receiver, js_text* key):
	int* calls = cast(int*, context)
	*calls = *calls + 1
	return 0

int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	js_runtime* rt = js_runtime_new()
	error_brand_eval(rt, c"let constructors=[Error,EvalError,RangeError,ReferenceError,SyntaxError,TypeError,URIError];let valid=true;for(let i=0;i<constructors.length;i++){let C=constructors[i];if(!Error.isError(C())||!Error.isError(new C())||Error.isError(C)||Error.isError(C.prototype)||Error.isError(Object.create(C.prototype)))valid=false;}valid;")
	error_brand_eval(rt, c"let other=[undefined,null,true,false,0,-0,NaN,Infinity,-Infinity,42,'','x',0n,42n,{},[],function(){},/a/g,Object(1),Object('x')];valid=!Error.isError();for(let i=0;i<other.length;i++){if(Error.isError(other[i]))valid=false;}valid;")
	error_brand_eval(rt, c"class Custom extends TypeError{}let actual=new Custom('x');let inherited=Object.create(actual);actual.name='Pretend';actual.constructor=Object;Object.setPrototypeOf(actual,null);Error.isError(actual) && !Error.isError(inherited);")
	error_brand_eval(rt, c"let fake=Object.create(Error.prototype);fake.name='Error';fake.constructor=Error;fake.message='x';fake.stack='Error';!Error.isError(fake);")
	error_brand_eval(rt, c"function Alternate(){}let reflected=Reflect.construct(Error,[],Alternate);Error.isError(reflected) && Object.getPrototypeOf(reflected)===Alternate.prototype;")
	error_brand_eval(rt, c"let effects=0;let guarded={};let keys=['name','constructor','message','stack','toString','valueOf'];for(let i=0;i<keys.length;i++){Object.defineProperty(guarded,keys[i],{get:function(){effects++;throw 71;}});}!Error.isError(guarded) && effects===0;")
	error_brand_eval(rt, c"let caught=0;try{null.x;}catch(e){caught=Error.isError(e);}caught===true;")
	error_brand_eval(rt, c"let descriptor=Object.getOwnPropertyDescriptor(Error,'isError');Error.isError.name==='isError' && Error.isError.length===1 && !Object.hasOwn(Error.isError,'prototype') && descriptor.writable && !descriptor.enumerable && descriptor.configurable;")
	error_brand_eval(rt, c"caught=0;try{new Error.isError();}catch(e){caught=e.constructor===TypeError;}caught===true && Error.isError.call(null,actual);")
	js_value* method = js_runtime_get(rt, js_runtime_get(rt, rt.global, c"Error"), c"isError")
	assert1(js_runtime_root(rt, method))
	js_value* host_object = js_runtime_alloc(rt, 5)
	int calls = 0
	assert1(js_runtime_set_host_hooks(rt, host_object, &calls, error_brand_hook, 0))
	list[js_value*] arguments = new list[js_value*]
	arguments.push(host_object)
	assert1(js_runtime_call_receiver(rt, method, rt.undefined_value, arguments).number == 0.0)
	assert_equal(0, calls)
	js_runtime* foreign = js_runtime_new()
	arguments[0] = foreign.undefined_value
	js_runtime_call_receiver(rt, method, rt.undefined_value, arguments)
	assert_equal(2, rt.completion.status)
	js_runtime_begin(rt, 1000)
	arguments.clear()
	js_runtime_call_receiver(rt, method, foreign.undefined_value, arguments)
	assert_equal(2, rt.completion.status)
	__w_list_free(cast(__w_list*, arguments))
	js_runtime_free(foreign)
	error_brand_eval(rt, c"let saved=Error.isError;Error=undefined;saved(actual) && !saved(fake);")
	js_runtime_free(rt)
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_error_brand_test: OK")
	return 0
