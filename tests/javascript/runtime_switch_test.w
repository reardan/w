# wbuild: name=javascript_runtime_switch_test
# wbuild: target=javascript_runtime_switch_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 --strict tests/javascript/runtime_switch_test.w -o bin/javascript_runtime_switch_test"
# wbuild: step="bin/javascript_runtime_switch_test" expect_stdout="javascript_runtime_switch_test: OK"
# wbuild: step="bin/javascript_runtime_switch_test memory" expect_stdout="javascript_runtime_switch_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

void switch_eval(js_runtime* rt, char* source, int status):
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
	switch_eval(rt, c"let order='';switch(2){case (order+='a',1):order+='x';break;default:order+='d';case (order+='b',2):order+='y';case (order+='c',3):order+='z';}order==='abyz';", 0)
	switch_eval(rt, c"let fallback='';switch(9){case (fallback+='a',1):break;default:fallback+='d';case (fallback+='b',2):fallback+='e';}fallback==='abde';", 0)
	switch_eval(rt, c"let strict=0;switch('1'){case 1:strict=9;break;default:strict=1;}strict===1;", 0)
	switch_eval(rt, c"let scope=0;switch(1){case 1:let local=4;case 2:scope=local;}scope===4 && typeof local==='undefined';", 0)
	switch_eval(rt, c"let tdz=0;try{switch(1){case 1:tdz=local;case 2:let local=4;}}catch(e){tdz=e.constructor===ReferenceError;}tdz===true;", 0)
	switch_eval(rt, c"let calls=0;let value={valueOf:function(){calls++;return 1;}};switch(value){case 1:calls+=10;break;case value:calls+=2;}calls===2;", 0)
	switch_eval(rt, c"let loops=0;for(let i=0;i<3;i++){switch(i){case 1:continue;case 2:break;}loops++;}loops===2;", 0)
	switch_eval(rt, c"let labelled=0;outer:while(true){switch(1){case 1:try{break outer;}finally{labelled=1;}}labelled=9;}labelled===1;", 0)
	switch_eval(rt, c"function choose(x){switch(x){case 1:return 7;default:return 9;}}choose(1)===7 && choose(2)===9;", 0)
	switch_eval(rt, c"let abrupt=0;try{switch(1){case (function(){throw 17;})():abrupt=9;}}catch(e){abrupt=e;}abrupt===17;", 0)
	switch_eval(rt, c"switch(0){case 1:var hoisted=3;}typeof hoisted==='undefined';", 0)
	switch_eval(rt, c"let outerValue=1;switch(outerValue){case 1:let outerValue=2;break;}outerValue===1;", 0)
	js_completion* completion = js_runtime_eval(rt, c"switch(1){case 1:7;break;}", 26, 10000)
	assert_equal(0, completion.status)
	assert1(completion.value.number == 7.0)
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	js_node* tree = rt.scripts[rt.scripts.length - 1]
	char* printed = js_print(tree, diagnostics)
	assert1(printed != 0)
	assert_equal(0, diagnostics.items.length)
	completion = js_runtime_eval(rt, printed, strlen(printed), 10000)
	assert_equal(0, completion.status)
	assert1(completion.value.number == 7.0)
	free(printed)
	pg_diagnostics_free(diagnostics)
	js_runtime_free(rt)
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_switch_test: OK")
	return 0
