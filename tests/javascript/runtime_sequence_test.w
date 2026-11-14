# wbuild: name=javascript_runtime_sequence_test
# wbuild: target=javascript_runtime_sequence_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 --strict tests/javascript/runtime_sequence_test.w -o bin/javascript_runtime_sequence_test"
# wbuild: step="bin/javascript_runtime_sequence_test" expect_stdout="javascript_runtime_sequence_test: OK"
# wbuild: step="bin/javascript_runtime_sequence_test memory-order" expect_stdout="javascript_runtime_sequence_test: OK"
# wbuild: step="bin/javascript_runtime_sequence_test memory-async" expect_stdout="javascript_runtime_sequence_test: OK"
# wbuild: step="bin/javascript_runtime_sequence_test memory-limits" expect_stdout="javascript_runtime_sequence_test: OK"
# wbuild: step="bin/javascript_runtime_sequence_test memory-mixed" expect_stdout="javascript_runtime_sequence_test: OK"
# wbuild: step="bin/javascript_runtime_sequence_test memory-conditional" expect_stdout="javascript_runtime_sequence_test: OK"
# wbuild: step="bin/javascript_runtime_sequence_test memory-conditional-depth" expect_stdout="javascript_runtime_sequence_test: OK"
# wbuild: step="bin/javascript_runtime_sequence_test memory-conditional-async" expect_stdout="javascript_runtime_sequence_test: OK"
# wbuild: step="bin/javascript_runtime_sequence_test memory-binary" expect_stdout="javascript_runtime_sequence_test: OK"
# wbuild: step="bin/javascript_runtime_sequence_test memory-binary-async" expect_stdout="javascript_runtime_sequence_test: OK"
# wbuild: step="bin/javascript_runtime_sequence_test memory-interleaved" expect_stdout="javascript_runtime_sequence_test: OK"
# wbuild: step="bin/javascript_runtime_sequence_test memory-coercion" expect_stdout="javascript_runtime_sequence_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

void sequence_eval(js_runtime* rt, char* source, int status):
	js_runtime_collect(rt)
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 20000)
	if (result.status != status || (status == 0 && result.value.number != 1.0)):
		println(source)
		println(result.message)
	assert_equal(status, result.status)
	if (status == 0): assert1(result.value.number == 1.0)

void test_sequence_order():
	js_runtime* rt = js_runtime_new()
	sequence_eval(rt, c"let calls='';function mark(s,v){calls+=s;return v;}true;", 0)
	sequence_eval(rt, c"let result=mark('a',true)&&mark('b',0)&&mark('c',1);result===0 && calls==='ab';", 0)
	sequence_eval(rt, c"calls='';let object={};let choice=mark('a',0)||(mark('b',object)||mark('c',3));choice===object && calls==='ab';", 0)
	sequence_eval(rt, c"calls='';let chosen=mark('a',null)??mark('b',false)??mark('c',3);chosen===false && calls==='ab';", 0)
	sequence_eval(rt, c"calls='';let last=(mark('a',1),(mark('b',2),mark('c',object)));last===object && calls==='abc';", 0)
	sequence_eval(rt, c"calls='';(mark('a',true)&&(mark('b',0)||mark('c',1)))===1 && calls==='abc';", 0)
	sequence_eval(rt, c"calls='';let caught=0;function fail(){throw 7;}try{(mark('a',1),fail(),mark('b',2));}catch(e){caught=e;}caught===7 && calls==='a';", 0)
	sequence_eval(rt, c"let holder={method:function(){'use strict';return this;}};(0,holder.method)()===undefined;", 0)
	js_runtime_free(rt)

void test_sequence_async():
	js_runtime* rt = js_runtime_new()
	sequence_eval(rt, c"let resolve;let p=new Promise(r=>{resolve=r;});let log='';let result=0;true;", 0)
	sequence_eval(rt, c"async function run(){return (log+='a',await p,log+='b',9);}run().then(v=>{result=v;});log==='a';", 0)
	js_runtime_collect(rt)
	sequence_eval(rt, c"resolve();true;", 0)
	assert_equal(0, js_runtime_drain_microtasks(rt, 20000).status)
	sequence_eval(rt, c"result===9 && log==='ab';", 0)
	sequence_eval(rt, c"let reject;let bad=new Promise((r,j)=>{reject=j;});let caught=0;let after=0;true;", 0)
	sequence_eval(rt, c"async function rejected(){return (1,await bad,after++);}rejected().catch(e=>{caught=e;});true;", 0)
	sequence_eval(rt, c"reject(8);true;", 0)
	assert_equal(0, js_runtime_drain_microtasks(rt, 20000).status)
	sequence_eval(rt, c"caught===8 && after===0;", 0)
	sequence_eval(rt, c"let never=new Promise(()=>{});async function pending(){return (1,await never,after++);}pending();true;", 0)
	js_runtime_collect(rt)
	sequence_eval(rt, c"after===0;", 0)
	js_runtime_free(rt)

void test_sequence_limits():
	js_runtime* rt = js_runtime_new()
	rt.max_depth = 8
	string_builder* source = string_new()
	for i in range(20): string_append(source, c"true&&")
	string_append(source, c"true;")
	sequence_eval(rt, source.data, 0)
	string_clear(source)
	for i in range(20): string_append(source, c"false||")
	string_append(source, c"true;")
	sequence_eval(rt, source.data, 0)
	string_clear(source)
	for i in range(20): string_append(source, c"null??")
	string_append(source, c"true;")
	sequence_eval(rt, source.data, 0)
	string_clear(source)
	for i in range(20): string_append(source, c"0,")
	string_append(source, c"true;")
	sequence_eval(rt, source.data, 0)
	rt.max_properties = 4
	sequence_eval(rt, source.data, 5)
	rt.max_properties = 10000
	assert_equal(5, js_runtime_eval(rt, source.data, source.length, 8).status)
	sequence_eval(rt, c"function recurse(){return recurse();}recurse();", 5)
	rt.max_depth = 256
	sequence_eval(rt, c"true&&true&&true;", 0)
	assert_equal(7, rt.completion.steps)
	sequence_eval(rt, c"0,0,true;", 0)
	assert_equal(7, rt.completion.steps)
	string_free(source)
	js_runtime_free(rt)

void test_sequence_mixed():
	js_runtime* rt = js_runtime_new()
	rt.max_depth = 8
	string_builder* source = string_new()
	for i in range(10): string_append(source, c"true&&(false||(")
	string_append(source, c"true")
	for i in range(10): string_append(source, c"))")
	string_append(source, c";")
	sequence_eval(rt, source.data, 0)
	string_free(source)
	js_runtime_free(rt)

void test_sequence_conditional():
	js_runtime* rt = js_runtime_new()
	sequence_eval(rt, c"let calls='';function mark(s,v){calls+=s;return v;}let object={};true;", 0)
	sequence_eval(rt, c"let value=mark('a',true)?mark('b',object):mark('c',0);value===object && calls==='ab';", 0)
	sequence_eval(rt, c"calls='';let other=mark('a',false)?mark('b',0):(mark('c',false)||mark('d',object));other===object && calls==='acd';", 0)
	sequence_eval(rt, c"calls='';let caught=0;function fail(){throw 7;}try{(true?fail():mark('x',1),mark('y',1));}catch(e){caught=e;}caught===7 && calls==='';", 0)
	sequence_eval(rt, c"true?true:false;", 0)
	assert_equal(5, rt.completion.steps)
	sequence_eval(rt, c"false?false:true;", 0)
	assert_equal(5, rt.completion.steps)
	js_runtime_free(rt)

void test_sequence_conditional_depth():
	js_runtime* rt = js_runtime_new()
	rt.max_depth = 8
	string_builder* source = string_new()
	for i in range(20): string_append(source, c"true?(")
	string_append(source, c"true")
	for i in range(20): string_append(source, c"):false")
	string_append(source, c";")
	sequence_eval(rt, source.data, 0)
	string_clear(source)
	for i in range(20): string_append(source, c"false?false:")
	string_append(source, c"true;")
	sequence_eval(rt, source.data, 0)
	string_free(source)
	js_runtime_free(rt)

void test_sequence_conditional_async():
	js_runtime* rt = js_runtime_new()
	sequence_eval(rt, c"let object={};true;", 0)
	sequence_eval(rt, c"let resolve;let p=new Promise(r=>{resolve=r;});let result=0;async function wait(){return (await p)?(false||object):null;}wait().then(v=>{result=v;});true;", 0)
	js_runtime_collect(rt)
	sequence_eval(rt, c"resolve(true);true;", 0)
	assert_equal(0, js_runtime_drain_microtasks(rt, 20000).status)
	sequence_eval(rt, c"result===object;", 0)
	js_runtime_free(rt)

void test_sequence_binary():
	js_runtime* rt = js_runtime_new()
	sequence_eval(rt, c"let calls='';function mark(s,v){calls+=s;return v;}let object={valueOf:function(){calls+='c';return 4;}};true;", 0)
	sequence_eval(rt, c"let sum=mark('l',object)+mark('r',2);sum===6 && calls==='lrc';", 0)
	sequence_eval(rt, c"calls='';let n=(mark('a',2)+mark('b',3))*(mark('c',4)+mark('d',5));n===45 && calls==='abcd';", 0)
	sequence_eval(rt, c"calls='';let caught=0;function fail(){throw 8;}try{mark('l',object)+fail();}catch(e){caught=e;}caught===8 && calls==='l';", 0)
	sequence_eval(rt, c"(2+3*4)===14;", 0)
	assert_equal(11, rt.completion.steps)
	rt.max_depth = 8
	string_builder* source = string_new()
	for i in range(20): string_append(source, c"1+")
	string_append(source, c"0===20;")
	sequence_eval(rt, source.data, 0)
	rt.max_properties = 4
	sequence_eval(rt, source.data, 5)
	string_free(source)
	js_runtime_free(rt)

void test_sequence_binary_async():
	js_runtime* rt = js_runtime_new()
	sequence_eval(rt, c"let resolve;let p=new Promise(r=>{resolve=r;});let result=0;async function wait(){return ({valueOf:function(){return 7;}})+(await p);}wait().then(v=>{result=v;});true;", 0)
	js_runtime_collect(rt)
	sequence_eval(rt, c"resolve(5);true;", 0)
	assert_equal(0, js_runtime_drain_microtasks(rt, 20000).status)
	sequence_eval(rt, c"result===12;", 0)
	sequence_eval(rt, c"let never=new Promise(()=>{});async function canceled(){return ({valueOf:function(){result=99;return 1;}})+await never;}canceled();true;", 0)
	js_runtime_collect(rt)
	sequence_eval(rt, c"result===12;", 0)
	js_runtime_free(rt)

void test_sequence_interleaved():
	js_runtime* rt = js_runtime_new()
	sequence_eval(rt, c"let first,second;let a=new Promise(r=>{first=r;});let b=new Promise(r=>{second=r;});let x=0,y=0;async function sum(p){return ({valueOf:function(){return 3;}})+await p;}sum(a).then(v=>{x=v;});sum(b).then(v=>{y=v;});true;", 0)
	js_runtime_collect(rt)
	sequence_eval(rt, c"first(4);true;", 0)
	assert_equal(0, js_runtime_drain_microtasks(rt, 20000).status)
	sequence_eval(rt, c"x===7 && y===0;", 0)
	sequence_eval(rt, c"second(5);true;", 0)
	assert_equal(0, js_runtime_drain_microtasks(rt, 20000).status)
	sequence_eval(rt, c"x===7 && y===8;", 0)
	js_runtime_free(rt)

void test_sequence_coercion():
	js_runtime* rt = js_runtime_new()
	rt.max_depth = 8
	sequence_eval(rt, c"let log='';let left={valueOf:function(){log+='l';return 3;}};let right={valueOf:function(){log+='r';return 4;}};true;", 0)
	sequence_eval(rt, c"let total=left+right+left+right+left+right+left+right+left+right+left+right+left+right+left+right+left+right+left+right;total===70 && log.length===20 && log.slice(0,4)==='lrlr';", 0)
	# Coercion inside a deep chain charges the budget like the recursive path.
	char* source = c"left+right+left+right+left+right+left+right+left+right+left+right;"
	assert_equal(5, js_runtime_eval(rt, source, strlen(source), 20).status)
	sequence_eval(rt, c"let deep=1+(2+(3+(4+(5+(6+(7+(8+(9+(10+(11+12))))))))));deep===78;", 0)
	sequence_eval(rt, c"let mix='a'+1+'b'+2+'c'+3+'d'+4+'e'+5+'f'+6;mix==='a1b2c3d4e5f6';", 0)
	sequence_eval(rt, c"let cmp=1==1&&2==2&&'3'==3&&null==undefined&&5%3==2&&(1|2|4|8|16)==31&&1<2&&'a' in {a:1}&&[] instanceof Array&&1===1;cmp;", 0)
	js_runtime_free(rt)

int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	if (argc == 1 || strcmp(args_get(1), c"memory-order") == 0): test_sequence_order()
	if (argc == 1 || strcmp(args_get(1), c"memory-async") == 0): test_sequence_async()
	if (argc == 1 || strcmp(args_get(1), c"memory-limits") == 0): test_sequence_limits()
	if (argc == 1 || strcmp(args_get(1), c"memory-mixed") == 0): test_sequence_mixed()
	if (argc == 1 || strcmp(args_get(1), c"memory-conditional") == 0): test_sequence_conditional()
	if (argc == 1 || strcmp(args_get(1), c"memory-conditional-depth") == 0): test_sequence_conditional_depth()
	if (argc == 1 || strcmp(args_get(1), c"memory-conditional-async") == 0): test_sequence_conditional_async()
	if (argc == 1 || strcmp(args_get(1), c"memory-binary") == 0): test_sequence_binary()
	if (argc == 1 || strcmp(args_get(1), c"memory-binary-async") == 0): test_sequence_binary_async()
	if (argc == 1 || strcmp(args_get(1), c"memory-interleaved") == 0): test_sequence_interleaved()
	if (argc == 1 || strcmp(args_get(1), c"memory-coercion") == 0): test_sequence_coercion()
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_sequence_test: OK")
	return 0
