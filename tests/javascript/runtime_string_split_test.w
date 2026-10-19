# wbuild: name=javascript_runtime_string_split_test
# wbuild: target=javascript_runtime_string_split_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 --strict tests/javascript/runtime_string_split_test.w -o bin/javascript_runtime_string_split_test"
# wbuild: step="bin/javascript_runtime_string_split_test" expect_stdout="javascript_runtime_string_split_test: OK"
# wbuild: step="bin/javascript_runtime_string_split_test memory" expect_stdout="javascript_runtime_string_split_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

void string_split_eval(js_runtime* rt, char* source, int status):
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
	string_split_eval(rt, c"let x='a.b.c'.split('.');x.length===3 && x[0]==='a' && x[1]==='b' && x[2]==='c' && String.prototype.split.length===2;", 0)
	string_split_eval(rt, c"'..'.split('.').length===3 && '.a.'.split('.').join('|')==='|a|' && 'aaa'.split('aa').join('|')==='|a';", 0)
	string_split_eval(rt, c"''.split('').length===0 && ''.split('.').length===1 && ''.split()[0]==='' && 'abc'.split()[0]==='abc';", 0)
	string_split_eval(rt, c"'ab'.split('').join('|')==='a|b' && 'ab'.split('',1)[0]==='a' && 'ab'.split('',0).length===0;", 0)
	string_split_eval(rt, c"'a.b.c'.split('.',2).join('|')==='a|b' && 'a.b'.split('.',-1).length===2 && 'a.b'.split('.',4294967296).length===0 && 'a.b'.split('.',4294967297).length===1;", 0)
	string_split_eval(rt, c"'a.b'.split('.',NaN).length===0 && 'a.b'.split('.',Infinity).length===0 && 'a.b'.split('.',-Infinity).length===0 && 'a.b'.split('.',1.9).length===1;", 0)
	string_split_eval(rt, c"let pair=String.fromCharCode(55296,56320);let units=pair.split('');units.length===2 && units[0]===String.fromCharCode(55296) && units[1]===String.fromCharCode(56320);", 0)
	string_split_eval(rt, c"let nul=String.fromCharCode(0);('a'+nul+'b').split(nul).join('|')==='a|b' && 'nullxnull'.split(null).join('|')==='|x|';", 0)
	string_split_eval(rt, c"String.prototype.split.call(121,2).join('|')==='1|1' && String.prototype.split.call(true,'r').join('|')==='t|ue';", 0)
	string_split_eval(rt, c"let log='';let receiver={toString:function(){log+='r';return 'a.b';}};let sep={toString:function(){log+='s';return '.';}};let lim={valueOf:function(){log+='l';return 0;}};String.prototype.split.call(receiver,sep,lim).length===0 && log==='rls';", 0)
	string_split_eval(rt, c"let thrown=0;try{'abc'.split({toString:function(){throw 9;}},0);}catch(e){thrown=e;}thrown===9;", 0)
	string_split_eval(rt, c"let trace='';let error=0;try{String.prototype.split.call({toString:function(){trace+='r';throw 12;}},{toString:function(){trace+='s';return '.';}},{valueOf:function(){trace+='l';return 1;}});}catch(e){error=e;}error===12 && trace==='r';", 0)
	string_split_eval(rt, c"let bad=0;try{'abc'.split('',1n);}catch(e){bad=e.constructor===TypeError;}bad;", 0)
	string_split_eval(rt, c"let count=0;try{String.prototype.split.call(null,{toString:function(){count++;return '.';}});}catch(e){if(e.constructor===TypeError)count+=10;}count===10;", 0)
	string_split_eval(rt, c"let setterCalls=0;Object.defineProperty(Object.prototype,'0',{set:function(){setterCalls++;},configurable:true});let parts='a.b'.split('.');delete Object.prototype[0];setterCalls===0 && parts[0]==='a' && parts[1]==='b';", 0)
	string_split_eval(rt, c"'a'.split(/a/).join('|')==='|';", 0)
	js_runtime_free(rt)
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_string_split_test: OK")
	return 0
