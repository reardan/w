# wbuild: name=javascript_runtime_coroutines_test
# wbuild: target=javascript_runtime_coroutines_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 tests/javascript/runtime_coroutines_test.w -o bin/javascript_runtime_coroutines_test"
# wbuild: step="bin/javascript_runtime_coroutines_test" expect_stdout="javascript_runtime_coroutines_test: OK"
# wbuild: step="bin/javascript_runtime_coroutines_test memory" expect_stdout="javascript_runtime_coroutines_test: OK"
# Generators, async functions, async generators and for await (reardan/w#906).
import lib.assert
import lib.args
import libs.extras.javascript.runtime


js_completion* co_eval(js_runtime* rt, char* source):
	return js_runtime_eval(rt, source, strlen(source), 100000)


void co_true(js_runtime* rt, char* source):
	js_completion* result = co_eval(rt, source)
	if (result.status != 0 || result.value.kind != 2 || result.value.number != 1.0):
		println(source)
		println(result.message)
	assert_equal(0, result.status)
	assert_equal(2, result.value.kind)
	assert1(result.value.number == 1.0)


void co_status(js_runtime* rt, char* source, int status):
	js_completion* result = co_eval(rt, source)
	if (result.status != status): println(source)
	assert_equal(status, result.status)


void co_drain(js_runtime* rt):
	js_completion* result = js_runtime_drain_microtasks(rt, 100000)
	if (result.status != 0): println(result.message)
	assert_equal(0, result.status)


void test_generator_protocol():
	js_runtime* rt = js_runtime_new()
	co_true(rt, c"function* g(a) { const x = yield a; const y = yield x + 1; return x + y; } var it = g(5); var r1 = it.next(); var r2 = it.next(10); var r3 = it.next(3); var r4 = it.next(); r1.value === 5 && !r1.done && r2.value === 11 && r3.value === 13 && r3.done && r4.value === undefined && r4.done;")
	# return/throw before the start complete the generator without running it.
	co_true(rt, c"var ran = false; function* s() { ran = true; yield 1; } var a = s(); var ra = a.return(4); var b = s(); var caught; try { b.throw(9); } catch (e) { caught = e; } !ran && ra.value === 4 && ra.done && caught === 9 && a.next().done && b.next().done;")
	# A finally block runs (and may yield) on return(); throw() is catchable.
	co_true(rt, c"function* f() { try { yield 1; } finally { yield 2; } } var t = f(); t.next(); var x = t.return(7); var y = t.next(); x.value === 2 && !x.done && y.value === 7 && y.done;")
	co_true(rt, c"function* c() { try { yield 1; } catch (e) { yield e + 1; } } var ci = c(); ci.next(); ci.throw(41).value === 42;")
	co_true(rt, c"function* reentry() { try { me.next(); } catch (e) { yield e instanceof TypeError; } } var me = reentry(); me.next().value;")
	# Generator objects inherit the function's prototype object.
	co_true(rt, c"function* p() {} p.prototype.extra = 3; var o = p(); o.extra === 3 && Object.getPrototypeOf(o) === p.prototype && typeof o[Symbol.iterator] === 'function' && o[Symbol.iterator]() === o;")
	co_true(rt, c"let notConstructor = false; try { new p(); } catch (e) { notConstructor = e instanceof TypeError; } notConstructor;")
	co_true(rt, c"var bad = 0; try { p.prototype.next.call({}); } catch (e) { bad = 1; } bad === 1;")
	# for-of, spread and destructuring-free iteration consume generators.
	co_true(rt, c"function* n() { for (let i = 0; i < 4; i++) yield i; } let sum = 0; for (const v of n()) sum += v; [...n()].length === 4 && sum === 6;")
	co_true(rt, c"var closed = 0; function* k() { try { yield 1; yield 2; } finally { closed++; } } for (const v of k()) break; closed === 1;")
	js_runtime_free(rt)


void test_resumable_constructs():
	js_runtime* rt = js_runtime_new()
	co_true(rt, c"function* b() { return (yield 1) + (yield 2); } var i = b(); i.next(); i.next(10); i.next(20).value === 30;")
	co_true(rt, c"function add(a, b, c) { return a + b + c; } function* call() { return add(1, yield, ...(yield)); } var i = call(); i.next(); i.next(10); i.next([2, 3]).value === 13;")
	co_true(rt, c"function* lit() { return [1, yield, { a: yield, [yield]: 4 }]; } var i = lit(); i.next(); i.next(2); i.next(3); var r = i.next('k').value; r[1] === 2 && r[2].a === 3 && r[2].k === 4;")
	co_true(rt, c"function* tpl() { return `${yield}-${yield}`; } var i = tpl(); i.next(); i.next('a'); i.next('b').value === 'a-b';")
	# Compound assignment keeps the value read before the suspension.
	co_true(rt, c"var x = 1; function* cmp() { x += yield; } var i = cmp(); i.next(); x = 100; i.next(5); x === 6;")
	co_true(rt, c"var o = {}; function* mem() { o[yield 'k'] = yield 'v'; return o.key; } var i = mem(); i.next(); i.next('key'); i.next(9).value === 9;")
	co_true(rt, c"function* cond(f) { if (yield) { return f ? (yield 'a') : 'b'; } else { return 'c'; } } var i = cond(true); i.next(); i.next(true); i.next('z').value === 'z';")
	co_true(rt, c"function* loops() { let n = 0; while (n < 2) { n += yield n; } do { n += yield n; } while (n < 10); for (let j = yield 'init'; j < 3; j = j + (yield j)) {} return n; } var i = loops(); var seen = []; var r = i.next(); while (!r.done) { seen.push(r.value); r = i.next(typeof r.value === 'number' ? 1 : 0); } r.value === 10;")
	co_true(rt, c"function* capture() { const fs = []; for (let i = 0; i < 3; i++) { fs.push(() => i); yield; } return fs[0]() + fs[1]() + fs[2](); } var it = capture(); it.next(); it.next(); it.next(); it.next().value === 3;")
	co_true(rt, c"function* sw(v) { switch (v) { case yield 'test': return yield 'body'; default: return 'none'; } } var i = sw(5); i.next(); i.next(5); i.next('done').value === 'done';")
	co_true(rt, c"function* lab() { outer: for (const a of [1, 2]) { for (const b of [1, 2]) { if ((yield b) === 'skip') continue outer; if (b === 2) break outer; } } return 'end'; } var i = lab(); i.next(); i.next('skip'); i.next(); i.next().value === 'end';")
	co_true(rt, c"function* tc() { var log = ''; try { log += yield 1; throw 'x'; } catch (e) { log += e; log += yield 2; } finally { log += yield 3; } return log; } var i = tc(); i.next(); i.next('a'); i.next('b'); i.next('c').value === 'axbc';")
	co_true(rt, c"function* decl() { var a = yield 1, b = a + (yield 2); let c = yield 3; return a + b + c; } var i = decl(); i.next(); i.next(1); i.next(2); i.next(3).value === 7;")
	co_true(rt, c"var obj = { *m() { yield this.k; }, k: 8, async am() { return 1; } }; obj.m().next().value === 8 && obj.m.name === 'm' && typeof obj.am().then === 'function';")
	co_true(rt, c"function B() {} function* cls() { class C extends (yield 'heritage', B) { [yield 'key']() { return 1; } static get [yield 'static']() { return 2; } } return new C().m() + C.st + (new C() instanceof B ? 4 : 0); } var i = cls(); i.next(); i.next(B); i.next('m'); i.next('st').value === 7;")
	co_true(rt, c"function B() {} function* g() { class C extends (B) { [yield 'k']() { return 3; } } var o = { *extends() { yield 4; } }; return new C().m() + o.extends().next().value; } var i = g(); i.next(); i.next('m').value === 7;")
	co_true(rt, c"async function await() { return 1; } await instanceof Function && (function* () {}) instanceof Function && (async () => 1) instanceof Function && Function.prototype.constructor === Function;")
	co_status(rt, c"Function('return 1');", 6)
	# Array binding patterns use the iterator protocol and close what they leave open.
	co_true(rt, c"function* g() { yield 1; yield 2; yield 3; } var [a, , ...r] = g(); var closed = 0; var o = {}; o[Symbol.iterator] = function () { return { next: function () { return {value: 5, done: false}; }, return: function () { closed = closed + 1; return {}; } }; }; var [x] = o; var [] = o; a === 1 && r.length === 1 && r[0] === 3 && x === 5 && closed === 2;")
	co_true(rt, c"var saved = Array.prototype[Symbol.iterator]; Array.prototype[Symbol.iterator] = function* () { yield 7; }; var [p, q] = [1, 2]; Array.prototype[Symbol.iterator] = saved; p === 7 && q === undefined;")
	# yield* delegates next/throw/return and passes results through.
	co_true(rt, c"function* inner() { var x = yield 1; return x * 2; } function* outer() { var r = yield* inner(); yield r; } var i = outer(); i.next(); i.next(21).value === 42;")
	co_true(rt, c"var result = { value: 5, done: false }; var iterable = { [Symbol.iterator]() { return { next() { return result; } }; } }; function* d() { yield* iterable; } d().next() === result;")
	co_true(rt, c"var log = []; var it2 = { [Symbol.iterator]() { return this; }, next() { return { value: 1, done: false }; }, return(v) { log.push('return'); return { value: v, done: true }; } }; function* d2() { yield* it2; } var g2 = d2(); g2.next(); var rr = g2.return(3); rr.value === 3 && rr.done && log.length === 1;")
	co_true(rt, c"var noThrow = { [Symbol.iterator]() { return this; }, next() { return { done: false }; }, return() { noThrow.closed = true; return {}; } }; function* d3() { yield* noThrow; } var g3 = d3(); g3.next(); var te = false; try { g3.throw(1); } catch (e) { te = e instanceof TypeError; } te && noThrow.closed;")
	co_true(rt, c"function* arr() { yield* [1, 2]; yield* 'ab'; } [...arr()].length === 4;")
	# Yield inside unsupported positions is rejected before execution.
	co_status(rt, c"function* bad() { var [a = yield] = []; }", 6)
	co_status(rt, c"function* bad2() { a?.b(yield); }", 6)
	co_status(rt, c"function* bad3() { var o = {}; o[yield]++; }", 6)
	js_runtime_free(rt)


void test_async_functions():
	js_runtime* rt = js_runtime_new()
	co_true(rt, c"var log = []; async function f(x) { log.push('start'); const y = await x; log.push('resumed'); return y + 1; } var p = f(3); log.push('sync'); var out; p.then(v => { out = v; }); log.length === 2 && log[1] === 'sync';")
	co_drain(rt)
	co_true(rt, c"out === 4 && log[2] === 'resumed';")
	# Rejections throw at the await; throws reject the promise.
	co_true(rt, c"var caught, rejected; async function g() { try { await Promise.reject(5); } catch (e) { caught = e; } throw 'late'; } g().catch(e => { rejected = e; }); true;")
	co_drain(rt)
	co_true(rt, c"caught === 5 && rejected === 'late';")
	# Parameter errors reject instead of throwing synchronously.
	co_true(rt, c"var perr; async function h(a = missing) {} h().catch(e => { perr = e instanceof ReferenceError; }); true;")
	co_drain(rt)
	co_true(rt, c"perr;")
	# Ordering: await of a native promise takes one job; thenables are assimilated.
	co_true(rt, c"var order = ''; async function one() { order += 'a'; await undefined; order += 'c'; } one(); Promise.resolve().then(() => { order += 'd'; }); order += 'b'; var thenable = { then(resolve) { resolve(42); } }; var tv; (async () => { tv = await thenable; })(); true;")
	co_drain(rt)
	co_true(rt, c"order === 'abcd' && tv === 42;")
	co_true(rt, c"var self = { k: 1, m() { return (async () => this.k)(); } }; var arrowThis; self.m().then(v => { arrowThis = v; }); var exprArrow; (async x => x * 2)(21).then(v => { exprArrow = v; }); true;")
	co_drain(rt)
	co_true(rt, c"arrowThis === 1 && exprArrow === 42;")
	co_status(rt, c"await 1;", 6)
	js_runtime_free(rt)


void test_async_generators():
	js_runtime* rt = js_runtime_new()
	# Requests queue while the generator runs and settle in order.
	co_true(rt, c"var got = []; async function* ag() { var x = yield 1; got.push(x); yield await Promise.resolve(2); return 3; } var it = ag(); var ps = [it.next(), it.next('sent'), it.next(), it.next()]; for (const p of ps) p.then(r => { got.push(r.value, r.done); }); true;")
	co_drain(rt)
	# The queued request resumes the body before request 1's reaction runs.
	co_true(rt, c"got.length === 9 && got[0] === 'sent' && got[1] === 1 && got[2] === false && got[3] === 2 && got[5] === 3 && got[6] === true && got[7] === undefined && got[8] === true;")
	co_true(rt, c"var fin = []; async function* f() { try { yield 1; yield 2; } finally { fin.push('cleanup'); } } var g = f(); g.next().then(() => g.return(9)).then(r => { fin.push(r.value, r.done); }); true;")
	co_drain(rt)
	co_true(rt, c"fin[0] === 'cleanup' && fin[1] === 9 && fin[2] === true;")
	co_true(rt, c"var thrown; async function* t() { yield 1; } var tg = t(); tg.throw(7).catch(e => { thrown = e; }); true;")
	co_drain(rt)
	co_true(rt, c"thrown === 7;")
	# for await over async generators, sync iterables and with an early exit.
	co_true(rt, c"var sum = 0; var closed = false; async function* src() { try { yield 1; yield 2; yield 3; } finally { closed = true; } } async function consume() { for await (const v of src()) { sum += v; if (v === 2) break; } for await (const w of [10, Promise.resolve(20)]) sum += w; return sum; } var total; consume().then(v => { total = v; }); true;")
	co_drain(rt)
	co_true(rt, c"total === 33 && closed;")
	co_true(rt, c"async function* inner() { yield 'a'; return 'r'; } async function* outer() { var r = yield* inner(); yield r; yield* ['s']; } var seen = []; (async () => { for await (const v of outer()) seen.push(v); })(); true;")
	co_drain(rt)
	co_true(rt, c"seen.length === 3 && seen[0] === 'a' && seen[1] === 'r' && seen[2] === 's';")
	co_true(rt, c"var bad; async function* b() {} b.prototype.next.call({}).catch(e => { bad = e instanceof TypeError; }); true;")
	co_drain(rt)
	co_true(rt, c"bad;")
	js_runtime_free(rt)


# Suspended activations are heap values: they survive collection while
# reachable, are reclaimed with their frames when not, and resuming
# charges steps for every re-entered frame.
void test_limits():
	js_runtime* rt = js_runtime_new()
	co_true(rt, c"function* deep() { let a = [1, [2, { k: yield 1 }]]; return a[1][1].k; } var held = deep(); held.next().value === 1;")
	js_runtime_collect(rt)
	co_true(rt, c"held.next(5).value === 5;")
	co_true(rt, c"var dropped = deep(); dropped.next(); dropped = null; true;")
	int before = rt.heap.length
	assert1(js_runtime_collect(rt) > 0)
	assert1(rt.heap.length < before)
	# An awaiting async function stays alive through its promise reaction.
	co_true(rt, c"var resolveLater; var late = 0; (async () => { late = await new Promise(r => { resolveLater = r; }); })(); true;")
	js_runtime_collect(rt)
	co_true(rt, c"resolveLater(8); true;")
	co_drain(rt)
	co_true(rt, c"late === 8;")
	# A step-limit abort inside a generator is terminal and closes it.
	char* spin = c"function* spin() { yield 1; while (true) {} } var s = spin(); s.next(); s.next();"
	assert_equal(5, js_runtime_eval(rt, spin, strlen(spin), 2000).status)
	co_true(rt, c"s.next().done;")
	# Long-suspended generators resume after many evaluations and collections.
	co_true(rt, c"function* counter() { let n = 0; while (true) n += yield n; } var count = counter(); count.next(); true;")
	for i in range(20):
		co_true(rt, c"count.next(1).value > 0;")
		js_runtime_collect(rt)
	co_true(rt, c"count.next(0).value === 20;")
	js_runtime_free(rt)
	# Frames count against max_values: a full heap turns a suspension into a limit.
	rt = js_runtime_new()
	co_true(rt, c"function* nest() { return [[[[yield 1]]]]; } var nn = nest(); true;")
	rt.max_values = rt.heap.length + 3
	assert_equal(5, co_eval(rt, c"nn.next();").status)
	rt.max_values = 100000
	co_true(rt, c"nn.next().done;")
	js_runtime_free(rt)


int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	test_generator_protocol()
	test_resumable_constructs()
	test_async_functions()
	test_async_generators()
	test_limits()
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_coroutines_test: OK")
	return 0
