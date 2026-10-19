# wbuild: name=javascript_runtime_regexp_lookahead_test
# wbuild: target=javascript_runtime_regexp_lookahead_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 --strict tests/javascript/runtime_regexp_lookahead_test.w -o bin/javascript_runtime_regexp_lookahead_test"
# wbuild: step="bin/javascript_runtime_regexp_lookahead_test" expect_stdout="javascript_runtime_regexp_lookahead_test: OK"
# wbuild: step="bin/javascript_runtime_regexp_lookahead_test memory" expect_stdout="javascript_runtime_regexp_lookahead_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

void lookahead_eval(js_runtime* rt, char* source, int status):
	js_runtime_collect(rt)
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 100000)
	if (result.status != status || (status == 0 && result.value.number != 1.0)):
		println(source)
		println(result.message)
	assert_equal(status, result.status)
	if (status == 0): assert1(result.value.kind == 2 && result.value.number == 1.0)

void lookahead_semantics():
	js_runtime* rt = js_runtime_new()
	lookahead_eval(rt, c"/(?=a)a/.test('a') && !/(?=a)b/.test('a') && /a(?!b)/.test('ac') && !/a(?!b)/.test('ab');", 0)
	lookahead_eval(rt, c"let m=/(?=(ab))a/.exec('zab');m.index===1 && m[0]==='a' && m[1]==='ab' && m.length===2;", 0)
	lookahead_eval(rt, c"let first=/(?=(a|ab))ab/.exec('ab');let greedy=/(?=(a+))a/.exec('aaa');let lazy=/(?=(a+?))aaa/.exec('aaa');first[1]==='a' && greedy[1]==='aaa' && lazy[1]==='a';", 0)
	lookahead_eval(rt, c"let outer=/(?=(a))ab|a/.exec('ac');outer[0]==='a' && outer[1]===undefined;", 0)
	lookahead_eval(rt, c"let neg=/(?!((a))b)a/.exec('ac');neg[0]==='a' && neg[1]===undefined && neg[2]===undefined;", 0)
	lookahead_eval(rt, c"let nested=/(?=(a(?=(b))))ab/.exec('ab');nested[0]==='ab' && nested[1]==='a' && nested[2]==='b' && /(?!(?=b))a/.test('a') && !/(?!(?=a))a/.test('a');", 0)
	lookahead_eval(rt, c"let reset=/(?:(?=(a))a|b)+/.exec('ab');reset[0]==='ab' && reset[1]===undefined;", 0)
	lookahead_eval(rt, c"/(?=)/.exec('')[0]==='' && /(?!)/.exec('')===null && /(?=$)/.exec('ab').index===2 && /(?=^a)/m.exec('x\\na').index===2;", 0)
	lookahead_eval(rt, c"let optional=/(?=(a))?a/.exec('a');let skipped=/(?=(a))??a/.exec('a');optional[1]===undefined && skipped[1]===undefined && /(?!a)?a/.test('a');", 0)
	lookahead_eval(rt, c"let nullable=/(a?)?/.exec('');let fallback=/((?=a)|a)?/.exec('a');let nestedOptional=/(((?=a)|a)?)?/.exec('a');nullable[1]===undefined && fallback[0]==='a' && fallback[1]==='a' && nestedOptional[0]==='a' && nestedOptional[1]==='a' && nestedOptional[2]==='a';", 0)
	lookahead_eval(rt, c"let units=/(?=(\\ud83d))(?!\\ude00)./.exec('😀');units[0]==='\\ud83d' && units[1]==='\\ud83d' && /(?!\\0)./.exec('\\0x').index===1 && /(?=(\\0))\\0/.exec('x\\0')[1]==='\\0';", 0)
	lookahead_eval(rt, c"let sanitizer=/([\\ud800-\\udbff]+)(?![\\udc00-\\udfff])|(^|[^\\ud800-\\udbff])([\\udc00-\\udfff]+)/g;let high=sanitizer.exec('\\ud800\\ud800\\udc00');let finished=sanitizer.exec('\\ud800\\ud800\\udc00');let low=sanitizer.exec('x\\udc00\\udfff');high[0]==='\\ud800' && high[1]==='\\ud800' && high[2]===undefined && finished===null && low[0]==='x\\udc00\\udfff' && low[1]===undefined && low[2]==='x' && low[3]==='\\udc00\\udfff';", 0)
	lookahead_eval(rt, c"let stateful=/(?=(a))/g;stateful.lastIndex=1;let zero=stateful.exec('ba');zero.index===1 && zero[0]==='' && zero[1]==='a' && stateful.lastIndex===1;", 0)
	lookahead_eval(rt, c"let sticky=/(?!a)b/y;sticky.lastIndex=1;sticky.test('ab') && sticky.lastIndex===2 && !sticky.test('ab') && sticky.lastIndex===0;", 0)
	lookahead_eval(rt, c"'aba'.replace(/(?=(a))/g,'[$1]')==='[a]ab[a]a' && 'foo bar'.replace(/foo(?!bar)/g,'x')==='x bar';", 0)
	lookahead_eval(rt, c"/(?=a)A/i.test('A') && /(?=.)/s.test('\\n') && !/(?=.)/.test('\\n');", 0)
	lookahead_eval(rt, c"new RegExp('(?=a)a').test('a') && new RegExp('(?!a)b').test('b');", 0)
	lookahead_eval(rt, c"let syntax=0;try{new RegExp('(?=a');}catch(e){syntax=e.name==='SyntaxError';}syntax;", 0)
	lookahead_eval(rt, c"/(?<=a)b/.test('ab');", 6)
	lookahead_eval(rt, c"/(?<name>a)/.test('a');", 6)
	lookahead_eval(rt, c"/(?=a)+/.test('a');", 6)
	lookahead_eval(rt, c"/(?=a)*/.test('a');", 6)
	js_runtime_free(rt)

# Native exercises keep guarded allocation usage below the host VMA limit.
# Failed assertions must free partial captures/alternatives, and resource errors
# must never be inverted into success by a negative assertion.
void lookahead_native_limits():
	js_runtime* rt = js_runtime_new()
	js_text* flags = js_text_new()
	js_text* pattern = js_runtime_key(c"(?=(a|ab))(?!((b))c)ab")
	js_text* input = js_runtime_key(c"ab")
	for budget in range(1, 100):
		js_runtime_begin(rt, budget)
		js_regexp* partial = js_re_compile(rt, pattern, flags)
		assert1(rt.completion.status == 0 || rt.completion.status == 5)
		js_regexp_free(partial)
		assert_equal(0, rt.regexp_units)
	js_runtime_begin(rt, 100000)
	js_regexp* re = js_re_compile(rt, pattern, flags)
	assert1(re != 0)
	for budget in range(1, 35):
		js_runtime_begin(rt, budget)
		js_re_state* state = js_re_match_at(re, input, 0)
		if (rt.completion.status == 0):
			assert1(state != 0)
			assert_equal(0, state.captures[0])
			assert_equal(2, state.captures[1])
			assert_equal(1, state.captures[3])
			assert_equal(-1, state.captures[4])
			assert_equal(-1, state.captures[6])
		else:
			assert_equal(5, rt.completion.status)
			assert1(state == 0)
		js_re_state_free(state)
	js_regexp_free(re)
	js_text_free(pattern)
	pattern = js_runtime_key(c"(?!(a|aa)+b)a")
	js_text_free(input)
	input = js_runtime_key(c"aaaaaaaaaaaaaaaaaaaaaaaa")
	js_runtime_begin(rt, 100000)
	re = js_re_compile(rt, pattern, flags)
	js_runtime_begin(rt, 50)
	assert1(js_re_match_at(re, input, 0) == 0)
	assert_equal(5, rt.completion.status)
	js_regexp_free(re)
	js_text_free(pattern)
	js_text_free(input)
	# Maximum assertion nesting succeeds; the next level fails compilation.
	pattern = js_text_new()
	for i in range(32):
		pattern.units.push('(')
		pattern.units.push('?')
		pattern.units.push('=')
	pattern.units.push('a')
	for i in range(32): pattern.units.push(')')
	input = js_runtime_key(c"a")
	js_runtime_begin(rt, 100000)
	re = js_re_compile(rt, pattern, flags)
	assert1(re != 0)
	js_re_state* nested = js_re_match_at(re, input, 0)
	assert1(nested != 0)
	assert_equal(0, nested.position)
	js_re_state_free(nested)
	js_regexp_free(re)
	pattern.units.push(')')
	js_text* extra = js_runtime_key(c"(?=")
	for i in range(pattern.units.length): extra.units.push(pattern.units[i])
	js_runtime_begin(rt, 100000)
	assert1(js_re_compile(rt, extra, flags) == 0)
	assert_equal(5, rt.completion.status)
	js_text_free(extra)
	js_text_free(pattern)
	js_text_free(input)
	pattern = js_runtime_key(c"(?:(?=(a))|a)?")
	input = js_runtime_key(c"a")
	js_runtime_begin(rt, 100000)
	re = js_re_compile(rt, pattern, flags)
	assert1(re != 0 && re.guards == 1)
	for budget in range(1, 45):
		js_runtime_begin(rt, budget)
		js_re_state* optional = js_re_match_at(re, input, 0)
		if (rt.completion.status == 0):
			assert1(optional != 0)
			assert_equal(1, optional.position)
			assert_equal(4, optional.captures.length)
			assert_equal(-1, optional.captures[2])
		else:
			assert_equal(5, rt.completion.status)
			assert1(optional == 0)
		js_re_state_free(optional)
	js_regexp_free(re)
	js_text_free(pattern)
	js_text_free(input)
	js_text_free(flags)
	assert_equal(0, rt.regexp_units)
	js_runtime_free(rt)

void lookahead_shared_stack_limit():
	js_runtime* rt = js_runtime_new()
	js_text* pattern = js_runtime_key(c"(?:(?=a)(a|a))+")
	js_text* flags = js_text_new()
	js_text* input = js_text_new()
	for i in range(5000): input.units.push('a')
	js_runtime_begin(rt, 100000)
	js_regexp* re = js_re_compile(rt, pattern, flags)
	assert1(re != 0)
	js_runtime_begin(rt, 1000000)
	js_re_state* initial = js_re_state_new(re.entry, 0, 0, (re.captures + 1) * 2)
	initial.captures[0] = 0
	int states = 1
	assert1(js_re_match_program(re, input, initial, 0, &states) == 0)
	assert_equal(5, rt.completion.status)
	assert_equal(0, states)
	js_regexp_free(re)
	js_text_free(pattern)
	js_text_free(flags)
	js_text_free(input)
	assert_equal(0, rt.regexp_units)
	js_runtime_free(rt)

int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	if (argc == 1): lookahead_semantics()
	lookahead_native_limits()
	lookahead_shared_stack_limit()
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_regexp_lookahead_test: OK")
	return 0
