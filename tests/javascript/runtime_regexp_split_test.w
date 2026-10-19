# wbuild: name=javascript_runtime_regexp_split_test
# wbuild: target=javascript_runtime_regexp_split_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 --strict tests/javascript/runtime_regexp_split_test.w -o bin/javascript_runtime_regexp_split_test"
# wbuild: step="bin/javascript_runtime_regexp_split_test" expect_stdout="javascript_runtime_regexp_split_test: OK"
# wbuild: step="bin/javascript_runtime_regexp_split_test memory" expect_stdout="javascript_runtime_regexp_split_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

void regexp_split_eval(js_runtime* rt, char* source, int expected):
	js_runtime_collect(rt)
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 100000)
	if (result.status != expected || (expected == 0 && result.value.number != 1.0)):
		println(source)
		println(result.message)
	assert_equal(expected, result.status)
	if (expected == 0): assert1(result.value.number == 1.0)

int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	js_runtime* rt = js_runtime_new()
	regexp_split_eval(rt, c"'a,b;c'.split(/[,;]/).join('|')==='a|b|c' && ',a,'.split(/,/g).join('|')==='|a|' && 'aa'.split(/a/).join('|')==='||';", 0)
	regexp_split_eval(rt, c"'a,b;c'.split(/[,;]/y).join('|')==='a|b|c' && 'AaA'.split(/a/i).length===4 && 'ab'.split(/b/g).join('|')==='a|';", 0)
	regexp_split_eval(rt, c"let pieces='a1b2c'.split(/([0-9])/);pieces.join('|')==='a|1|b|2|c' && 'a1b'.split(/([0-9])/,2).join('|')==='a|1';", 0)
	regexp_split_eval(rt, c"pieces='a,b'.split(/(x)?(,)/);pieces.length===4 && pieces[0]==='a' && pieces[1]===undefined && Object.hasOwn(pieces,'1') && pieces[2]===',' && pieces[3]==='b';", 0)
	regexp_split_eval(rt, c"''.split(/a/).length===1 && ''.split(/(?:)/).length===0 && ''.split(/()/).length===0 && ''.split(/a/,0).length===0;", 0)
	regexp_split_eval(rt, c"'abc'.split(/(?:)/).join('|')==='a|b|c' && 'abc'.split(/()/).join('|')==='a||b||c' && 'ab'.split(/a*?/).join('|')==='a|b' && 'ab'.split(/a*/).join('|')==='|b';", 0)
	regexp_split_eval(rt, c"'ab'.split(/^/).join('|')==='ab' && 'ab'.split(/$/).join('|')==='ab' && 'ab'.split(/(?=b)/).join('|')==='a|b' && 'ab'.split(/(?!b)/).join('|')==='ab';", 0)
	regexp_split_eval(rt, c"let re=/,/g;re.lastIndex=77;pieces='a,b'.split(re);pieces.length===2 && re.lastIndex===77;", 0)
	regexp_split_eval(rt, c"Object.defineProperty(re,'lastIndex',{writable:false});'a,b'.split(re).join('|')==='a|b' && re.lastIndex===77;", 0)
	regexp_split_eval(rt, c"let calls=0;re.exec=function(){calls++;throw 1;};Object.defineProperty(re,'source',{get:function(){throw 2;}});'a,b'.split(re).length===2 && calls===0;", 0)
	regexp_split_eval(rt, c"'a,b'.split(/,/,4294967296).length===0 && 'a,b'.split(/,/,4294967297).join('|')==='a' && 'a,b'.split(/,/,-1).length===2 && 'a,b'.split(/,/,Infinity).length===0;", 0)
	regexp_split_eval(rt, c"let pair=String.fromCharCode(55296,56320);pieces=pair.split(/(?:)/);pieces.length===2 && pieces[0]===String.fromCharCode(55296) && pieces[1]===String.fromCharCode(56320);", 0)
	regexp_split_eval(rt, c"String.prototype.split.call(121,/2/).join('|')==='1|1' && ('a'+String.fromCharCode(0)+'b').split(/\\u0000/).join('|')==='a|b';", 0)
	regexp_split_eval(rt, c"let order='';let sep=/,/;Object.defineProperty(sep,'constructor',{get:function(){order+='c';return undefined;},configurable:true});Object.defineProperty(sep,'flags',{get:function(){order+='f';return {toString:function(){order+='s';return 'g';}};},configurable:true});let receiver={toString:function(){order+='r';return 'a,b';}};let limit={valueOf:function(){order+='l';return 0;}};String.prototype.split.call(receiver,sep,limit).length===0 && order==='rcfsl';", 0)
	regexp_split_eval(rt, c"order='';let error=0;Object.defineProperty(sep,'constructor',{get:function(){order+='c';throw 31;}});try{String.prototype.split.call(receiver,sep,limit);}catch(e){error=e;}error===31 && order==='rc';", 0)
	regexp_split_eval(rt, c"let invalid=/,/;invalid.constructor=1;error=0;try{'a,b'.split(invalid,0);}catch(e){error=e.constructor===TypeError;}error===true;", 0)
	regexp_split_eval(rt, c"invalid.constructor={};'a,b'.split(invalid).length===2;", 0)
	regexp_split_eval(rt, c"let flagError=/,/;Object.defineProperty(flagError,'flags',{get:function(){throw 41;}});error=0;try{'a,b'.split(flagError,0);}catch(e){error=e;}error===41;", 0)
	regexp_split_eval(rt, c"let flags=/,/;Object.defineProperty(flags,'flags',{value:'gg'});error=0;try{'a,b'.split(flags,0);}catch(e){error=e.constructor===SyntaxError;}error===true;", 0)
	regexp_split_eval(rt, c"error=0;try{'a,b'.split(/,/,1n);}catch(e){error=e.constructor===TypeError;}error===true;", 0)
	regexp_split_eval(rt, c"calls=0;Object.defineProperty(Object.prototype,'0',{set:function(){calls++;},configurable:true});pieces='a,b'.split(/(,)/);delete Object.prototype[0];calls===0 && pieces.join('|')==='a|,|b';", 0)
	regexp_split_eval(rt, c"let originalExec=RegExp.prototype.exec;RegExp.prototype.exec=function(){return null;};'a,b'.split(/,/);", 6)
	regexp_split_eval(rt, c"RegExp.prototype.exec=originalExec;true;", 0)
	regexp_split_eval(rt, c"Object.defineProperty(RegExp.prototype,'exec',{get:function(){throw 51;},configurable:true});error=0;try{'a,b'.split(/,/);}catch(e){error=e;}Object.defineProperty(RegExp.prototype,'exec',{value:originalExec,writable:true,configurable:true});error===51;", 0)
	js_runtime* foreign = js_runtime_new()
	list[js_value*] arguments = new list[js_value*]
	arguments.push(foreign.undefined_value)
	js_value* method = js_runtime_get(rt, rt.string_prototype, c"split")
	js_runtime_call_receiver(rt, method, rt.undefined_value, arguments)
	assert_equal(2, rt.completion.status)
	__w_list_free(cast(__w_list*, arguments))
	js_runtime_free(foreign)
	regexp_split_eval(rt, c"true;", 0)
	char* bounded = c"'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'.split(/a/);"
	assert_equal(5, js_runtime_eval(rt, bounded, strlen(bounded), 40).status)
	for budget in range(1, 90):
		js_runtime_collect(rt)
		js_completion* result = js_runtime_eval(rt, bounded, strlen(bounded), budget)
		assert1(result.status == 0 || result.status == 5)
	regexp_split_eval(rt, c"let many=/a/;true;", 0)
	rt.max_properties = 4
	char* output_limit = c"'aaaaaa'.split(many);"
	assert_equal(5, js_runtime_eval(rt, output_limit, strlen(output_limit), 100000).status)
	rt.max_properties = 65536
	js_runtime_free(rt)
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_regexp_split_test: OK")
	return 0
