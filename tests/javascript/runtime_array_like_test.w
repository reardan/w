# wbuild: name=javascript_runtime_array_like_test
# wbuild: target=javascript_runtime_array_like_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 --strict tests/javascript/runtime_array_like_test.w -o bin/javascript_runtime_array_like_test"
# wbuild: step="bin/javascript_runtime_array_like_test" expect_stdout="javascript_runtime_array_like_test: OK"
# wbuild: step="bin/javascript_runtime_array_like_test memory" expect_stdout="javascript_runtime_array_like_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

void array_like_eval(js_runtime* rt, char* source, int status):
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
	# Generic slice: relative bounds, holes, array-likes and strings.
	array_like_eval(rt, c"[1,2,3,4].slice(1,3).join()==='2,3' && [1,2,3].slice(-2).join()==='2,3' && [1,2,3].slice(1,-1).join()==='2' && [1,2,3].slice().length===3 && [1,2,3].slice(5).length===0;", 0)
	array_like_eval(rt, c"let sparse=Array(4);sparse[2]='x';let part=sparse.slice(1,4);part.length===3 && !(0 in part) && part[1]==='x' && !(2 in part);", 0)
	array_like_eval(rt, c"let like=Array.prototype.slice.call({0:'a',1:'b',2:'c',length:3},1);like.length===2 && like[0]==='b' && Array.isArray(like);", 0)
	array_like_eval(rt, c"let letters=Array.prototype.slice.call('abc',1);letters.length===2 && letters[0]==='b' && letters[1]==='c';", 0)
	array_like_eval(rt, c"[1,2,3].slice(undefined,undefined).length===3 && [1,2,3].slice(0,Infinity).length===3 && [1,2,3].slice(-Infinity,1).length===1 && [1,2,3].slice(NaN,2).length===2;", 0)
	array_like_eval(rt, c"let order='';let start={valueOf:function(){order+='s';return 0;}};let end={valueOf:function(){order+='e';return 1;}};[1,2].slice(start,end).length===1 && order==='se';", 0)
	array_like_eval(rt, c"Array.prototype.slice.length===2 && Array.prototype.slice.name==='slice';", 0)
	array_like_eval(rt, c"let nil=0;try{Array.prototype.slice.call(undefined);}catch(e){nil=e.constructor===TypeError;}let bad=[1];bad.constructor=3;let species=0;try{bad.slice();}catch(e){species=e.constructor===TypeError;}nil && species;", 0)
	array_like_eval(rt, c"class Sub extends Array{}let sub=new Sub();sub.push(1,2,3);let cut=sub.slice(1);cut instanceof Sub && cut.length===2 && cut[0]===2;", 0)
	array_like_eval(rt, c"Array.prototype.slice.call({length:1/0});", 5)
	char* source = c"Array.prototype.slice.call({length:1000});"
	assert_equal(5, js_runtime_eval(rt, source, strlen(source), 40).status)
	# indexOf: strict equality over present elements, fromIndex coercion.
	array_like_eval(rt, c"[1,2,3].indexOf(2)===1 && [1,2,1].indexOf(1,1)===2 && [1,2,3].indexOf(4)===-1 && [1,2,3].indexOf(3,-1)===2 && [1,2,3].indexOf(1,-1)===-1;", 0)
	array_like_eval(rt, c"[1,2].indexOf(1,-Infinity)===0 && [1,2].indexOf(2,Infinity)===-1 && [1,2].indexOf(1,NaN)===0 && [1,2].indexOf(1,10)===-1 && [].indexOf(1)===-1;", 0)
	array_like_eval(rt, c"[NaN].indexOf(NaN)===-1 && [-0].indexOf(0)===0 && ['1'].indexOf(1)===-1 && [1n].indexOf(1n)===0 && Array(2).indexOf(undefined)===-1 && [undefined].indexOf()===0;", 0)
	array_like_eval(rt, c"Array.prototype.indexOf.call('abca','a',1)===3 && Array.prototype.indexOf.call({1:'x',length:3},'x')===1 && Array.prototype.indexOf.length===1;", 0)
	array_like_eval(rt, c"let trace='';let live={length:3};Object.defineProperty(live,'0',{get:function(){trace+='0';return 1;}});Object.defineProperty(live,'1',{get:function(){trace+='1';return 2;}});Array.prototype.indexOf.call(live,2)===1 && trace==='01';", 0)
	array_like_eval(rt, c"let empty={valueOf:function(){throw 1;}};[].indexOf(1,empty)===-1;", 0)
	array_like_eval(rt, c"Array.prototype.indexOf.call({length:1/0},1);", 5)
	source = c"Array.prototype.indexOf.call({length:1000},1);"
	assert_equal(5, js_runtime_eval(rt, source, strlen(source), 40).status)
	js_runtime_free(rt)
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_array_like_test: OK")
	return 0
