# wbuild: name=javascript_runtime_string_regexp_test
# wbuild: target=javascript_runtime_string_regexp_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 tests/javascript/runtime_string_regexp_test.w -o bin/javascript_runtime_string_regexp_test"
# wbuild: step="bin/javascript_runtime_string_regexp_test" expect_stdout="javascript_runtime_string_regexp_test: OK"
# wbuild: step="bin/javascript_runtime_string_regexp_test memory" expect_stdout="javascript_runtime_string_regexp_test: OK"
# String.prototype RegExp methods, RegExp Symbol methods, symbols, conversions
# and the iterator protocol (reardan/w#902).
import lib.assert
import lib.args
import libs.extras.javascript.runtime


# Each script runs in its own block so its lexical bindings do not collide.
void sr_true(js_runtime* rt, char* body):
	char* opened = strjoin(c"{ ", body)
	char* source = strjoin(opened, c" }")
	free(opened)
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 200000)
	if (result.status != 0 || result.value.kind != 2 || result.value.number != 1.0):
		println2(source)
		println2(result.message)
	assert_equal(0, result.status)
	assert1(result.value.kind == 2 && result.value.number == 1.0)
	free(source)


int sr_status(js_runtime* rt, char* source, int budget):
	return js_runtime_eval(rt, source, strlen(source), budget).status


void test_string_methods():
	js_runtime* rt = js_runtime_new()
	sr_true(rt, c"const m = 'a1b22'.match(/\\d+/g); m.length === 2 && m[0] === '1' && m[1] === '22' && 'xyz'.match(/q/) === null && 'ab'.match()[0] === '' && 'a.c'.match('.').index === 0;")
	sr_true(rt, c"const m = 'x12'.match(/(?<n>\\d)(\\d)/); m.index === 1 && m.groups.n === '1' && m[2] === '2' && m.input === 'x12';")
	sr_true(rt, c"'2020-12'.replace(/(?<y>\\d+)-(?<m>\\d+)/, '$<m>/$<y>') === '12/2020' && 'abc'.replace(/b/, '[$&|$`|$\\'|$$]') === 'a[b|a|c|$]c';")
	sr_true(rt, c"'abc'.replace(/(b)/, '$01$10$2$0$<x>') === 'abb0$2$0$<x>c' && 'ab'.replace(/(?<x>b)/, '[$<x>$<y>$<x]') === 'a[b$<x]';")
	sr_true(rt, c"'aaa'.replace(/a/g, (m, p) => `${p}`) === '012' && 'x-y'.replace(/-(.)/, (m, c, p, s) => `${c}${p}${s}`) === 'xy1x-y';")
	sr_true(rt, c"'aaa'.replace('a', '$&$&') === 'aaaa' && 'abc'.replace('', '_') === '_abc' && 'a.b.c'.replace('.', () => '!') === 'a!b.c' && 'abc'.replace('z', 'q') === 'abc';")
	sr_true(rt, c"'xy'.replace(/(?<n>y)/, (...a) => typeof a[a.length - 1]) === 'xobject' && 'aa'.replace(/(?:)/g, '-') === '-a-a-';")
	sr_true(rt, c"'hello'.search(/l/) === 2 && 'abc'.search(/z/) === -1 && 'a.b'.search('.') === 0 && 'aBc'.search(/b/i) === 1;")
	sr_true(rt, c"const r = /b/g; r.lastIndex = 2; 'abc'.search(r) === 1 && r.lastIndex === 2;")
	sr_true(rt, c"const a = 'a,b,,c'.split(','); a.length === 4 && a[2] === '' && 'a,b,c'.split(',', 2).length === 2 && 'abc'.split('').length === 3 && 'abc'.split().length === 1;")
	sr_true(rt, c"const a = 'a1b2c3'.split(/(\\d)/); a.length === 7 && a[1] === '1' && a[6] === '' && ''.split(',').length === 1 && ''.split('').length === 0 && 'ab'.split('', 0).length === 0;")
	sr_true(rt, c"'test'.split(/(?:)/).length === 4 && '\\u{1F600}x'.split(/(?:)/u).length === 2 && '\\u{1F600}x'.split(/(?:)/).length === 3 && 'aXbX'.split(/X/y).length === 3;")
	sr_true(rt, c"let s = ''; for (const m of 'a1b22'.matchAll(/(?<n>\\d+)/g)) s = `${s}${m[0]}@${m.index}:${m.groups.n};`; s === '1@1:1;22@3:22;';")
	sr_true(rt, c"const it = 'xx'.matchAll(/x/g); it[Symbol.iterator]() === it && it.next().value.index === 0 && it.next().value.index === 1 && it.next().done && it.next().done;")
	sr_true(rt, c"[...'aXbX'.matchAll('X')].length === 2 && [...'ab'.matchAll(/./)].length === 1 && [...'\\u{1F600}'.matchAll(/(?:)/gu)].length === 2;")
	sr_true(rt, c"const r = /a/g; r.lastIndex = 1; const it = 'aaa'.matchAll(r); it.next().value.index === 1 && r.lastIndex === 1;")
	js_runtime_free(rt)


void test_regexp_symbols():
	js_runtime* rt = js_runtime_new()
	sr_true(rt, c"typeof Symbol.match === 'symbol' && Symbol.match !== Symbol.replace && String(Symbol.split) === 'Symbol(Symbol.split)' && Symbol.iterator.description === 'Symbol.iterator';")
	sr_true(rt, c"const s = Symbol('k'); const o = {[s]: 1, k: 2}; o[s] === 1 && o.k === 2 && Symbol('k') !== s && Symbol().description === undefined && s.toString() === 'Symbol(k)';")
	sr_true(rt, c"let e = 0; try { `${Symbol()}`; } catch (x) { e = x.constructor === TypeError; } let f = 0; try { new Symbol(); } catch (x) { f = x.constructor === TypeError; } e && f;")
	sr_true(rt, c"const calls = []; const re = {[Symbol.match](s) { calls.push(s); return 1; }, [Symbol.replace](s, v) { return `${s}${v}`; }, [Symbol.search]() { return 3; }, [Symbol.split](s, l) { return l; }}; 'q'.match(re) === 1 && 'q'.replace(re, 'v') === 'qv' && 'q'.search(re) === 3 && 'q'.split(re, 9) === 9 && calls[0] === 'q';")
	sr_true(rt, c"let n = 0; const re = /./g; re.exec = function () { n++; return n > 2 ? null : {0: 'z', length: 1, index: n - 1}; }; 'abc'.replace(re, '_') === '__c' && n === 3;")
	sr_true(rt, c"const re = /a/; re.exec = () => 5; let e = 0; try { re.test('a'); } catch (x) { e = x.constructor === TypeError; } e;")
	sr_true(rt, c"RegExp.prototype[Symbol.split].call(/b/, 'abc').length === 2 && /x/[Symbol.replace]('axb', '[$&]') === 'a[x]b' && /x/g[Symbol.match]('xax').length === 2 && /b/[Symbol.search]('abc') === 1;")
	sr_true(rt, c"RegExp[Symbol.species] === RegExp && RegExp('a') instanceof RegExp && RegExp.prototype.flags === '';")
	sr_true(rt, c"const r = /a/g; RegExp(r) === r && new RegExp(r) !== r && RegExp(r, 'i') !== r;")
	sr_true(rt, c"let used = 0; class_free: { const re = /b/; re.constructor = {[Symbol.species]: function (p, f) { used = f; return /b/y; }}; 'abc'.split(re); } used === 'y';")
	sr_true(rt, c"const f = {get global() { return true; }, get ignoreCase() { return false; }, get multiline() { return 1; }, dotAll: 0, unicode: 'u', sticky: null}; Object.getOwnPropertyDescriptor(RegExp.prototype, 'flags').get.call(f) === 'gmu';")
	sr_true(rt, c"RegExp.prototype.toString.call({source: 'a', flags: 'g'}) === '/a/g' && RegExp.prototype.test.call({exec() { return {}; }}, 'x');")
	sr_true(rt, c"const r = /a/y; r.lastIndex = 1; 'baa'.replace(r, 'X') === 'bXa' && r.lastIndex === 2 && 'aaba'.replace(/a/gy, 'X') === 'XXba';")
	sr_true(rt, c"const r = /a/g; Object.defineProperty(r, 'lastIndex', {writable: false}); let e = 0; try { 'aa'.replace(r, 'b'); } catch (x) { e = x.constructor === TypeError; } e;")
	sr_true(rt, c"const g = /a/g; g.lastIndex = 5; 'aaa'.match(g).length === 3 && g.lastIndex === 0;")
	js_runtime_free(rt)


void test_conversions():
	js_runtime* rt = js_runtime_new()
	sr_true(rt, c"const order = []; const p = {toString() { order.push('p'); return 'b'; }}; const f = {toString() { order.push('f'); return 'g'; }}; const r = new RegExp(p, f); r.source === 'b' && r.flags === 'g' && `${order}` === 'p,f';")
	sr_true(rt, c"const o = {valueOf() { return 'v'; }, toString() { return 't'; }}; 'atb'.replace(o, '_') === 'a_b' && 'aaa'.split({toString() { return 'a'; }}).length === 4;")
	sr_true(rt, c"const o = {[Symbol.toPrimitive](h) { return h; }}; 'string'.search(o) === 0 && `${o}` === 'string' && `${{}}` === '[object Object]' && `${[1, [2, 3]]}` === '1,2,3';")
	sr_true(rt, c"const o = {toString() { return {}; }, valueOf() { return 'v'; }}; 'v'.match(o)[0] === 'v';")
	sr_true(rt, c"let e = 0; try { 'a'.replace({toString() { return {}; }, valueOf() { return {}; }}, ''); } catch (x) { e = x.constructor === TypeError; } e;")
	sr_true(rt, c"const r = /a/g; r.lastIndex = '1'; const t = r.test('ba') && r.lastIndex === 2; const s = /a/g; s.lastIndex = {valueOf() { return 2; }}; t && s.exec('aaa').index === 2;")
	sr_true(rt, c"'a1b1c'.split('1', '2').length === 2 && 'a1b1c'.split('1', -1).length === 3 && new RegExp(1).test('x1') && String(new String('ab')) === 'ab' && new String('ab')[1] === 'b';")
	sr_true(rt, c"let e = 0; try { String.prototype.match.call(null, /a/); } catch (x) { e = x.constructor === TypeError; } e && String.prototype.split.call(12, '').length === 2;")
	sr_true(rt, c"const k = {toString() { return 'key'; }}; const o = {}; o[k] = 1; o.key === 1 && ({1.5: 'x'})['1.5'] === 'x' && ({[1 + 1]: 2})['2'] === 2;")
	sr_true(rt, c"const o = {get x() { return 4; }, set x(v) { this.y = v; }}; o.x = 3; o.x === 4 && o.y === 3;")
	js_runtime_free(rt)


void test_iterators_and_calls():
	js_runtime* rt = js_runtime_new()
	sr_true(rt, c"const it = {[Symbol.iterator]() { let i = 0; return {next() { i++; return {value: i, done: i > 3}; }}; }}; let s = 0; for (const v of it) s += v; s === 6 && [...it].length === 3;")
	sr_true(rt, c"let closed = 0; const it = {[Symbol.iterator]() { return {next() { return {value: 1, done: false}; }, return() { closed++; return {}; }}; }}; for (const v of it) break; closed === 1;")
	sr_true(rt, c"let closed = 0; const it = {[Symbol.iterator]() { return {next() { return {value: 1, done: false}; }, return() { closed++; return {}; }}; }}; try { for (const v of it) throw 1; } catch (e) {} closed === 1;")
	sr_true(rt, c"function f(a, b) { return `${this.v}${a}${b}`; } f.call({v: 1}, 2, 3) === '123' && f.apply({v: 4}, [5, 6]) === '456' && Array.isArray([]) && !Array.isArray('a');")
	assert_equal(2, sr_status(rt, c"for (const x of 5) {}", 1000))
	js_runtime_free(rt)


# Matching, substitution and copying are charged to the step budget.
void test_budget():
	js_runtime* rt = js_runtime_new()
	char* setup = c"let big = 'ab'; for (let i = 0; i < 12; i++) big = big + big;"
	assert_equal(0, sr_status(rt, setup, 100000))
	assert_equal(5, sr_status(rt, c"big.replace(/a/g, '$&$&');", 20000))
	assert_equal(5, sr_status(rt, c"big.split('');", 5000))
	assert_equal(5, sr_status(rt, c"big.split(/(?:)/);", 20000))
	assert_equal(5, sr_status(rt, c"big.match(/b/g);", 20000))
	assert_equal(5, sr_status(rt, c"[...big.matchAll(/a/g)];", 20000))
	assert_equal(5, sr_status(rt, c"big.replace('zz', 'q');", 5000))
	assert_equal(5, sr_status(rt, c"'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'.search(/(a*)*b/);", 50000))
	assert_equal(0, sr_status(rt, c"big.replace(/a/g, 'c').length === 8192;", 1000000))
	# Result strings stay within the instance's string length limit.
	assert_equal(5, sr_status(rt, c"big.replace(/a/g, 'aaa');", 1000000))
	js_runtime_free(rt)


int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	test_string_methods()
	test_regexp_symbols()
	test_conversions()
	test_iterators_and_calls()
	# The budget cases allocate thousands of strings; debug mode would exhaust
	# the guard-page mappings, so the memory run covers the other cases.
	if (argc == 1): test_budget()
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_string_regexp_test: OK")
	return 0
