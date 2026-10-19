# wbuild: name=javascript_runtime_regexp_test
# wbuild: target=javascript_runtime_regexp_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 --strict tests/javascript/runtime_regexp_test.w -o bin/javascript_runtime_regexp_test"
# wbuild: step="bin/javascript_runtime_regexp_test" expect_stdout="javascript_runtime_regexp_test: OK"
# wbuild: step="bin/javascript_runtime_regexp_test memory" expect_stdout="javascript_runtime_regexp_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

void regexp_test_eval(js_runtime* rt, char* source, int status):
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 100000)
	if (result.status != status):
		println(source)
		println(result.message)
	assert_equal(status, result.status)
	if (status == 0):
		if (result.value.kind != 2 || result.value.number != 1.0): println(source)
		assert_equal(2, result.value.kind)
		assert1(result.value.number == 1.0)

void regexp_test_source(char* source):
	js_runtime* rt = js_runtime_new()
	regexp_test_eval(rt, source, 0)
	js_runtime_free(rt)

void regexp_test_semantics():
	regexp_test_source(c"'line\\n'.replace(/\\n$/, '') === 'line' && 'line\\nrest'.replace(/\\n$/, '') === 'line\\nrest';")
	regexp_test_source(c"let y=/acit|ex(?:s|g|n|p|$)|rph|grid|ows|mnc|ntw|ine[ch]|zoo|^ord|itera/i; y.test('opacity') && y.test('flexGrow') && y.test('order') && !y.test('width');")
	regexp_test_source(c"let f=/(PointerCapture)$|Capture$/i; 'onGotPointerCapture'.replace(f,'$1')==='onGotPointerCapture' && 'onClickCapture'.replace(f,'$1')==='onClick' && 'xlinkHref'.replace(/xlink(H|:h)/,'h')==='href';")
	regexp_test_source(c"let r=/(a|ab)c/; let m=r.exec('zabc!'); m[0]==='abc' && m[1]==='ab' && m.index===1 && m.input==='zabc!' && m.groups===undefined && m.length===2 && r.exec('xyz')===null;")
	regexp_test_source(c"let r=/(a|(b))+/; let m=r.exec('ba'); m[0]==='ba' && m[1]==='a' && m[2]===undefined;")
	regexp_test_source(c"/a*/.exec('aaa')[0]==='aaa' && /a*?/.exec('aaa')[0]==='' && /a+?/.exec('aaa')[0]==='a' && /a??/.exec('aaa')[0]==='' && /a?/.exec('aaa')[0]==='a';")
	regexp_test_source(c"/(?:ab|a)+b/.exec('aab')[0]==='aab' && /a.*b/.exec('axbyb')[0]==='axbyb' && /a.*?b/.exec('axbyb')[0]==='axb';")
	regexp_test_source(c"/^[a-z]+$/i.test('AbZ') && !/^[^a-z]+$/i.test('AbZ') && /^[^a-z]+$/i.test('19!') && /[a-cx-z]+/.exec('0byz!')[0]==='byz';")
	regexp_test_source(c"/^[\\d\\w]+$/.test('Az_19') && /^\\D\\W\\S$/.test('a!x') && /^\\s+$/.test(' \\t\\r\\n\\u00a0\\u2028\\ufeff') && !/\\s/.test('x');")
	regexp_test_source(c"/\\x41\\u0042\\0/.test('AB\\0') && /\\0/.exec('x\\0y').index===1 && 'x\\0y'.replace(/\\0/, '!')==='x!y';")
	regexp_test_source(c"/./.exec('😀')[0]==='\\ud83d' && /\\ud83d/.test('😀') && /\\ude00/.exec('😀').index===1 && '😀'.replace(/./g, '_')==='__';")
	regexp_test_source(c"!/^x$/.test('x\\n') && /^x$/m.test('a\\nx\\nb') && /.$/s.test('\\n') && !/./.test('\\u2028');")
	regexp_test_source(c"let r=/a/g; r.lastIndex=1; r.test('ba') && r.lastIndex===2 && !r.test('ba') && r.lastIndex===0 && r.test('a') && r.lastIndex===1;")
	regexp_test_source(c"let r=/a/y; r.lastIndex=1; !r.test('bba') && r.lastIndex===0; r.lastIndex=2; r.test('bba') && r.lastIndex===3;")
	regexp_test_source(c"let r=/a/; r.lastIndex=99; r.test('a') && r.lastIndex===99 && !r.test('b') && r.lastIndex===99;")
	regexp_test_source(c"let r=/a/g; r.lastIndex=NaN; let a=r.test('a'); r.lastIndex=-1; let b=r.test('a'); r.lastIndex=Infinity; a && b && !r.test('a') && r.lastIndex===0;")
	regexp_test_source(c"let r=/a/g; r.lastIndex=1.9; r.test('ba') && r.lastIndex===2;")
	regexp_test_source(c"let r=/(?:)/g; r.lastIndex=1; let m=r.exec('ab'); m[0]==='' && m.index===1 && r.lastIndex===1;")
	regexp_test_source(c"let r=/(?:)/g; 'ab'.replace(r,'-')==='-a-b-' && r.lastIndex===0 && ''.replace(r,'-')==='-' && '😀'.replace(r,'-')==='-\\ud83d-\\ude00-';")
	regexp_test_source(c"let r=/a*/g; 'ab'.replace(r,'_')==='__b_' && r.lastIndex===0;")
	regexp_test_source(c"'xabz'.replace(/(a)(b)/,'$$:$&:$1:$2:$12:$03:$0:$99')==='x$:ab:a:b:a2:$03:$0:$99z';")
	regexp_test_source(c"'abc'.replace(/b/, \"$`-$&-$'\")==='aa-b-cc' && 'a'.replace(/(z)?a/,'[$1]')==='[]';")
	regexp_test_source(c"'aaa'.replace('a','b')==='baa' && 'ab'.replace('', '_')==='_ab' && 'ab'.replace('b', '$&$1')==='ab$1' && 'undefined!'.replace(undefined,7)==='7!';")
	regexp_test_source(c"let r=/b/y; r.lastIndex=1; 'abc'.replace(r,'x')==='axc' && r.lastIndex===2;")
	regexp_test_source(c"let r=new RegExp('a/b\\n','ymig'); r.source==='a\\\\/b\\\\n' && r.flags==='gimy' && r.global && r.ignoreCase && r.multiline && !r.dotAll && r.sticky && r instanceof RegExp;")
	regexp_test_source(c"new RegExp().source==='(?:)' && new RegExp('\\0').test('\\0') && RegExp('a','g').test('a');")
	regexp_test_source(c"function f(){return /a/g;} let a=f(); let b=f(); a!==b && a.test('a') && b.lastIndex===0;")
	regexp_test_source(c"let r=/x/; r.source='y'; r.flags='g'; r.source==='x' && r.flags==='';")
	regexp_test_source(c"let caught=false; try{RegExp.prototype.test('x');}catch(e){caught=true;} caught;")
	regexp_test_source(c"RegExp.prototype.source==='(?:)' && RegExp.prototype.flags==='' && RegExp.prototype.global===undefined;")
	regexp_test_source(c"let caught=false;try{new RegExp('[z-a]');}catch(e){caught=e.name==='SyntaxError';}caught;")

void regexp_test_native_limits():
	js_runtime* rt = js_runtime_new()
	js_text* pattern = js_runtime_key(c"(ab|a)+?c")
	js_text* flags = js_text_new()
	for budget in range(1, 60):
		js_runtime_begin(rt, budget)
		js_regexp* re = js_re_compile(rt, pattern, flags)
		assert1(rt.completion.status == 0 || rt.completion.status == 5)
		js_regexp_free(re)
		assert_equal(0, rt.regexp_units)
	js_text_free(pattern)
	pattern = js_text_new()
	pattern.units.push('[')
	for i in range(1021): pattern.units.push('a')
	pattern.units.push(']')
	list[js_regexp*] programs = new list[js_regexp*]
	js_runtime_begin(rt, 100000)
	for i in range(64):
		js_regexp* re = js_re_compile(rt, pattern, flags)
		assert1(re != 0)
		programs.push(re)
	assert_equal(65536, rt.regexp_units)
	assert1(js_re_compile(rt, pattern, flags) == 0)
	assert_equal(5, rt.completion.status)
	for i in range(programs.length): js_regexp_free(programs[i])
	__w_list_free(cast(__w_list*, programs))
	assert_equal(0, rt.regexp_units)
	js_runtime_begin(rt, 100000)
	pattern.units.push('a')
	pattern.units.push('a')
	assert1(js_re_compile(rt, pattern, flags) == 0)
	assert_equal(5, rt.completion.status)
	js_text_free(pattern)
	js_text_free(flags)
	js_runtime_free(rt)

void regexp_test_descriptors():
	js_runtime* rt = js_runtime_new()
	regexp_test_eval(rt, c"let r=/x/g; r.test('x');", 0)
	js_value* value = js_runtime_get(rt, rt.global, c"r")
	js_text* key = js_runtime_key(c"lastIndex")
	js_value* property = js_runtime_property(value, key)
	assert1(property != 0 && property.writable && property.enumerable == 0 && property.configurable == 0)
	property.writable = 0
	regexp_test_eval(rt, c"let caught=false; try{r.test('x');}catch(e){caught=true;} caught;", 0)
	js_text_free(key)
	key = js_runtime_key(c"source")
	property = js_runtime_property(rt.regexp_prototype, key)
	assert1(property != 0 && property.accessor && property.getter != 0 && property.setter == 0 && property.enumerable == 0 && property.configurable)
	js_text_free(key)
	js_runtime_free(rt)

void regexp_test_rejections():
	js_runtime* rt = js_runtime_new()
	regexp_test_eval(rt, c"/a{2}/.test('aa');", 6)
	regexp_test_eval(rt, c"/(a)\\1/.test('aa');", 6)
	regexp_test_eval(rt, c"/(?=a)a/.test('a');", 6)
	regexp_test_eval(rt, c"/(?<x>a)/.test('a');", 6)
	regexp_test_eval(rt, c"/a/u.test('a');", 6)
	regexp_test_eval(rt, c"/\\bword/.test('word');", 6)
	regexp_test_eval(rt, c"/(?:a?)*/.test('a');", 6)
	regexp_test_eval(rt, c"/é/i.test('É');", 6)
	regexp_test_eval(rt, c"/\\u00e9/i.test('e');", 6)
	regexp_test_eval(rt, c"/[a-\\u00ff]/i.test('e');", 6)
	regexp_test_eval(rt, c"/a/i.test('é');", 6)
	regexp_test_eval(rt, c"'a'.replace(/a/, function(){return 'b';})==='b';", 0)
	regexp_test_eval(rt, c"new RegExp(/a/);", 6)
	regexp_test_eval(rt, c"let r=/a/g;r.lastIndex='1';r.test('ba');", 6)
	regexp_test_eval(rt, c"let custom=/a/;custom.exec=function(){return null;};custom.test('a');", 6)
	regexp_test_eval(rt, c"'a'.replace(custom, 'b');", 6)
	regexp_test_eval(rt, c"new RegExp('a','gg');", 2)
	regexp_test_eval(rt, c"new RegExp('(');", 2)
	regexp_test_eval(rt, c"new RegExp('[z-a]');", 2)
	regexp_test_eval(rt, c"new RegExp('*');", 2)
	js_runtime_free(rt)

void regexp_test_limits():
	js_runtime* rt = js_runtime_new()
	char* source = c"/(a|aa)+b/.test('aaaaaaaaaaaaaaaaaaaaaaaa');"
	assert_equal(5, js_runtime_eval(rt, source, strlen(source), 300).status)
	regexp_test_eval(rt, c"/a/.test('a');", 0)
	rt.max_properties = 8
	regexp_test_eval(rt, c"'abcd'.replace(/./g,'abcd');", 5)
	js_runtime_free(rt)
	for extra in range(8):
		rt = js_runtime_new()
		rt.max_values = rt.heap.length + extra
		source = c"/a/.exec('a');"
		int status = js_runtime_eval(rt, source, strlen(source), 10000).status
		assert1(status == 0 || status == 5)
		assert1(rt.heap.length <= rt.max_values)
		js_runtime_free(rt)

void regexp_test_lifetime():
	js_runtime* rt = js_runtime_new()
	for i in range(3):
		regexp_test_eval(rt, c"'onClickCapture'.replace(/(PointerCapture)$|Capture$/i,'$1')==='onClick';", 0)
		js_runtime_collect(rt)
		assert_equal(0, rt.regexp_units)
	regexp_test_eval(rt, c"let retained=/a/g; retained.test('a');", 0)
	js_runtime_collect(rt)
	assert_equal(2, rt.regexp_units)
	regexp_test_eval(rt, c"retained.lastIndex===1 && !retained.test('a') && retained.lastIndex===0;", 0)
	js_runtime_free(rt)

int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	if (argc == 1):
		regexp_test_semantics()
		regexp_test_descriptors()
		regexp_test_rejections()
		regexp_test_limits()
	regexp_test_native_limits()
	regexp_test_lifetime()
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_regexp_test: OK")
	return 0
