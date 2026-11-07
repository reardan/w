# wbuild: name=javascript_early_errors_test
# wbuild: target=javascript_early_errors_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 tests/javascript/early_errors_test.w -o bin/javascript_early_errors_test"
# wbuild: step="bin/javascript_early_errors_test"
# Contextual keywords, Annex B syntax and the early errors added for
# reardan/w#840. Each expectation was checked against Node's parser.
import lib.testing
import libs.extras.javascript.parser


void early(char* source, int module, int expected):
	pg_parse_result* result = js_parse(source, strlen(source), c"early.js", module)
	if (result.success != expected):
		println2(source)
		pg_diagnostics_print(result.diagnostics)
	assert_equal(expected, result.success)
	pg_parse_result_free(result)


void test_yield_await_identifiers_in_sloppy_code():
	early(c"var yield = 1; yield = 2; yield++;", 0, 1)
	early(c"function f(yield) { return yield; }", 0, 1)
	early(c"var await = 1; await + 1; await\n/1/g;", 0, 1)
	early(c"yield => 1; await => 1; async yield => 1;", 0, 1)
	early(c"var o = { yield: 1, await: 2 }; o.yield; ({yield, await});", 0, 1)
	early(c"function* g() { function f() { var yield = 1; } }", 0, 1)
	early(c"async function f() { function g() { var await = 1; } }", 0, 1)
	# Arrow bodies are not generator or async bodies of their enclosing function.
	early(c"function* g() { var f = () => yield; }", 0, 1)
	early(c"async function f() { var g = () => await; }", 0, 1)
	early(c"async function f() { var o = { m() { var await; } }; }", 0, 1)
	# A declaration's name follows the enclosing context, an expression's its own.
	early(c"function* yield() {} async function await() {}", 0, 1)
	early(c"function* g() { (function yield() {}); }", 0, 1)
	early(c"(function* yield() {});", 0, 0)
	early(c"(async function await() {});", 0, 0)
	early(c"function* g() { function yield() {} }", 0, 0)
	# Keyword-named functions keep their own context.
	early(c"function* yield() { (yield 3) + (yield 4); }", 0, 1)
	early(c"async function await() { (await 1); }", 0, 1)
	early(c"async function f() { for await (x of y) { await z; } }", 0, 1)


void test_yield_await_reserved_contexts():
	early(c"function* g() { var yield; }", 0, 0)
	early(c"async function f() { var await; }", 0, 0)
	early(c"function* g() { yield = 1; }", 0, 0)
	early(c"async function f() { await; }", 0, 0)
	early(c"'use strict'; var yield;", 0, 0)
	early(c"var await;", 1, 0)
	early(c"function f() { var await; }", 1, 0)
	early(c"async await => 1;", 0, 0)
	early(c"async (await) => 1;", 0, 0)
	early(c"function* g() { (x = yield) => 1; }", 0, 0)
	early(c"async function f() { (x = await 1) => x; }", 0, 0)
	early(c"function* g() { var g = () => { yield 1; }; }", 0, 0)
	early(c"function f() { for await (x of y) ; }", 0, 0)
	early(c"await 1;", 0, 0)


void test_call_assignment_targets():
	# Sloppy scripts parse them (Annex B web compatibility); evaluation throws.
	early(c"f() = 1; f() += 1; f()++; --f(); (f()) = 1; a.b() = 1; f()() = 1;", 0, 1)
	early(c"for (f() in x) ; for (f() of x) ;", 0, 1)
	# Strict code and modules keep the ES2020 early error.
	early(c"'use strict'; f() = 1;", 0, 0)
	early(c"'use strict'; f()++;", 0, 0)
	early(c"'use strict'; for (f() in x) ;", 0, 0)
	early(c"f() = 1;", 1, 0)
	early(c"function g() { 'use strict'; f() = 1; }", 0, 0)
	# Never valid: optional calls, new, templates, import() and patterns.
	early(c"a?.b() = 1;", 0, 0)
	early(c"new f() = 1;", 0, 0)
	early(c"f`x` = 1;", 0, 0)
	early(c"import(x) = 1;", 0, 0)
	early(c"[f()] = x;", 0, 0)
	early(c"({a: f()} = x);", 0, 0)


void test_html_like_comments():
	early(c"var x = 1; <!-- comment\nx;", 0, 1)
	early(c"<!-- start", 0, 1)
	early(c"--> start", 0, 1)
	early(c"x = 1;\n   --> comment", 0, 1)
	early(c"x = 1; /*\n*/ --> comment", 0, 1)
	early(c"x = 1;\n/* a */ /* b\n */ --> c", 0, 1)
	early(c"x-->y;", 0, 1)
	early(c"x = 1; /* */ --> comment", 0, 0)
	early(c"x = 1 --> 0;", 0, 0)
	early(c"<!-- x", 1, 0)
	early(c"x = 1;\n--> comment", 1, 0)
	early(c"x-->y;", 1, 1)


void test_legacy_octal_literals():
	early(c"010; 08; 08.5; 08e1; 0789; 00; 07.toString();", 0, 1)
	early(c"07.5;", 0, 0)
	early(c"07e1;", 0, 0)
	early(c"07n;", 0, 0)
	early(c"'use strict'; 00;", 0, 0)
	early(c"'use strict'; 0789;", 0, 0)
	early(c"'\\101\\8';", 0, 1)
	early(c"'use strict'; '\\8';", 0, 0)


void test_annex_b_block_functions():
	early(c"{ function f() {} function f() {} }", 0, 1)
	early(c"switch (x) { case 1: function f() {} case 2: function f() {} }", 0, 1)
	early(c"'use strict'; { function f() {} function f() {} }", 0, 0)
	early(c"{ async function f() {} function f() {} }", 0, 0)
	early(c"{ function* f() {} function f() {} }", 0, 0)
	early(c"{ let f; function f() {} }", 0, 0)
	# An if-clause function is alone in an implicit block.
	early(c"function g() { let f = 1; if (true) function f() {} }", 0, 1)
	early(c"L: function f() {} a: b: function g() {}", 0, 1)
	early(c"if (1) L: function f() {}", 0, 0)
	early(c"while (1) L: function f() {}", 0, 0)
	early(c"if (1) L: L2: function f() {}", 0, 0)
	early(c"switch (1) { case 1: L: function f() {} }", 0, 1)


void test_static_semantics_additions():
	early(c"({__proto__: 1, __proto__: 2});", 0, 0)
	early(c"({__proto__: 1, '__proto__': 2});", 0, 0)
	early(c"x = {a: {__proto__: 1, __proto__: 2}};", 0, 0)
	early(c"({__proto__: 1, ['__proto__']: 2, __proto__() {}, __proto__});", 0, 1)
	early(c"({__proto__: a, __proto__: b} = {}); [{__proto__: a, __proto__: b}] = c;", 0, 1)
	early(c"let let = 1;", 0, 0)
	early(c"let [let] = x;", 0, 0)
	early(c"const let = 1;", 0, 0)
	early(c"for (let let of x) ;", 0, 0)
	early(c"var let = 1; { function let() {} }", 0, 1)
	early(c"for (x of a, b) ;", 0, 0)
	early(c"for (x in a, b) ; for (x of [a, b]) ;", 0, 1)
	early(c"for (let.x of y) ;", 0, 0)
	early(c"for (let.x in y) ;", 0, 1)
	early(c"a?.b`x`;", 0, 0)
	early(c"a?.b.c`x`;", 0, 0)
	early(c"new a?.b();", 0, 0)
	early(c"new a.b?.c;", 0, 0)
	early(c"new a()?.b; a?.b;", 0, 1)
	# Nested rest elements are checked by their own patterns.
	early(c"let {c: [d, ...e]} = x; let {g: {...h}} = x; function f(a, {c: [...e]}) {}", 0, 1)
	early(c"function f(a = (...b) => 1, c) {}", 0, 1)
	early(c"let {c: [...d, e]} = x;", 0, 0)
