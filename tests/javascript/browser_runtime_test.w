# wbuild: name=javascript_browser_runtime_test
# wbuild: target=javascript_browser_runtime_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 tests/javascript/browser_runtime_test.w -o bin/javascript_browser_runtime_test"
# wbuild: step="bin/javascript_browser_runtime_test" expect_stdout="javascript_browser_runtime_test: OK"
# wbuild: step="bin/javascript_browser_runtime_test memory" expect_stdout="javascript_browser_runtime_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime


js_completion* browser_eval(js_runtime* rt, char* source):
	return js_runtime_eval(rt, source, strlen(source), 10000)


void browser_number(js_runtime* rt, char* source, float64 expected):
	js_completion* result = browser_eval(rt, source)
	assert_equal(0, result.status)
	assert_equal(3, result.value.kind)
	assert1(result.value.number == expected)


void browser_text(js_runtime* rt, char* source, char* expected):
	js_completion* result = browser_eval(rt, source)
	assert_equal(0, result.status)
	assert_equal(4, result.value.kind)
	js_text* text = js_runtime_key(expected)
	assert1(js_text_equal(text, result.value.text))
	js_text_free(text)


void browser_callbacks():
	js_runtime* rt = js_runtime_new()
	js_runtime* other = js_runtime_new()
	js_value* callback = browser_eval(rt, c"let events = 0; (event) => { events += event.delta; return events; };").value
	assert1(js_runtime_root(rt, callback))
	browser_number(rt, c"1;", 1.0)
	js_runtime_collect(rt)
	list[js_value*] arguments = new list[js_value*]
	js_value* event = js_runtime_alloc(rt, 5)
	js_runtime_set(rt, event, c"delta", js_runtime_number(rt, 21.0))
	arguments.push(event)
	js_completion* result = js_runtime_invoke(rt, callback, arguments, 100)
	assert_equal(0, result.status)
	assert1(result.value.number == 21.0)
	result = js_runtime_invoke(rt, callback, arguments, 100)
	assert_equal(0, result.status)
	assert1(result.value.number == 42.0)
	assert_equal(5, js_runtime_invoke(rt, callback, arguments, 1).status)
	assert_equal(2, js_runtime_invoke(other, callback, arguments, 100).status)
	arguments[0] = other.undefined_value
	assert_equal(2, js_runtime_invoke(rt, callback, arguments, 100).status)
	arguments.pop()
	assert_equal(2, js_runtime_invoke(rt, rt.undefined_value, arguments, 100).status)
	assert_equal(5, js_runtime_invoke(rt, callback, arguments, 0).status)
	callback = browser_eval(rt, c"() => { throw 7; };").value
	assert_equal(2, js_runtime_invoke(rt, callback, arguments, 100).status)
	assert1(rt.completion.value.number == 7.0)
	__w_list_free(cast(__w_list*, arguments))
	js_runtime_free(other)
	js_runtime_free(rt)


void browser_semantics():
	js_runtime* rt = js_runtime_new()
	browser_number(rt, c"const add = x => y => x + y; add(20)(22);", 42.0)
	browser_number(rt, c"const pair = (x, y) => ({sum: x + y}); pair(20, 22).sum;", 42.0)
	browser_number(rt, c"const block = () => { return 42; }; block();", 42.0)
	browser_number(rt, c"let sum = 0; for (const x of [1, 2, 3, 4]) { if (x === 2) continue; if (x === 4) break; sum += x; } sum;", 4.0)
	browser_number(rt, c"const closures = []; let i = 0; for (let x of [2, 4, 6]) { closures[i++] = () => x; x++; } closures[0]() + closures[1]() + closures[2]();", 15.0)
	browser_number(rt, c"const live = [1]; let count = 0; for (const n of live) { count++; if (n === 1) live[1] = 2; } count;", 2.0)
	browser_number(rt, c"let points = 0; let units = 0; for (const ch of 'a\\ud83d\\ude00\\ud800') { points++; units += ch.length; } points * 10 + units;", 34.0)
	browser_number(rt, c"function first() { for (const x of [42]) return x; } first();", 42.0)
	browser_number(rt, c"let finalized = 0; for (const x of [1, 2]) { try { continue; } finally { finalized += x; } } finalized;", 3.0)
	assert_equal(2, browser_eval(rt, c"for (const x of [1]) x = 2;").status)
	assert_equal(2, browser_eval(rt, c"let shadowed = [1]; for (let shadowed of shadowed) {}").status)
	assert_equal(6, browser_eval(rt, c"for (const x of {}) {}").status)
	assert_equal(6, browser_eval(rt, c"for (const x in {}) {}").status)
	assert_equal(6, browser_eval(rt, c"async x => x;").status)
	assert_equal(6, browser_eval(rt, c"(x = 1) => x;").status)
	assert_equal(6, browser_eval(rt, c"() => this;").status)
	assert_equal(6, browser_eval(rt, c"function implicit() { return (() => arguments)(); } implicit(1);").status)
	assert_equal(6, browser_eval(rt, c"let arguments = 42; function hidden() { return arguments; } hidden();").status)
	browser_number(rt, c"function explicit(arguments) { return (() => arguments)(); } explicit(42);", 42.0)
	browser_text(rt, c"typeof missing;", c"undefined")
	browser_text(rt, c"typeof (() => 1);", c"function")
	browser_text(rt, c"typeof null;", c"object")
	assert_equal(2, browser_eval(rt, c"{ typeof tdz; let tdz; }").status)
	browser_text(rt, c"`answer: ${add(20)(22)}, ${true}, ${null}, ${undefined}`;", c"answer: 42, true, null, undefined")
	browser_text(rt, c"`quoted \" and \\` and \\${literal}\\n${`nested ${false}`}`;", c"quoted \" and ` and ${literal}\nnested false")
	browser_text(rt, c"`a\r\nb\rc`;", c"a\nb\nc")
	browser_text(rt, c"`a\\\r\nb`;", c"ab")
	browser_text(rt, c"`${-0},${NaN},${Infinity},${-Infinity},${1e20},${1e21},${1e-6},${1e-7}`;", c"0,NaN,Infinity,-Infinity,100000000000000000000,1e+21,0.000001,1e-7")
	browser_text(rt, c"`${1.2345},${0.00000123},${1.2345e22},${-100.5},${5e-324}`;", c"1.2345,0.00000123,1.2345e+22,-100.5,5e-324")
	browser_number(rt, c"`\\0\\ud800${'\\udfff'}`.length;", 3.0)
	browser_number(rt, c"let order = 0; `${order++}${order++}`; order;", 2.0)
	assert_equal(6, browser_eval(rt, c"`${{}}`;").status)
	browser_number(rt, c"let effects = 0; try { `${(() => { throw 7; })()}${effects++}`; } catch (e) {} effects;", 0.0)
	assert_equal(6, browser_eval(rt, c"effects = 99; async x => x;").status)
	browser_number(rt, c"effects;", 0.0)
	char* loop = c"const growing = [1]; for (const x of growing) growing[growing.length] = 1;"
	assert_equal(5, js_runtime_eval(rt, loop, strlen(loop), 100).status)
	rt.max_properties = 3
	assert_equal(5, browser_eval(rt, c"`ab${'cd'}`;").status)
	js_runtime_free(rt)


int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1):
		malloc_force_debug_mode()
		js_runtime* rt = js_runtime_new()
		browser_text(rt, c"let out = ''; for (const x of [2, 3]) { const f = n => `item ${n}`; out = f(x); } out;", c"item 3")
		js_runtime_free(rt)
		browser_callbacks()
		assert_equal(0, debug_alloc_report_leaks())
	else:
		browser_semantics()
		browser_callbacks()
	println(c"javascript_browser_runtime_test: OK")
	return 0
