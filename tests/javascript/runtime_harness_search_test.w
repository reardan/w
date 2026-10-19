# wbuild: name=javascript_runtime_harness_search_test
# wbuild: target=javascript_runtime_harness_search_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 --strict tests/javascript/runtime_harness_search_test.w -o bin/javascript_runtime_harness_search_test"
# wbuild: step="bin/javascript_runtime_harness_search_test" expect_stdout="javascript_runtime_harness_search_test: OK"
# wbuild: step="bin/javascript_runtime_harness_search_test memory" expect_stdout="javascript_runtime_harness_search_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

void harness_search_eval(js_runtime* rt, char* source, int status):
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
	harness_search_eval(rt, c"String.fromCharCode()==='' && String.fromCharCode(65,66)==='AB' && String.fromCharCode.length===1;", 0)
	harness_search_eval(rt, c"String.fromCharCode(65537,-65535,1.9)===String.fromCharCode(1,1,1) && String.fromCharCode(-1,-1.9)===String.fromCharCode(65535,65535);", 0)
	harness_search_eval(rt, c"String.fromCharCode(NaN,Infinity,-Infinity,undefined,null,-0)===String.fromCharCode(0,0,0,0,0,0);", 0)
	harness_search_eval(rt, c"String.fromCharCode(55296).length===1 && String.fromCharCode(55296,56320).length===2 && String.fromCharCode(0).length===1;", 0)
	harness_search_eval(rt, c"String.fromCharCode(9007199254740991)===String.fromCharCode(65535) && String.fromCharCode(1.7976931348623157e308)===String.fromCharCode(0);", 0)
	harness_search_eval(rt, c"let order='';let a={valueOf:function(){order+='a';return 65;}};let b={valueOf:function(){order+='b';return 66;}};String.fromCharCode(a,b)==='AB' && order==='ab';", 0)
	harness_search_eval(rt, c"let reads='';let caught=0;try{String.fromCharCode({valueOf:function(){reads+='a';throw 12;}},{valueOf:function(){reads+='b';return 1;}});}catch(e){caught=e;}caught===12 && reads==='a';", 0)
	harness_search_eval(rt, c"let big=0;try{String.fromCharCode(1n);}catch(e){big=e.constructor===TypeError;}big;", 0)
	harness_search_eval(rt, c"[1,2,1].indexOf(1)===0 && [1,2,1].indexOf(1,1)===2 && [1,2].indexOf(3)===-1 && Array.prototype.indexOf.length===1;", 0)
	harness_search_eval(rt, c"[1,2,1].indexOf(1,-1)===2 && [1,2].indexOf(1,-Infinity)===0 && [1].indexOf(1,Infinity)===-1 && [1].indexOf(1,NaN)===0 && [1].indexOf(1,-0.9)===0;", 0)
	harness_search_eval(rt, c"[NaN].indexOf(NaN)===-1 && [-0].indexOf(0)===0 && ['1'].indexOf(1)===-1 && [1n].indexOf(1n)===0;", 0)
	harness_search_eval(rt, c"let x={};[x].indexOf(x)===0 && [x].indexOf({})===-1 && Array(2).indexOf(undefined)===-1 && [undefined].indexOf()===0;", 0)
	harness_search_eval(rt, c"Array.prototype.indexOf.call('abc','b')===1 && Array.prototype.indexOf.call({1:'x',length:3},'x')===1;", 0)
	harness_search_eval(rt, c"let inherited=Object.create({1:'x'});inherited.length=2;Array.prototype.indexOf.call(inherited,'x')===1;", 0)
	harness_search_eval(rt, c"let log='';let obj={};Object.defineProperty(obj,'length',{get:function(){log+='l';return 2;}});Object.defineProperty(obj,'0',{get:function(){log+='0';return 1;}});Object.defineProperty(obj,'1',{get:function(){log+='1';return 2;}});let start={valueOf:function(){log+='s';return 0;}};Array.prototype.indexOf.call(obj,2,start)===1 && log==='ls01';", 0)
	harness_search_eval(rt, c"let empty={valueOf:function(){throw 1;}};[].indexOf(1,empty)===-1;", 0)
	harness_search_eval(rt, c"let live={0:1,1:2,length:2};let from={valueOf:function(){live[1]=3;live.length=0;return 0;}};Array.prototype.indexOf.call(live,3,from)===1;", 0)
	harness_search_eval(rt, c"Number.prototype.length=1;Number.prototype[0]='x';let boxed=Array.prototype.indexOf.call(7,'x');delete Number.prototype.length;delete Number.prototype[0];boxed===0;", 0)
	harness_search_eval(rt, c"let thrown=0;let target={length:1};Object.defineProperty(target,'0',{get:function(){throw 19;}});try{Array.prototype.indexOf.call(target,1);}catch(e){thrown=e;}thrown===19;", 0)
	harness_search_eval(rt, c"let errors=0;try{Array.prototype.indexOf.call(null,1);}catch(e){if(e.constructor===TypeError)errors++;}try{[1].indexOf(1,1n);}catch(e){if(e.constructor===TypeError)errors++;}errors===2;", 0)
	harness_search_eval(rt, c"Array.prototype.indexOf.call({length:Infinity},1);", 5)
	js_runtime_free(rt)
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_harness_search_test: OK")
	return 0
