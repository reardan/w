# wbuild: name=javascript_runtime_array_join_test
# wbuild: target=javascript_runtime_array_join_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 --strict tests/javascript/runtime_array_join_test.w -o bin/javascript_runtime_array_join_test"
# wbuild: step="bin/javascript_runtime_array_join_test" expect_stdout="javascript_runtime_array_join_test: OK"
# wbuild: step="bin/javascript_runtime_array_join_test memory" expect_stdout="javascript_runtime_array_join_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

void join_eval(js_runtime* rt, char* source, int status):
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
	join_eval(rt, c"[1,null,undefined,'x'].join()==='1,,,x' && [].join('x')==='' && [1,2].join(null)==='1null2' && [1,2].toString()==='1,2';", 0)
	join_eval(rt, c"let sparse=Array(3);sparse[2]='z';sparse.join('-')==='--z' && Array.prototype.join.call({0:'a',2:'c',length:3},':')==='a::c';", 0)
	join_eval(rt, c"function Base(){}Base.prototype[1]='b';let inherited=new Base();inherited[0]='a';inherited.length=2;Array.prototype.join.call(inherited,'')==='ab';", 0)
	join_eval(rt, c"let mutate={0:'a',1:'b',length:2};let sep={toString:function(){mutate[1]='c';mutate.length=1;return '-';}};Array.prototype.join.call(mutate,sep)==='a-c';", 0)
	join_eval(rt, c"let reads='';let source={};Object.defineProperty(source,'length',{get:function(){reads+='l';return 2;}});Object.defineProperty(source,'0',{get:function(){reads+='a';return 1;}});Object.defineProperty(source,'1',{get:function(){reads+='b';return 2;}});let separator={toString:function(){reads+='s';return ':';}};Array.prototype.join.call(source,separator)==='1:2' && reads==='lsab';", 0)
	join_eval(rt, c"let self=[];self[0]=self;self[1]=3;self.join()===',3';", 0)
	join_eval(rt, c"let outer=[1];let inner=[outer,2];outer[1]=inner;outer.join()==='1,,2' && String(outer)==='1,,2';", 0)
	join_eval(rt, c"let recover=[{toString:function(){throw 9;}}];let error=0;try{recover.join();}catch(e){error=e;}recover[0]=2;error===9 && recover.join()==='2';", 0)
	join_eval(rt, c"let custom=[1];custom.join=function(){return 17;};custom.toString()===17 && Array.prototype.join.call('ab','-')==='a-b';", 0)
	join_eval(rt, c"String([])==='' && String([1,2])==='1,2' && [[1,2],[3]].join(';')==='1,2;3';", 0)
	join_eval(rt, c"Array.prototype.join.length===1 && Array.prototype.join.name==='join' && Array.prototype.toString.length===0 && Array.prototype.toString.name==='toString';", 0)
	join_eval(rt, c"let nil=0;try{Array.prototype.join.call(null);}catch(e){nil=e.constructor===TypeError;}let sym=0;try{[Symbol()].join();}catch(e){sym=e.constructor===TypeError;}nil && sym;", 0)
	join_eval(rt, c"let nolength={join:3};Array.prototype.toString.call(nolength)==='[object Object]';", 0)
	# Limits: output length and the evaluation budget.
	rt.max_properties = 8
	join_eval(rt, c"[1,2,3,4,5].join('--');", 5)
	rt.max_properties = 10000
	join_eval(rt, c"Array.prototype.join.call({length:1/0});", 5)
	char* source = c"Array.prototype.join.call({length:1000},',');"
	assert_equal(5, js_runtime_eval(rt, source, strlen(source), 40).status)
	source = c"var parts=[];for (var i=0;i<20;i++) parts[i]='abcdefghij';parts.join('-').length;"
	assert_equal(5, js_runtime_eval(rt, source, strlen(source), 200).status)
	join_eval(rt, c"let deep=[];deep[0]=deep;deep.join()==='';", 0)
	js_runtime_free(rt)
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_array_join_test: OK")
	return 0
