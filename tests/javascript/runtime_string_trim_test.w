# wbuild: name=javascript_runtime_string_trim_test
# wbuild: target=javascript_runtime_string_trim_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 --strict tests/javascript/runtime_string_trim_test.w -o bin/javascript_runtime_string_trim_test"
# wbuild: step="bin/javascript_runtime_string_trim_test" expect_stdout="javascript_runtime_string_trim_test: OK"
# wbuild: step="bin/javascript_runtime_string_trim_test memory" expect_stdout="javascript_runtime_string_trim_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

void trim_eval(js_runtime* rt, char* source):
	js_runtime_collect(rt)
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
	trim_eval(rt, c"''.trim()==='' && '  '.trim()==='' && ' a b '.trim()==='a b' && 'abc'.trim()==='abc' && ' a b '.trimStart()==='a b ' && ' a b '.trimEnd()===' a b';")
	trim_eval(rt, c"let spaces=[9,10,11,12,13,32,160,5760,8192,8193,8194,8195,8196,8197,8198,8199,8200,8201,8202,8232,8233,8239,8287,12288,65279];let all='';let valid=true;for(let i=0;i<spaces.length;i++){let s=String.fromCharCode(spaces[i]);all+=s;if((s+'x'+s).trim()!=='x'||(s+'x'+s).trimStart()!=='x'+s||(s+'x'+s).trimEnd()!==s+'x')valid=false;}valid && all.trim()==='' && all.trimStart()==='' && all.trimEnd()==='';")
	trim_eval(rt, c"let kept=[0,133,6158,8203,8288,55296,56320,65535];valid=true;for(let i=0;i<kept.length;i++){let s=String.fromCharCode(kept[i]);if((' '+s+' ').trim()!==s||(' '+s+' ').trimStart()!==s+' '||(' '+s+' ').trimEnd()!==' '+s)valid=false;}valid;")
	trim_eval(rt, c"let lone=String.fromCharCode(55296,32,56320);(' '+lone+' ').trim()===lone && (' '+lone+' ').trim().length===3 && (all+'x'+all+'y'+all).trim()==='x'+all+'y';")
	trim_eval(rt, c"String.prototype.trim.call(123)==='123' && String.prototype.trim.call(true)==='true' && String.prototype.trim.call(-0)==='0' && String.prototype.trim.call(NaN)==='NaN' && String.prototype.trim.call(123n)==='123' && Object(' a ').trim()==='a';")
	trim_eval(rt, c"let order='';let receiver={toString:function(){order+='s';return ' x ';},valueOf:function(){order+='v';return ' y ';}};let ignored={toString:function(){throw 5;}};String.prototype.trim.call(receiver,ignored)==='x' && order==='s';")
	trim_eval(rt, c"order='';let receiver2={toString:function(){order+='s';return {};},valueOf:function(){order+='v';return ' z ';}};String.prototype.trim.call(receiver2)==='z' && order==='sv';")
	trim_eval(rt, c"let thrown=0;try{String.prototype.trim.call({toString:function(){throw 31;}});}catch(e){thrown=e;}thrown===31;")
	trim_eval(rt, c"let getLog='';let receiver3={};Object.defineProperty(receiver3,'toString',{get:function(){getLog+='s';throw 32;}});thrown=0;try{String.prototype.trimStart.call(receiver3);}catch(e){thrown=e;}thrown===32 && getLog==='s';")
	trim_eval(rt, c"let errors=0;try{String.prototype.trim.call(null);}catch(e){if(e.constructor===TypeError)errors++;}try{String.prototype.trimEnd.call(undefined);}catch(e){if(e.constructor===TypeError)errors++;}try{String.prototype.trim.call(Object.create(null));}catch(e){if(e.constructor===TypeError)errors++;}errors===3;")
	trim_eval(rt, c"let methods=['trim','trimStart','trimEnd'];valid=true;for(let i=0;i<methods.length;i++){let m=String.prototype[methods[i]];let d=Object.getOwnPropertyDescriptor(String.prototype,methods[i]);if(m.name!==methods[i]||m.length!==0||Object.hasOwn(m,'prototype')||!d.writable||d.enumerable||!d.configurable)valid=false;}valid;")
	trim_eval(rt, c"String.prototype.trimLeft===String.prototype.trimStart && String.prototype.trimRight===String.prototype.trimEnd && ' x '.trimLeft()==='x ' && ' x '.trimRight()===' x' && Object.getOwnPropertyDescriptor(String.prototype,'trimLeft').writable && !Object.getOwnPropertyDescriptor(String.prototype,'trimRight').enumerable && Object.getOwnPropertyDescriptor(String.prototype,'trimRight').configurable;")
	trim_eval(rt, c"errors=0;try{new String.prototype.trim();}catch(e){if(e.constructor===TypeError)errors++;}try{new String.prototype.trimStart();}catch(e){if(e.constructor===TypeError)errors++;}try{new String.prototype.trimEnd();}catch(e){if(e.constructor===TypeError)errors++;}errors===3;")
	js_value* method = js_runtime_get(rt, rt.string_prototype, c"trim")
	js_value* input = js_class_string(rt, c" abc ")
	assert1(js_runtime_root(rt, input))
	list[js_value*] arguments = new list[js_value*]
	js_runtime_begin(rt, 7)
	js_runtime_call_receiver(rt, method, input, arguments)
	assert_equal(5, rt.completion.status)
	js_runtime_begin(rt, 8)
	js_value* output = js_runtime_call_receiver(rt, method, input, arguments)
	assert_equal(0, rt.completion.status)
	assert_equal(0, rt.remaining)
	assert_equal(3, output.text.units.length)
	assert1(js_runtime_root(rt, output))
	js_runtime_collect(rt)
	assert_equal('a', output.text.units[0])
	js_runtime_begin(rt, 1000)
	int max_values = rt.max_values
	rt.max_values = rt.heap.length
	js_runtime_call_receiver(rt, method, input, arguments)
	assert_equal(5, rt.completion.status)
	rt.max_values = max_values
	js_runtime_begin(rt, 1000)
	rt.max_properties = 4
	js_runtime_call_receiver(rt, method, input, arguments)
	assert_equal(5, rt.completion.status)
	rt.max_properties = 10000
	js_runtime* foreign = js_runtime_new()
	js_runtime_begin(rt, 1000)
	arguments.push(foreign.undefined_value)
	js_runtime_call_receiver(rt, method, input, arguments)
	assert_equal(2, rt.completion.status)
	js_runtime_begin(rt, 1000)
	arguments.clear()
	js_runtime_call_receiver(rt, method, foreign.undefined_value, arguments)
	assert_equal(2, rt.completion.status)
	js_runtime_free(foreign)
	__w_list_free(cast(__w_list*, arguments))
	js_runtime_free(rt)
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_string_trim_test: OK")
	return 0
