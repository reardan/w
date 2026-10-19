# wbuild: name=javascript_runtime_array_concat_test
# wbuild: target=javascript_runtime_array_concat_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 --strict tests/javascript/runtime_array_concat_test.w -o bin/javascript_runtime_array_concat_test"
# wbuild: step="bin/javascript_runtime_array_concat_test" expect_stdout="javascript_runtime_array_concat_test: OK"
# wbuild: step="bin/javascript_runtime_array_concat_test memory" expect_stdout="javascript_runtime_array_concat_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

void array_concat_eval(js_runtime* rt, char* source, int status):
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
	array_concat_eval(rt, c"[1,2].concat([3],4,[5,6]).join(',')==='1,2,3,4,5,6' && Array.prototype.concat.length===1;", 0)
	array_concat_eval(rt, c"let a=[1];let b=a.concat();b!==a && b[0]===1 && a.length===1 && a.concat(a).join(',')==='1,1';", 0)
	array_concat_eval(rt, c"let holes=Array(2);holes[1]=3;let joined=holes.concat(Array(2),4);joined.length===5 && !(0 in joined) && joined[1]===3 && !(2 in joined) && !(3 in joined) && joined[4]===4;", 0)
	array_concat_eval(rt, c"let object={0:'x',length:1};let generic=Array.prototype.concat.call(object,[2],3);generic.length===3 && generic[0]===object && generic[1]===2 && generic[2]===3;", 0)
	array_concat_eval(rt, c"let boxed=Array.prototype.concat.call('ab','cd');boxed.length===2 && boxed[0].valueOf()==='ab' && boxed[1]==='cd' && Object.getPrototypeOf(boxed[0])===String.prototype;", 0)
	array_concat_eval(rt, c"let nested=[['a']];let retained=[].concat(nested);retained[0]===nested[0] && [].concat(null,undefined).length===2;", 0)
	array_concat_eval(rt, c"let spread=Array(2);let proto={};Object.defineProperty(proto,'0',{get:function(){spread[1]='later';return 'first';}});Object.setPrototypeOf(spread,proto);let result=Array.prototype.concat.call(spread);result.length===2 && result[0]==='first' && result[1]==='later';", 0)
	array_concat_eval(rt, c"let source=Array(2);let shrink={};Object.defineProperty(shrink,'0',{get:function(){source.length=0;return 7;}});Object.setPrototypeOf(source,shrink);let snap=Array.prototype.concat.call(source);snap.length===2 && snap[0]===7 && !(1 in snap);", 0)
	array_concat_eval(rt, c"let failures=0;Object.defineProperty(Object.prototype,'0',{set:function(){failures++;},configurable:true});let stored=[].concat('ok');delete Object.prototype[0];failures===0 && stored[0]==='ok';", 0)
	array_concat_eval(rt, c"let ctorArray=[1];ctorArray.constructor={};ctorArray.concat()[0]===1;", 0)
	array_concat_eval(rt, c"let bad=[1];bad.constructor=null;let error=0;try{bad.concat();}catch(e){error=e.constructor===TypeError;}error;", 0)
	array_concat_eval(rt, c"let visits='';let ctorProto={};Object.defineProperty(ctorProto,'constructor',{get:function(){visits+='c';return undefined;}});Object.defineProperty(ctorProto,'0',{get:function(){visits+='0';return 7;}});let ordered=Array(1);Object.setPrototypeOf(ordered,ctorProto);Array.prototype.concat.call(ordered)[0]===7 && visits==='c0';", 0)
	array_concat_eval(rt, c"let throwing=Array(1);let throwingProto={};Object.defineProperty(throwingProto,'0',{get:function(){throw 88;}});Object.setPrototypeOf(throwing,throwingProto);let caught=0;try{[].concat(throwing);}catch(e){caught=e;}caught===88;", 0)
	array_concat_eval(rt, c"let nil=0;try{Array.prototype.concat.call(null);}catch(e){nil=e.constructor===TypeError;}nil;", 0)
	js_runtime_collect(rt)
	array_concat_eval(rt, c"retained[0]===nested[0] && boxed[0].valueOf()==='ab';", 0)
	rt.max_properties = 64
	array_concat_eval(rt, c"Array(40).concat(Array(40));", 5)
	rt.max_properties = 10000
	array_concat_eval(rt, c"true;", 0)
	js_runtime* foreign = js_runtime_new()
	list[js_value*] arguments = new list[js_value*]
	js_value* method = js_runtime_get(rt, rt.array_prototype, c"concat")
	arguments.push(foreign.undefined_value)
	js_runtime_call_receiver(rt, method, rt.array_prototype, arguments)
	assert_equal(2, rt.completion.status)
	__w_list_free(cast(__w_list*, arguments))
	js_runtime_free(foreign)
	js_runtime_free(rt)
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_array_concat_test: OK")
	return 0
