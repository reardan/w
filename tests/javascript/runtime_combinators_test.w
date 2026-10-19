# wbuild: name=javascript_runtime_combinators_test
# wbuild: target=javascript_runtime_combinators_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 tests/javascript/runtime_combinators_test.w -o bin/javascript_runtime_combinators_test"
# wbuild: step="bin/javascript_runtime_combinators_test" expect_stdout="javascript_runtime_combinators_test: OK"
# wbuild: step="bin/javascript_runtime_combinators_test memory-all" expect_stdout="javascript_runtime_combinators_test: OK"
# wbuild: step="bin/javascript_runtime_combinators_test memory-race" expect_stdout="javascript_runtime_combinators_test: OK"
# wbuild: step="bin/javascript_runtime_combinators_test memory-settled" expect_stdout="javascript_runtime_combinators_test: OK"
# wbuild: step="bin/javascript_runtime_combinators_test memory-errors" expect_stdout="javascript_runtime_combinators_test: OK"
# wbuild: step="bin/javascript_runtime_combinators_test memory-iteration" expect_stdout="javascript_runtime_combinators_test: OK"
# wbuild: step="bin/javascript_runtime_combinators_test memory-overrides" expect_stdout="javascript_runtime_combinators_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

void combinator_eval(js_runtime* rt, char* source):
	js_runtime_collect(rt)
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 10000)
	if (result.status != 0): println(result.message)
	assert_equal(0, result.status)
	assert1(result.value.number == 1.0)

void test_combinator_all():
	js_runtime* rt = js_runtime_new()
	combinator_eval(rt, c"let first;let second;let values;const a=new Promise(r=>{first=r;});const b=new Promise(r=>{second=r;});Promise.all([a,2,b]).then(x=>{values=x;});true;")
	js_runtime_collect(rt)
	combinator_eval(rt, c"second(3);true;")
	assert_equal(0, js_runtime_drain_microtasks(rt, 10000).status)
	combinator_eval(rt, c"values===undefined;")
	combinator_eval(rt, c"first(1);true;")
	js_runtime_collect(rt)
	assert_equal(0, js_runtime_drain_microtasks(rt, 10000).status)
	combinator_eval(rt, c"values.length===3 && values[0]===1 && values[1]===2 && values[2]===3;")
	js_runtime_free(rt)
	rt = js_runtime_new()
	combinator_eval(rt, c"let values;Promise.all('ab').then(x=>{values=x;});const empty=Promise.all([]);true;")
	js_value* empty = js_runtime_get(rt, rt.global, c"empty")
	assert_equal(2, empty.promise_state)
	assert_equal(0, empty.promise_result.array_length)
	assert_equal(0, js_runtime_drain_microtasks(rt, 10000).status)
	combinator_eval(rt, c"values.length===2 && values[0]==='a' && values[1]==='b';")
	js_runtime_free(rt)

void test_combinator_race():
	js_runtime* rt = js_runtime_new()
	combinator_eval(rt, c"let value=0;let release;const p=new Promise(r=>{release=r;});const empty=Promise.race([]);Promise.race([p,7,8]).then(x=>{value=x;});true;")
	assert_equal(1, js_runtime_get(rt, rt.global, c"empty").promise_state)
	assert_equal(0, js_runtime_drain_microtasks(rt, 10000).status)
	combinator_eval(rt, c"value===7;")
	combinator_eval(rt, c"release(9);true;")
	js_runtime_collect(rt)
	assert_equal(0, js_runtime_drain_microtasks(rt, 10000).status)
	combinator_eval(rt, c"value===7;")
	js_runtime_free(rt)
	rt = js_runtime_new()
	combinator_eval(rt, c"let reason=0;Promise.race([Promise.reject(5),1]).catch(x=>{reason=x;});true;")
	assert_equal(0, js_runtime_drain_microtasks(rt, 10000).status)
	combinator_eval(rt, c"reason===5;")
	js_runtime_free(rt)

void test_combinator_settled():
	js_runtime* rt = js_runtime_new()
	combinator_eval(rt, c"let result;Promise.allSettled([Promise.resolve(1),Promise.reject(2),{then(r){r(3);}}]).then(x=>{result=x;});true;")
	js_runtime_collect(rt)
	assert_equal(0, js_runtime_drain_microtasks(rt, 10000).status)
	combinator_eval(rt, c"result.length===3 && result[0].status==='fulfilled' && result[0].value===1;")
	combinator_eval(rt, c"result[1].status==='rejected' && result[1].reason===2 && result[1].value===undefined;")
	combinator_eval(rt, c"result[2].status==='fulfilled' && result[2].value===3;")
	combinator_eval(rt, c"const empty=Promise.allSettled([]);true;")
	assert_equal(2, js_runtime_get(rt, rt.global, c"empty").promise_state)
	js_runtime_free(rt)

void test_combinator_errors():
	js_runtime* rt = js_runtime_new()
	combinator_eval(rt, c"let reason=0;Promise.all([1,Promise.reject(8)]).catch(e=>{reason=e;});true;")
	assert_equal(0, js_runtime_drain_microtasks(rt, 10000).status)
	combinator_eval(rt, c"reason===8;")
	combinator_eval(rt, c"let bad=false;Promise.all(3).catch(e=>{bad=e.name==='TypeError';});true;")
	assert_equal(0, js_runtime_drain_microtasks(rt, 10000).status)
	combinator_eval(rt, c"bad;")
	js_runtime_free(rt)
	rt = js_runtime_new()
	combinator_eval(rt, c"const values=[1,2,3];true;")
	rt.max_properties = 2
	char* source = c"Promise.all(values);"
	assert_equal(5, js_runtime_eval(rt, source, strlen(source), 1000).status)
	js_runtime_free(rt)
	rt = js_runtime_new()
	rt.max_microtasks = 0
	source = c"Promise.all([1]);"
	assert_equal(5, js_runtime_eval(rt, source, strlen(source), 1000).status)
	js_runtime_free(rt)

void test_combinator_overrides():
	js_runtime* rt = js_runtime_new()
	combinator_eval(rt, c"const odd=Promise.resolve(0);odd.then=(r,j)=>{r(1);r(2);j(9);};let result;Promise.allSettled([odd,3]).then(v=>{result=v;});true;")
	assert_equal(0, js_runtime_drain_microtasks(rt, 10000).status)
	combinator_eval(rt, c"result[0].value===1 && result[1].value===3;")
	combinator_eval(rt, c"let reason=0;Promise.all([odd,new Promise(r=>{})]).catch(e=>{reason=e;});true;")
	assert_equal(0, js_runtime_drain_microtasks(rt, 10000).status)
	combinator_eval(rt, c"reason===9;")
	js_runtime_free(rt)
	rt = js_runtime_new()
	combinator_eval(rt, c"let result;const odd=Promise.resolve(0);odd.then=r=>{r(1);r(2);};Promise.all([odd,3]).then(v=>{result=v;});true;")
	assert_equal(0, js_runtime_drain_microtasks(rt, 10000).status)
	combinator_eval(rt, c"result.length===2 && result[0]===1 && result[1]===3;")
	js_runtime_free(rt)

void test_combinator_iteration():
	js_runtime* rt = js_runtime_new()
	combinator_eval(rt, c"let reason=0;const values=[1,2];const getter=function(){throw 17;};true;")
	js_value* values = js_runtime_get(rt, rt.global, c"values")
	js_value* getter = js_runtime_get(rt, rt.global, c"getter")
	js_text* key = js_runtime_key(c"1")
	assert1(js_runtime_define_accessor(rt, values, key, getter, 0, 1, 1))
	js_text_free(key)
	combinator_eval(rt, c"Promise.all(values).catch(e=>{reason=e;});true;")
	assert_equal(0, js_runtime_drain_microtasks(rt, 10000).status)
	combinator_eval(rt, c"reason===17;")
	js_runtime_free(rt)
	rt = js_runtime_new()
	combinator_eval(rt, c"let values;const original=Promise.resolve;let calls=0;Promise.resolve=x=>{calls++;return original(x+1);};Promise.all([1,2]).then(x=>{values=x;});true;")
	assert_equal(0, js_runtime_drain_microtasks(rt, 10000).status)
	combinator_eval(rt, c"calls===2 && values[0]===2 && values[1]===3;")
	js_runtime_free(rt)
	rt = js_runtime_new()
	combinator_eval(rt, c"let values;const holes=[];holes.length=2;holes[1]=1;Promise.all(holes).then(x=>{values=x;});true;")
	assert_equal(0, js_runtime_drain_microtasks(rt, 10000).status)
	combinator_eval(rt, c"values.length===2 && values[0]===undefined && values[1]===1;")
	js_runtime_free(rt)
	rt = js_runtime_new()
	combinator_eval(rt, c"let intercepted=0;let result;const input=[1,2];const setter=function(){intercepted++;};true;")
	js_value* setter = js_runtime_get(rt, rt.global, c"setter")
	key = js_runtime_key(c"0")
	assert1(js_runtime_define_accessor(rt, rt.array_prototype, key, 0, setter, 1, 1))
	js_text_free(key)
	combinator_eval(rt, c"Promise.all(input).then(x=>{result=x;});true;")
	assert_equal(0, js_runtime_drain_microtasks(rt, 10000).status)
	combinator_eval(rt, c"intercepted===0 && result.length===2 && result[0]===1 && result[1]===2;")
	js_runtime_free(rt)


int main(int argc, int argv):
	args_init(argc, argv)
	assert1(argc == 1 || strcmp(args_get(1), c"memory-all") == 0 || strcmp(args_get(1), c"memory-race") == 0 || strcmp(args_get(1), c"memory-settled") == 0 || strcmp(args_get(1), c"memory-errors") == 0 || strcmp(args_get(1), c"memory-iteration") == 0 || strcmp(args_get(1), c"memory-overrides") == 0)
	if (argc > 1): malloc_force_debug_mode()
	if (argc == 1 || strcmp(args_get(1), c"memory-all") == 0): test_combinator_all()
	if (argc == 1 || strcmp(args_get(1), c"memory-race") == 0): test_combinator_race()
	if (argc == 1 || strcmp(args_get(1), c"memory-settled") == 0): test_combinator_settled()
	if (argc == 1 || strcmp(args_get(1), c"memory-errors") == 0): test_combinator_errors()
	if (argc == 1 || strcmp(args_get(1), c"memory-overrides") == 0): test_combinator_overrides()
	if (argc == 1 || strcmp(args_get(1), c"memory-iteration") == 0): test_combinator_iteration()
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_combinators_test: OK")
	return 0
