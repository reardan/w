# wbuild: name=javascript_runtime_mapped_arguments_test
# wbuild: target=javascript_runtime_mapped_arguments_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 --strict tests/javascript/runtime_mapped_arguments_test.w -o bin/javascript_runtime_mapped_arguments_test"
# wbuild: step="bin/javascript_runtime_mapped_arguments_test" expect_stdout="javascript_runtime_mapped_arguments_test: OK"
# wbuild: step="bin/javascript_runtime_mapped_arguments_test memory" expect_stdout="javascript_runtime_mapped_arguments_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

void mapped_eval(js_runtime* rt, char* source):
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 100000)
	if (result.status != 0 || result.value.number != 1.0):
		println(source)
		println(result.message)
	assert_equal(0, result.status)
	assert1(result.value.number == 1.0)

int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	js_runtime* rt = js_runtime_new()
	mapped_eval(rt, c"function f(a){a=2;let x=arguments;a=3;return x[0]===3 && Object.getOwnPropertyDescriptor(x,'0').value===3;}f(1);")
	mapped_eval(rt, c"function f(a){let x=arguments;x[0]=4;return a===4 && x===arguments && !Array.isArray(x);}f(1);")
	mapped_eval(rt, c"function f(a,a){let x=arguments;a=8;return x[0]===1 && x[1]===8;}f(1,2);")
	mapped_eval(rt, c"function f(a,a){let x=arguments;let initial=a;a=8;return initial===undefined && x[0]===1 && x.length===1;}f(1);")
	mapped_eval(rt, c"function f(a){arguments[1]=9;return a===1 && arguments.length===2 && arguments[1]===9;}f(1,2);")
	mapped_eval(rt, c"function f(a){arguments[0]=9;return a===undefined && arguments[0]===9 && arguments.length===0;}f();")
	mapped_eval(rt, c"function f(a){let x=arguments;delete x[0];a=4;x[0]=8;return a===4 && x[0]===8;}f(1);")
	mapped_eval(rt, c"function f(a){let x=arguments;Object.defineProperty(x,'0',{configurable:false});let d=Reflect.deleteProperty(x,'0');a=7;return !d && x[0]===7;}f(1);")
	mapped_eval(rt, c"function f(a){let x=arguments;a=4;Object.defineProperty(x,'0',{writable:false});a=8;return x[0]===4 && !Reflect.set(x,'0',9) && a===8;}f(1);")
	mapped_eval(rt, c"function f(a){let x=arguments;Object.defineProperty(x,'0',{value:5,writable:false});let v=a;a=8;return v===5 && x[0]===5;}f(1);")
	mapped_eval(rt, c"function f(a){let x=arguments;Object.defineProperty(x,'0',{value:5});let v=a;a=8;return v===5 && x[0]===8;}f(1);")
	mapped_eval(rt, c"function f(a){let x=arguments;Object.defineProperty(x,'0',{get:function(){return 6;}});a=8;return x[0]===6 && a===8;}f(1);")
	mapped_eval(rt, c"function f(a){let x=arguments;Object.defineProperty(x,'0',{configurable:false});let bad=Reflect.defineProperty(x,'0',{value:9,configurable:true});let v=a;a=8;return !bad && v===1 && x[0]===8;}f(1);")
	mapped_eval(rt, c"function f(a){let x=arguments;let r={};let ok=Reflect.set(x,'0',7,r);a=8;return ok && r[0]===7 && Reflect.get(x,'0',r)===8;}f(1);")
	mapped_eval(rt, c"function f(a){let x=arguments;Object.preventExtensions(x);x[0]=7;return a===7;}f(1);")
	mapped_eval(rt, c"function f(a){let d=Object.getOwnPropertyDescriptor(arguments,'callee');return d.value===f && d.writable && d.configurable && !d.enumerable;}f(1);")
	mapped_eval(rt, c"function f(a){'use strict';a=7;return arguments[0]===1;}f(1);")
	mapped_eval(rt, c"function f(a=1){a=7;return arguments[0]===2;}f(2);")
	mapped_eval(rt, c"function f(a){let x=arguments;let d={};Object.defineProperty(d,'value',{get:function(){throw 17;}});let caught=0;try{Object.defineProperty(x,'0',d);}catch(e){caught=e;}a=6;return caught===17 && x[0]===6;}f(1);")
	mapped_eval(rt, c"function f(a){let x=arguments;Object.defineProperty(x,'0',{enumerable:false});a=7;return x[0]===7 && !Object.getOwnPropertyDescriptor(x,'0').enumerable;}f(1);")
	mapped_eval(rt, c"let saved;let set;let get;(function(a){saved=arguments;set=function(v){a=v;};get=function(){return a;};})({value:11});true;")
	js_runtime_collect(rt)
	mapped_eval(rt, c"saved[0].value===11 && get()===saved[0];")
	mapped_eval(rt, c"set({value:19});true;")
	js_runtime_collect(rt)
	mapped_eval(rt, c"saved[0].value===19 && Object.getOwnPropertyDescriptor(saved,'0').value===get();")
	mapped_eval(rt, c"set=null;get=null;true;")
	js_runtime_collect(rt)
	mapped_eval(rt, c"saved[0].value===19;")
	mapped_eval(rt, c"Object.defineProperty(saved,'0',{writable:false});true;")
	js_runtime_collect(rt)
	mapped_eval(rt, c"saved[0].value===19;")
	js_runtime* foreign = js_runtime_new()
	js_value* object = js_runtime_get(rt, rt.global, c"saved")
	assert_equal(0, js_runtime_set(rt, object, c"0", js_runtime_number(foreign, 3.0)))
	js_runtime_free(foreign)
	js_runtime_free(rt)
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_mapped_arguments_test: OK")
	return 0
