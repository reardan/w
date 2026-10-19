# wbuild: name=javascript_runtime_boxed_test
# wbuild: target=javascript_runtime_boxed_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 --strict tests/javascript/runtime_boxed_test.w -o bin/javascript_runtime_boxed_test"
# wbuild: step="bin/javascript_runtime_boxed_test" expect_stdout="javascript_runtime_boxed_test: OK"
# wbuild: step="bin/javascript_runtime_boxed_test memory" expect_stdout="javascript_runtime_boxed_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

void boxed_eval(js_runtime* rt, char* source, int status):
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
	boxed_eval(rt, c"let n=Object(7);let b=Object(false);let s=Object('ab');n.valueOf()===7 && b.valueOf()===false && s.valueOf()==='ab' && n!==Object(7) && Object(n)===n;", 0)
	boxed_eval(rt, c"Object.getPrototypeOf(n)===Number.prototype && Object.getPrototypeOf(b)===Boolean.prototype && Object.getPrototypeOf(s)===String.prototype && n instanceof Number;", 0)
	boxed_eval(rt, c"Number()===0 && Number(null)===0 && Number(true)===1 && Number('0x10')===16 && Object.is(Number('-0'),-0) && Number.isNaN(Number(undefined)) && Number(1n)===1;", 0)
	boxed_eval(rt, c"Boolean()===false && Boolean('')===false && Boolean({})===true && new Boolean(false).valueOf()===false && new Number('5').valueOf()===5 && new String(7).valueOf()==='7';", 0)
	boxed_eval(rt, c"let text=new String('a\\ud800');let d=Object.getOwnPropertyDescriptor(text,'1');text.length===2 && d.value==='\\ud800' && !d.writable && d.enumerable && !d.configurable && !delete text[1];", 0)
	boxed_eval(rt, c"Object.getOwnPropertyDescriptor('xy','0').value==='x' && Object.keys('xy').length===2 && Object.getOwnPropertyNames('xy')[2]==='length' && Object.hasOwn('xy','1');", 0)
	boxed_eval(rt, c"Object.getOwnPropertyNames(7).length===0 && Object.getPrototypeOf(false)===Boolean.prototype && Object.setPrototypeOf(1,{})===1 && Object.preventExtensions(1)===1 && !Object.isExtensible(1);", 0)
	boxed_eval(rt, c"String(s)==='ab' && n+2===9 && b==false && Number.prototype.valueOf.call(8)===8 && Boolean.prototype.toString.call(false)==='false' && String.prototype.toString.call('x')==='x';", 0)
	boxed_eval(rt, c"Object.prototype.toString.call(n)==='[object Number]' && Object.prototype.toString.call(b)==='[object Boolean]' && Object.prototype.toString.call(s)==='[object String]' && Object.prototype.toString.call(Object(1n))==='[object BigInt]';", 0)
	boxed_eval(rt, c"let bad=0;try{Number.prototype.valueOf.call({valueOf:function(){return 7;}});}catch(e){bad=e.constructor===TypeError;}bad;", 0)
	boxed_eval(rt, c"let order='';let cv={valueOf:function(){order+='v';return 8;},toString:function(){order+='s';return '9';}};Number(cv)===8 && new String(cv).valueOf()==='9' && order==='vs';", 0)
	boxed_eval(rt, c"Object.create({},7).constructor===Object && Object.prototype.valueOf.call(7).valueOf()===7 && Object.prototype.hasOwnProperty.call('xy','0');", 0)
	boxed_eval(rt, c"let forbidden=0;try{Object.getOwnPropertyDescriptor(null,{toString:function(){forbidden++;return 'x';}});}catch(e){}forbidden===0;", 0)
	boxed_eval(rt, c"Object(2n).valueOf()===2n && Object(2n).toString()==='2';", 0)
	boxed_eval(rt, c"Number.prototype.toString.call(1,2);", 6)
	boxed_eval(rt, c"let range=0;try{Number.prototype.toString.call(1,1);}catch(e){range=e.constructor===RangeError;}range;", 0)
	js_runtime_free(rt)
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_boxed_test: OK")
	return 0
