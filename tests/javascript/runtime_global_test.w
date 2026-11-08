# wbuild: name=javascript_runtime_global_test
# wbuild: target=javascript_runtime_global_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 tests/javascript/runtime_global_test.w -o bin/javascript_runtime_global_test"
# wbuild: step="bin/javascript_runtime_global_test" expect_stdout="javascript_runtime_global_test: OK"
# wbuild: step="bin/javascript_runtime_global_test memory" expect_stdout="javascript_runtime_global_test: OK"
# reardan/w#907: the global object and global this, delete and in, for-in
# enumeration and var/assignment-target for-in/of heads, destructuring
# assignment, array holes, destructured catch parameters, primitive wrapper
# objects and direct/indirect eval.
import lib.assert
import lib.args
import libs.extras.javascript.runtime


js_completion* global_eval(js_runtime* rt, char* source):
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 100000)
	if (result.status != 0):
		println2(source)
		println2(result.message)
	return result


void global_string(char* source, char* expected):
	js_runtime* rt = js_runtime_new()
	js_completion* result = global_eval(rt, source)
	assert_equal(0, result.status)
	assert_equal(4, result.value.kind)
	js_text* text = js_runtime_key(expected)
	if (js_text_equal(text, result.value.text) == 0):
		println2(source)
		int length = 0
		println2(js_text_to_utf8(result.value.text, &length))
	assert1(js_text_equal(text, result.value.text))
	js_text_free(text)
	js_runtime_free(rt)


void global_true(char* source):
	js_runtime* rt = js_runtime_new()
	js_completion* result = global_eval(rt, source)
	if (result.value.kind != 2 || result.value.number == 0.0): println2(source)
	assert_equal(0, result.status)
	assert_equal(2, result.value.kind)
	assert1(result.value.number != 0.0)
	js_runtime_free(rt)


void global_error(char* source, char* name):
	js_runtime* rt = js_runtime_new()
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 100000)
	if (result.status != 2 || strcmp(result.value.intrinsic_error_name, name) != 0):
		println2(source)
		println2(result.message)
	assert_equal(2, result.status)
	assert_equal(0, strcmp(result.value.intrinsic_error_name, name))
	js_runtime_free(rt)


# A first script, then a second one that fails with the given error.
void global_scripts(char* first, char* second, char* name):
	js_runtime* rt = js_runtime_new()
	assert_equal(0, global_eval(rt, first).status)
	js_completion* result = js_runtime_eval(rt, second, strlen(second), 100000)
	if (result.status != 2 || strcmp(result.value.intrinsic_error_name, name) != 0): println2(second)
	assert_equal(2, result.status)
	assert_equal(0, strcmp(result.value.intrinsic_error_name, name))
	js_runtime_free(rt)


void global_unsupported(char* source):
	js_runtime* rt = js_runtime_new()
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 100000)
	if (result.status != 6): println2(source)
	assert_equal(6, result.status)
	js_runtime_free(rt)


void global_object():
	global_true(c"this === globalThis && typeof this === 'object';")
	global_true(c"var v = 1; function f() {} this.v === 1 && typeof this.f === 'function' && 'v' in this;")
	global_true(c"let l = 1; const c = 2; class K {} !('l' in this) && !('c' in this) && !('K' in this) && l === 1;")
	global_true(c"globalThis.fromObject = 5; fromObject === 5;")
	global_true(c"implicit = 3; this.implicit === 3 && delete implicit && typeof implicit === 'undefined';")
	global_true(c"var kept = 1; !delete kept && !delete this.kept && kept === 1;")
	global_true(c"Object.defineProperty(this, 'acc', {get: function() { return 7; }, configurable: true}); acc === 7;")
	global_true(c"var log = 0; Object.defineProperty(this, 'store', {set: function(v) { log = v; }, configurable: true}); store = 9; log === 9;")
	global_true(c"undefined = 1; NaN = 2; undefined === void 0 && NaN !== NaN;")
	global_true(c"var keys = ''; for (var k in this) keys += k + ','; keys === 'keys,k,';")
	global_true(c"function sloppy() { return this; } sloppy() === this;")
	global_true(c"function boxed() { return typeof this; } boxed.call(5) === 'object' && boxed.call('s') === 'object';")
	global_true(c"function strict() { 'use strict'; return this; } strict() === undefined;")
	global_true(c"(() => this)() === globalThis;")
	global_error(c"'use strict'; undeclared = 1;", c"ReferenceError")
	global_error(c"'use strict'; undefined = 1;", c"TypeError")
	global_scripts(c"var shadowed;", c"let shadowed;", c"SyntaxError")
	global_scripts(c"let first;", c"var first;", c"SyntaxError")
	global_scripts(c"let second;", c"function second() {}", c"SyntaxError")
	global_error(c"let undefined;", c"SyntaxError")
	global_error(c"function NaN() {}", c"TypeError")
	global_string(c"let Math = 'shadow'; Math;", c"shadow")


void global_delete_in():
	global_true(c"var o = {a: 1}; delete o.a && !('a' in o) && delete o.missing;")
	global_true(c"var a = [1, 2]; !delete a.length && delete a[1] && a.length === 2 && !(1 in a);")
	global_true(c"var s = new String('ab'); !delete s[0] && !delete s.length && delete s[5];")
	global_true(c"var o = {}; Object.defineProperty(o, 'x', {value: 1}); !delete o.x && delete 1 && delete 'abc'[5];")
	global_true(c"function f() {} 'prototype' in f && 'length' in [] && 0 in [1] && !(1 in [1]) && 'a' in {a: undefined};")
	global_true(c"var key = {toString: function() { return 'k'; }}; key in {k: 1};")
	global_true(c"var sym = Symbol(); var o = {}; o[sym] = 1; sym in o;")
	global_true(c"'slice' in new String('x') && 1 in new String('xy') && !(2 in new String('xy'));")
	global_error(c"'a' in 'abc';", c"TypeError")
	global_error(c"'use strict'; var o = {}; Object.defineProperty(o, 'x', {value: 1}); delete o.x;", c"TypeError")
	global_error(c"delete null.x;", c"TypeError")


void global_for_in():
	global_string(c"var s = ''; for (var k in {b: 1, a: 2, 2: 3, 1: 4}) s += k; s;", c"12ba")
	global_string(c"function F() { this.own = 1; this.shared = 2; } F.prototype = {shared: 3, inherited: 4}; var s = ''; for (var k in new F()) s += k + ','; s;", c"own,shared,inherited,")
	global_string(c"var p = {hidden: 1, shown: 2}; Object.defineProperty(p, 'hidden', {enumerable: false}); function F() {} F.prototype = p; var c = new F(); var s = ''; for (var k in c) s += k; s;", c"shown")
	global_string(c"var parent = {x: 1}; function F() { Object.defineProperty(this, 'x', {value: 2, enumerable: false}); } F.prototype = parent; var s = ''; for (var k in new F()) s += k; s;", c"")
	global_string(c"var o = {a: 1, b: 2, c: 3}; var s = ''; for (var k in o) { delete o.b; s += k; } s;", c"ac")
	global_string(c"var s = ''; for (var k in 'xy') s += k; s;", c"01")
	global_string(c"var s = ''; for (var k in [7, , 9]) s += k; s;", c"02")
	global_true(c"var n = 0; for (var k in null) n++; for (var k in undefined) n++; for (var k in 5) n++; n === 0;")
	global_true(c"var fns = []; for (let k in {a: 1, b: 2}) fns.push(function() { return k; }); fns[0]() === 'a' && fns[1]() === 'b';")
	global_true(c"for (var i = 'init' in null); i === 'init';")
	global_true(c"var o = {}; for (o.p in {q: 1}); o.p === 'q';")
	global_true(c"var a = []; for (a[0] in {z: 1}); a[0] === 'z';")
	global_true(c"var x; for ([x] in {ab: 1}); x === 'a';")
	global_true(c"var n = 0; outer: for (var k in {a: 1, b: 2}) { for (var j in {c: 1}) { n++; continue outer; } } n === 2;")
	global_true(c"var n = 0; for (var k in {a: 1, b: 2}) { n++; break; } n === 1;")
	global_string(c"function f() { for (var k in {r: 1}) return k; } f();", c"r")
	global_error(c"for (const k in {a: 1, b: 2}) k = 1;", c"TypeError")
	global_error(c"let t = {}; for (let t in t);", c"ReferenceError")


void global_for_of_heads():
	global_true(c"for (var v of [1, 2]); v === 2;")
	global_true(c"var o = {}; for (o.v of [3]); o.v === 3;")
	global_true(c"var a, b; for ([a, b] of [[1, 2]]); a === 1 && b === 2;")
	global_true(c"var a, b; for ({a, b = 5} of [{a: 4}]); a === 4 && b === 5;")
	global_true(c"for (var [p, q] of [[6, 7]]); p === 6 && q === 7;")
	global_true(c"function f() { for (var x of [1]); return x; } f() === 1 && typeof x === 'undefined';")


void global_destructuring():
	global_true(c"var a, b, r; [a, , b, ...r] = [1, 2, 3, 4, 5]; a === 1 && b === 3 && r.length === 2 && r[1] === 5;")
	global_true(c"var a, c, d; ({a, b: c, d = 7} = {a: 9, b: 8}); a === 9 && c === 8 && d === 7;")
	global_true(c"var x, y; [x = 1, y = x] = []; x === 1 && y === 1;")
	global_true(c"var k, v; var key = 'dyn'; ({[key]: v, 3: k} = {dyn: 1, 3: 2}); v === 1 && k === 2;")
	global_true(c"var o = {}; [o.a, o['b']] = [1, 2]; o.a === 1 && o.b === 2;")
	global_true(c"var a, b; [[a], {b}] = [[1], {b: 2}]; a === 1 && b === 2;")
	global_true(c"var rest, a; ({a, ...rest} = {a: 1, b: 2, c: 3}); rest.b === 2 && rest.c === 3 && !('a' in rest);")
	global_true(c"var a, b; var v = [a, b] = [5, 6]; v.length === 2 && a === 5;")
	global_true(c"var f; [f = function() {}] = []; f.name === 'f';")
	global_true(c"var f; ({f = () => 1} = {}); f.name === 'f';")
	global_true(c"var a, b; [a, b] = 'xy'; a === 'x' && b === 'y';")
	global_true(c"var len; ({length: len} = 'abc'); len === 3;")
	global_true(c"var log = ''; var src = {get a() { log += 'a'; return 1; }, get b() { log += 'b'; return 2; }}; var t = {set x(v) { log += 'x'; }, set y(v) { log += 'y'; }}; ({a: t.x, b: t.y} = src); log === 'axby';")
	global_true(c"var closed = 0; var it = {}; it[Symbol.iterator] = function() { return {next: function() { return {value: 1, done: false}; }, return: function() { closed++; return {}; }}; }; var a; [a] = it; closed === 1 && a === 1;")
	global_true(c"var closed = 0; var it = {}; it[Symbol.iterator] = function() { var n = 0; return {next: function() { n++; return {value: n, done: n > 2}; }, return: function() { closed++; return {}; }}; }; var a; [...a] = it; closed === 0 && a.length === 2;")
	global_true(c"var h = [1, , 3]; h.length === 3 && !(1 in h) && h[1] === undefined;")
	global_true(c"[, ].length === 1 && [, , ].length === 2;")
	global_true(c"try { throw {m: 3, n: [4]}; } catch ({m, n: [k]}) { m === 3 && k === 4; }")
	global_true(c"try { throw [1, 2]; } catch ([first, ...more]) { first === 1 && more[0] === 2; }")
	global_error(c"var a; ({a} = null);", c"TypeError")
	global_error(c"var a; [a] = {};", c"TypeError")
	global_error(c"const c = 1; [c] = [2];", c"TypeError")
	global_error(c"try { throw null; } catch ({x}) {}", c"TypeError")
	global_error(c"'use strict'; [missingTarget] = [1];", c"ReferenceError")


void global_wrappers():
	global_true(c"var n = new Number(5); typeof n === 'object' && n.valueOf() === 5 && n instanceof Number && n.constructor === Number;")
	global_true(c"Number('12') === 12 && Number() === 0 && Number(true) === 1 && Number.prototype.valueOf() === 0;")
	global_true(c"(255).toString(16) === 'ff' && (0.5).toString(2) === '0.1' && (-10).toString(36) === '-a' && (12).toString() === '12';")
	global_true(c"var b = new Boolean(false); typeof b === 'object' && b.valueOf() === false && b.toString() === 'false' && Boolean(b) === true;")
	global_true(c"Boolean('') === false && Boolean('x') && true.toString() === 'true' && Boolean.prototype.valueOf() === false;")
	global_true(c"Object(1) instanceof Number && Object(true) instanceof Boolean && Object('s') instanceof String && typeof Object(Symbol()) === 'object';")
	global_true(c"var o = {}; Object(o) === o && typeof Object(null) === 'object' && typeof new Object(undefined) === 'object';")
	global_true(c"Object.getPrototypeOf(1) === Number.prototype && Object.getPrototypeOf(true) === Boolean.prototype && String.prototype.valueOf() === '';")
	global_true(c"isNaN('x') && !isNaN('1') && isFinite('2') && !isFinite(Infinity) && Number.MAX_VALUE > 1e308 && Number.MIN_VALUE > 0;")
	global_string(c"String(Object(3));", c"3")
	global_error(c"Number.prototype.valueOf.call('x');", c"TypeError")
	global_error(c"Boolean.prototype.toString.call(1);", c"TypeError")
	global_error(c"(1).toString(1);", c"RangeError")


void global_eval_code():
	global_true(c"eval('1 + 2') === 3 && eval(5) === 5 && eval() === undefined && eval('') === undefined;")
	global_true(c"eval('var ev = 4; ev') === 4 && ev === 4 && delete ev && typeof ev === 'undefined';")
	global_true(c"function g() { var x = 1; eval('var x = 2; var y = 3'); return x + y; } g() === 5 && typeof y === 'undefined';")
	global_true(c"function g() { eval('function inner() { return 6; }'); return inner(); } g() === 6;")
	global_true(c"function g() { var local = 'local'; return eval('local'); } g() === 'local';")
	global_true(c"var local = 'global'; function g() { var local = 'local'; var e = eval; return e('local'); } g() === 'global';")
	global_true(c"function g() { var local = 1; return (0, eval)('typeof local'); } g() === 'undefined';")
	global_true(c"function g() { 'use strict'; eval('var hidden = 1'); return typeof hidden; } g() === 'undefined';")
	global_true(c"eval('\"use strict\"; var strictVar = 1'); typeof strictVar === 'undefined';")
	global_true(c"eval('let lexical = 1; lexical') === 1 && typeof lexical === 'undefined';")
	global_true(c"var o = {m: function() { return eval('this'); }}; o.m() === o;")
	global_true(c"try { throw 1; } catch (e) { eval('var e = 2'); } true;")
	global_true(c"var r; try { eval('a b'); } catch (e) { r = e instanceof SyntaxError && e.constructor === SyntaxError; } r;")
	global_true(c"eval('1; for (var q in null);') === undefined && eval('2; if (true) 3;') === 3;")
	global_true(c"function g() { eval('{ function blockFn() {} }'); return typeof blockFn; } g() === 'function';")
	global_true(c"eval.name === 'eval' && eval.length === 1;")
	global_error(c"let clash; eval('var clash');", c"SyntaxError")
	global_error(c"function g() { let inner; { eval('var inner'); } } g();", c"SyntaxError")
	global_error(c"try { throw [1]; } catch ([e]) { eval('var e'); }", c"SyntaxError")
	global_error(c"eval('return 1');", c"SyntaxError")
	global_error(c"function g() { 'use strict'; eval('with ({}) {}'); } g();", c"SyntaxError")
	global_unsupported(c"eval('function* gen() {}');")


int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1):
		malloc_force_debug_mode()
		global_true(c"var o = {a: 1, b: 2}; var s = ''; for (var k in o) s += k; var a, b; [a, , b] = [1, 2, 3]; ({a} = o); 'a' in o && delete o.a && eval('var e = 1; e') === 1 && new Number(2).valueOf() === 2 && s === 'ab';")
		global_error(c"eval('a b');", c"SyntaxError")
		global_true(c"function g() { eval('var z = 1'); return delete z; } g();")
		assert_equal(0, debug_alloc_report_leaks())
		println(c"javascript_runtime_global_test: OK")
		return 0
	global_object()
	global_delete_in()
	global_for_in()
	global_for_of_heads()
	global_destructuring()
	global_wrappers()
	global_eval_code()
	println(c"javascript_runtime_global_test: OK")
	return 0
