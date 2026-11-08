# wbuild: name=javascript_runtime_regexp_test
# wbuild: target=javascript_runtime_regexp_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 tests/javascript/runtime_regexp_test.w -o bin/javascript_runtime_regexp_test"
# wbuild: step="bin/javascript_runtime_regexp_test" expect_stdout="javascript_runtime_regexp_test: OK"
# wbuild: step="bin/javascript_runtime_regexp_test memory" expect_stdout="javascript_runtime_regexp_test: OK"
# wbuild: step="python3 tools/javascript_regexp_case.py --check"
import lib.assert
import lib.args
import libs.extras.javascript.runtime


# Each script runs in its own block so its lexical bindings do not collide.
void regexp_true(js_runtime* rt, char* body):
	char* opened = strjoin(c"{ ", body)
	char* source = strjoin(opened, c" }")
	free(opened)
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 100000)
	if (result.status != 0 || result.value.kind != 2 || result.value.number != 1.0):
		println2(source)
		println2(result.message)
	assert_equal(0, result.status)
	assert1(result.value.number == 1.0)
	free(source)


int regexp_status(js_runtime* rt, char* source, int budget):
	return js_runtime_eval(rt, source, strlen(source), budget).status


void test_regexp_matching():
	js_runtime* rt = js_runtime_new()
	regexp_true(rt, c"const m = /(\\d+)-(?<w>[a-z]+)/.exec('xx 12-ab yy'); m[0] === '12-ab' && m[1] === '12' && m.index === 3 && m.input === 'xx 12-ab yy' && m.groups.w === 'ab' && m.length === 3;")
	regexp_true(rt, c"/(x)/.exec('x').groups === undefined && /a/.exec('b') === null && /(a)|b/.exec('b')[1] === undefined;")
	regexp_true(rt, c"const z = /(z)((a+)?(b+)?(c))*/.exec('zaacbbbcac'); z[2] === 'ac' && z[3] === 'a' && z[4] === undefined && z[5] === 'c';")
	regexp_true(rt, c"/(a*)*/.exec('b')[1] === undefined && /(a*)b\\1+/.exec('baaaac')[0] === 'b' && /(?:(a)|b)*/.exec('ab')[1] === undefined;")
	regexp_true(rt, c"/a+?/.exec('aaa')[0] === 'a' && /a{2,3}/.exec('aaaa')[0] === 'aaa' && /a{2,}?/.exec('aaaa')[0] === 'aa' && /a{0}b/.exec('ab')[0] === 'b' && /x{1,2}?y/.test('xxy');")
	regexp_true(rt, c"/(?=(a+))a*b\\1/.exec('baaabac')[0] === 'aba' && /(.*?)a(?!(a+)b\\2c)\\2(.*)/.exec('baaabaac')[2] === undefined && /(?=a)*b/.test('b');")
	regexp_true(rt, c"/(?<=\\$)\\d+(\\.\\d*)?/.exec('cost $10.53')[0] === '10.53' && /(?<!\\$)\\d+/.exec('$10 or 20')[0] === '0' && /(?<=\\1(a))b/.exec('aab')[0] === 'b';")
	regexp_true(rt, c"const b = /(?<=(\\d+)(\\d+))$/.exec('1053'); b[1] === '1' && b[2] === '053' && /(?<=a(?:b|c))d/.test('acd') && !/(?<!a)b/.test('ab');")
	regexp_true(rt, c"/\\bfoo\\b/.test('a foo b') && /\\Boo/.exec('foo').index === 1 && /^b/m.test('a\\nb') && !/^b/.test('a\\nb') && /a$/m.test('a\\nb') && !/a$/.test('a\\nb');")
	regexp_true(rt, c"/^a.c$/s.test('a\\nc') && !/^a.c$/.test('a\\nc') && /[^]/.test('\\n') && !/[]/.test('a') && /[\\b]/.test('\\b') && /\\0/.test('\\0');")
	regexp_true(rt, c"/^\\s+$/.test('\\t\\v\\f \\u00a0\\ufeff\\u2028\\u3000') && !/\\S/.test('\\u2029') && /\\W/.test('-') && !/\\W/.test('_') && /[^\\d]/.test('a') && /[\\D]/.test('a');")
	regexp_true(rt, c"/\\8/.test('8') && /\\08/.test('\\x008') && /\\101/.test('A') && /[\\101]/.test('A') && /[\\8]/.test('8') && /\\1(a)/.exec('aa')[0] === 'a' && /\\k<a>(?<a>x)/.test('x');")
	regexp_true(rt, c"/\\c/.test('\\\\c') && /\\cJ/.test('\\n') && /[\\c_]/.test('\\x1f') && /[\\c*]/.test('\\\\') && /\\u{2}/.test('uu') && /\\x4/.test('x4') && /a{1/.test('a{1') && /]/.test(']');")
	regexp_true(rt, c"/[\\d-a]/.test('-') && /[\\d-a]/.test('5') && !/[\\d-a]/.test('b') && /[%-\\d]/.test('%') && /[\\-]/.test('-') && /\\k<b>/.test('k<b>');")
	regexp_true(rt, c"/\\u{1F600}/u.test('\\u{1F600}') && /^.$/u.test('\\u{1F600}') && !/^.$/.test('\\u{1F600}') && /^..$/.test('\\u{1F600}') && /[\\u{1F600}-\\u{1F64F}]/u.test('\\u{1F610}');")
	regexp_true(rt, c"!/\\ud83d/u.test('\\ud83d\\udca9') && /\\ud83d/.test('\\ud83d\\udca9') && /\\uD83D\\uDE00/u.test('\\u{1F600}') && !/[\\uD83D\\uDE00]/u.test('\\uD83D') && /(.+)\\1/u.test('\\u{1F600}\\u{1F600}');")
	regexp_true(rt, c"/(?<=\\u{1F600})x/u.test('\\u{1F600}x') && /(?<=.)x/u.exec('\\u{1F600}x').index === 2 && /(?<=(.))x/u.exec('\\u{1F600}x')[1].length === 2;")
	regexp_true(rt, c"/[a-z]+/i.exec('ABC')[0] === 'ABC' && !/\\u212a/i.test('k') && /\\u212a/iu.test('k') && !/\\u017f/i.test('s') && /\\u017f/iu.test('s') && /[^a]/i.test('A') === false;")
	regexp_true(rt, c"/[\\w]/iu.test('\\u017f') && !/\\w/i.test('\\u017f') && /\\W/iu.test('\\u017f') === false && /\\bs/iu.test('\\u017f') && !/\\u00df/i.test('SS') && /\\u01c5/i.test('\\u01c6') && /\\u01c5/iu.test('\\u01c6');")
	regexp_true(rt, c"/[A-Z]/i.test('a') && !/[A-Z]/i.test('\\u212a') && /[A-Z]/iu.test('\\u212a') && /\\u03a3/i.test('\\u03c2') && /\\u1e9e/iu.test('\\u00df') && !/\\u1e9e/i.test('\\u00df');")
	regexp_true(rt, c"/(a)\\1/i.test('aA') && /(?<n>a)\\k<n>/i.test('aA') && /(a)\\1/iu.test('aA') && !/(a)\\1/.test('aA') && /(?<=\\1(a))b/i.test('Aab');")
	regexp_true(rt, c"/\\p{ASCII}+/u.exec('abc\\u00e9')[0] === 'abc' && /\\P{ASCII}/u.exec('abc\\u00e9')[0] === '\\u00e9' && /\\p{Any}/u.test('\\u{10FFFF}') && /[\\P{Any}]/u.test('a') === false;")
	regexp_true(rt, c"/\\p{ID_Start}\\p{IDC}*/u.exec('1abc2 x')[0] === 'abc2' && /\\p{AHex}+/u.exec('xyzBEEFg')[0] === 'BEEF' && /\\p{IDS}/u.test('\\u{10400}') && !/\\p{ASCII_Hex_Digit}/u.test('g');")
	regexp_true(rt, c"const g = /a/g; g.test('aa') && g.lastIndex === 1 && g.test('aa') && g.lastIndex === 2 && !g.test('aa') && g.lastIndex === 0;")
	regexp_true(rt, c"const y = /a/y; !y.test('ba') && y.lastIndex === 0 && (y.lastIndex = 1, y.test('ba')) && y.lastIndex === 2 && (y.lastIndex = 9, !y.test('ba')) && y.lastIndex === 0;")
	regexp_true(rt, c"const s = /^a/y; s.lastIndex = 1; !s.test('aa') && /a/.exec('ba').index === 1;")
	regexp_true(rt, c"const u = /./gu; u.lastIndex = 1; u.exec('\\u{1F600}a')[0].length === 2 && u.lastIndex === 2; const e = /(?:)/gu; e.lastIndex = 1; e.exec('\\u{1F600}').index === 0;")
	regexp_true(rt, c"const v = /(?:)/g; v.lastIndex = 1; v.exec('\\u{1F600}').index === 1 && /(?:)/gu.exec('').index === 0;")
	regexp_true(rt, c"/(?:)/.source === '(?:)' && /a\\/b/.source === 'a\\\\/b' && /[/]/.source === '[/]' && /a/gimsuy.flags === 'gimsuy' && /x/g.toString() === '/x/g';")
	regexp_true(rt, c"!/a/.global && /a/g.global && /a/i.ignoreCase && /a/m.multiline && /a/s.dotAll && /a/u.unicode && /a/y.sticky && /a/ !== /a/;")
	regexp_true(rt, c"RegExp.prototype.source === '(?:)' && RegExp.prototype.flags === '' && RegExp.prototype.global === undefined && RegExp.prototype.constructor === RegExp;")
	regexp_true(rt, c"new RegExp('a+', 'g').exec('baaa')[0] === 'aaa' && RegExp('b').test('abc') && new RegExp('a/b').source === 'a\\\\/b' && new RegExp('\\n').source === '\\\\n';")
	regexp_true(rt, c"new RegExp('\\r\\u2028\\u2029').source === '\\\\r\\\\u2028\\\\u2029' && new RegExp('\\\\\\n').source === '\\\\n' && new RegExp('[/]').source === '[/]';")
	regexp_true(rt, c"new RegExp(/a/g).flags === 'g' && new RegExp(/a/g, 'i').flags === 'i' && new RegExp().source === '(?:)' && new RegExp(undefined, undefined).flags === '';")
	regexp_true(rt, c"new RegExp('\\ud83d\\ude00', 'u').test('\\u{1F600}') && new RegExp('(?<a>.)\\\\k<a>').test('xx');")
	regexp_true(rt, c"let n = ''; try { new RegExp('(') } catch (e) { n = e.name } n === 'SyntaxError';")
	regexp_true(rt, c"let n = ''; try { new RegExp('a', 'gg') } catch (e) { n = e.name } n === 'SyntaxError';")
	regexp_true(rt, c"let n = ''; try { new RegExp('[z-a]') } catch (e) { n = e.name } n === 'SyntaxError';")
	regexp_true(rt, c"let n = ''; try { RegExp.prototype.exec.call({}, 'a') } catch (e) { n = e.name } n === 'TypeError';")
	regexp_true(rt, c"/a/.test() === false && /undefined/.test() && /1/.test(1) && /null/.test(null);")
	js_runtime_collect(rt)
	regexp_true(rt, c"/(a)\\1/.test('aa');")
	js_runtime_free(rt)


void test_regexp_limits():
	js_runtime* rt = js_runtime_new()
	# Every validated property escape has data (runtime_regexp_property_test.w).
	assert_equal(0, regexp_status(rt, c"/\\p{Lu}/u; /\\p{Script=Greek}/u; new RegExp('\\\\p{Lu}', 'u');", 1000))
	assert_equal(6, regexp_status(rt, c"new RegExp(1);", 1000))
	assert_equal(6, regexp_status(rt, c"new RegExp('a', 1);", 1000))
	assert_equal(6, regexp_status(rt, c"const r = /a/g; r.lastIndex = 'x'; r.test('a');", 1000))
	assert_equal(6, regexp_status(rt, c"/a/.test({});", 1000))
	assert_equal(6, regexp_status(rt, c"new RegExp('(?:ab){0,300000}');", 100000))
	# Catastrophic backtracking stops at the step budget.
	assert_equal(5, regexp_status(rt, c"/(a*)*b/.test('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');", 50000))
	assert_equal(5, regexp_status(rt, c"/(?=(a*)*b)/.test('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');", 50000))
	assert_equal(0, regexp_status(rt, c"/(a*)*b/.test('aab');", 50000))
	js_runtime_free(rt)


int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	test_regexp_matching()
	test_regexp_limits()
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_regexp_test: OK")
	return 0
