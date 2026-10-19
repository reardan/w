# wbuild: name=javascript_runtime_join_power_test
# wbuild: target=javascript_runtime_join_power_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 --strict tests/javascript/runtime_join_power_test.w -o bin/javascript_runtime_join_power_test"
# wbuild: step="bin/javascript_runtime_join_power_test" expect_stdout="javascript_runtime_join_power_test: OK"
# wbuild: step="bin/javascript_runtime_join_power_test memory" expect_stdout="javascript_runtime_join_power_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

void join_power_eval(js_runtime* rt, char* source, int status):
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
	join_power_eval(rt, c"Math.pow(2,32)===4294967296 && Math.pow(-2,3)===-8 && Math.pow(4,0.5)===2 && Math.pow.length===2;", 0)
	join_power_eval(rt, c"Object.is(Math.pow(-0,3),-0) && Object.is(Math.pow(-0,2),0) && Math.pow(-0,-3)===-Infinity && Math.pow(-Infinity,-3)===-0;", 0)
	join_power_eval(rt, c"Number.isNaN(Math.pow(1,NaN)) && Number.isNaN(Math.pow(1,Infinity)) && Number.isNaN(Math.pow(-1,-Infinity)) && Number.isNaN(Math.pow(-2,0.5)) && Math.pow(NaN,0)===1;", 0)
	join_power_eval(rt, c"let order='';let base={valueOf:function(){order+='b';return NaN;}};let exponent={valueOf:function(){order+='e';return 0;}};Math.pow(base,exponent)===1 && order==='be';", 0)
	join_power_eval(rt, c"let thrown=0;try{Math.pow(2,{valueOf:function(){throw 71;}});}catch(e){thrown=e;}thrown===71;", 0)
	join_power_eval(rt, c"let bigint=0;try{Math.pow(1n,2);}catch(e){bigint=e.constructor===TypeError;}bigint;", 0)
	join_power_eval(rt, c"[1,null,undefined,'x'].join()==='1,,,x' && [].join('x')==='' && [1,2].join(null)==='1null2' && [1,2].toString()==='1,2';", 0)
	join_power_eval(rt, c"let sparse=Array(3);sparse[2]='z';sparse.join('-')==='--z' && Array.prototype.join.call({0:'a',2:'c',length:3},':')==='a::c';", 0)
	join_power_eval(rt, c"let inherited=Object.create({1:'b'});inherited[0]='a';inherited.length=2;Array.prototype.join.call(inherited,'')==='ab';", 0)
	join_power_eval(rt, c"let mutate={0:'a',1:'b',length:2};let sep={toString:function(){mutate[1]='c';mutate.length=1;return '-';}};Array.prototype.join.call(mutate,sep)==='a-c';", 0)
	join_power_eval(rt, c"let reads='';let source={};Object.defineProperty(source,'length',{get:function(){reads+='l';return 2;}});Object.defineProperty(source,'0',{get:function(){reads+='a';return 1;}});Object.defineProperty(source,'1',{get:function(){reads+='b';return 2;}});let separator={toString:function(){reads+='s';return ':';}};Array.prototype.join.call(source,separator)==='1:2' && reads==='lsab';", 0)
	join_power_eval(rt, c"let self=[];self[0]=self;self[1]=3;self.join()===',3';", 0)
	join_power_eval(rt, c"let recover=[{toString:function(){throw 9;}}];let error=0;try{recover.join();}catch(e){error=e;}recover[0]=2;error===9 && recover.join()==='2';", 0)
	join_power_eval(rt, c"let custom=[1];custom.join=function(){return 17;};custom.toString()===17 && Array.prototype.toString.call({join:3})==='[object Object]' && Array.prototype.join.call('ab','-')==='a-b';", 0)
	join_power_eval(rt, c"Object.getPrototypeOf(Array.prototype)===Object.prototype && [1].hasOwnProperty('0') && String([])==='' && String([1,2])==='1,2';", 0)
	js_runtime_free(rt)
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_join_power_test: OK")
	return 0
