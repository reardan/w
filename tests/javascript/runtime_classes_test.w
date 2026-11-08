# wbuild: name=javascript_runtime_classes_test
# wbuild: target=javascript_runtime_classes_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 tests/javascript/runtime_classes_test.w -o bin/javascript_runtime_classes_test"
# wbuild: step="bin/javascript_runtime_classes_test" expect_stdout="javascript_runtime_classes_test: OK"
# wbuild: step="bin/javascript_runtime_classes_test memory" expect_stdout="javascript_runtime_classes_test: OK"
# Class runtime semantics (reardan/w#905): declarations and expressions,
# methods, accessors, static and computed members, extends, super(...),
# super.x, the derived-constructor this TDZ, new.target and class errors.
import lib.assert
import lib.args
import libs.extras.javascript.runtime


void classes_string(char* source, char* expected):
	js_runtime* rt = js_runtime_new()
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 100000)
	if (result.status != 0 || result.value.kind != 4):
		println2(source)
		println2(result.message)
	assert_equal(0, result.status)
	assert_equal(4, result.value.kind)
	js_text* text = js_runtime_key(expected)
	if (js_text_equal(text, result.value.text) == 0): println2(source)
	assert1(js_text_equal(text, result.value.text))
	js_text_free(text)
	js_runtime_free(rt)


void classes_true(char* source):
	js_runtime* rt = js_runtime_new()
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 100000)
	if (result.status != 0 || result.value.kind != 2 || result.value.number == 0.0):
		println2(source)
		println2(result.message)
	assert_equal(0, result.status)
	assert_equal(2, result.value.kind)
	assert1(result.value.number != 0.0)
	js_runtime_free(rt)


# An uncaught engine error of the given type.
void classes_error(char* source, char* name):
	js_runtime* rt = js_runtime_new()
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 100000)
	if (result.status != 2 || strcmp(result.value.intrinsic_error_name, name) != 0):
		println2(source)
		println2(result.message)
	assert_equal(2, result.status)
	assert_equal(0, strcmp(result.value.intrinsic_error_name, name))
	js_runtime_free(rt)


void classes_unsupported(char* source):
	js_runtime* rt = js_runtime_new()
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 100000)
	if (result.status != 6): println2(source)
	assert_equal(6, result.status)
	js_runtime_free(rt)


void classes_members():
	classes_string(c"class A { constructor(x) { this.x = x; } m() { return this.x; } } new A('v').m();", c"v")
	classes_true(c"class A {} var a = new A(); a instanceof A && a.constructor === A && typeof A === 'function';")
	classes_true(c"var C = class {}; new C() instanceof C && C.name === 'C' && (class {}).name === '';")
	# NamedEvaluation names anonymous classes and functions; a static name() wins.
	classes_true(c"var D; D = class { static name() { return 1; } }; let f = () => {}; var [g = function () {}] = []; typeof D.name === 'function' && f.name === 'f' && g.name === 'g';")
	classes_true(c"function f(a, b = 1, c) {} class A { m(x, ...r) {} } f.length === 1 && A.prototype.m.length === 1;")
	classes_true(c"class A { constructor(a, b) {} } A.length === 2 && A.name === 'A';")
	# Accessors share one property; the getter and setter see the receiver.
	classes_true(c"class A { get v() { return this.w; } set v(x) { this.w = x + 1; } } var a = new A(); a.v = 1; a.v === 2;")
	classes_true(c"class A { static s() { return this; } static get g() { return 3; } } A.s() === A && A.g === 3;")
	# Computed and numeric keys, including the literal spelling of a number.
	classes_true(c"var k = 'dyn'; class A { [k + 'amic']() { return 1; } 1() { return 2; } 0x10() { return 3; } 1.5() { return 4; } } var a = new A(); a.dynamic() + a[1]() + a[16]() + a['1.5']() === 10;")
	classes_true(c"class A { 'constructor'(x) { this.x = x; } } new A(7).x === 7;")
	# A computed 'constructor' key is an ordinary method.
	classes_true(c"class A { ['constructor']() { return 1; } } typeof A.prototype.constructor === 'function' && A.prototype.constructor !== A;")
	# Methods are non-enumerable and are not constructors.
	classes_true(c"class A { m() {} } var ok = true; try { new A.prototype.m(); ok = false; } catch (e) { ok = ok && e.name === 'TypeError'; } ok && A.prototype.m.prototype === undefined;")
	classes_true(c"class A { m() {} get g() {} } A.prototype.m.name === 'm' && ({...A.prototype}).m === undefined;")
	# Class bodies are strict.
	classes_error(c"class A { m() { undeclared = 1; } } new A().m();", c"ReferenceError")
	classes_error(c"class A { static ['prototype']() {} }", c"TypeError")


void classes_inheritance():
	classes_true(c"class A { constructor(x) { this.x = x; } m() { return this.x; } } class B extends A { constructor() { super(5); } m() { return super.m() + 1; } } var b = new B(); b.m() === 6 && b instanceof A && b instanceof B;")
	# The default derived constructor forwards every argument.
	classes_true(c"class A { constructor(a, b) { this.s = a + b; } } class B extends A {} new B(1, 2).s === 3 && B.length === 0;")
	# Static members inherit through the constructor's prototype.
	classes_true(c"class A { static s() { return 'A'; } } class B extends A { static s() { return super.s() + 'B'; } } B.s() === 'AB';")
	classes_true(c"class A { get g() { return this.v; } } class B extends A { constructor() { super(); this.v = 4; } get g() { return super.g * 2; } } new B().g === 8;")
	# super.x = v writes to this.
	classes_true(c"class A {} class B extends A { m() { super.x = 3; return this.x; } } new B().m() === 3;")
	classes_true(c"class A { m() { return 1; } } class B extends A { m() { return super['m']() + 1; } } new B().m() === 2;")
	# Expressions, functions and other classes as heritage.
	classes_true(c"function F() { this.f = 1; } class B extends F {} var b = new B(); b.f === 1 && b instanceof F;")
	classes_true(c"class B extends (class { constructor() { this.y = 2; } }) {} new B().y === 2;")
	classes_true(c"var base = null; function pick() { return class { k() { return 9; } }; } class B extends pick() {} new B().k() === 9;")
	classes_true(c"class E extends Error {} var e = new E('m'); e instanceof E && e instanceof Error && e.message === 'm';")
	# An arrow inside a method keeps the method's super and this.
	classes_true(c"class A { m() { return 1; } } class B extends A { m() { var f = () => super.m() + this.k; return f(); } } var b = new B(); b.k = 1; b.m() === 2;")
	# A derived constructor may return an object instead of calling super.
	classes_true(c"var o = {}; class A {} class B extends A { constructor() { return o; } } new B() === o;")
	# extends null: the prototype has a null prototype and super() throws.
	classes_error(c"class N extends null {} new N();", c"TypeError")
	classes_true(c"var o = {}; class N extends null { constructor() { return o; } } new N() === o;")
	classes_error(c"class B extends 3 {}", c"TypeError")
	classes_error(c"function F() {} F.prototype = 3; class B extends F {}", c"TypeError")
	classes_error(c"var arrow = () => {}; class B extends arrow {}", c"TypeError")


void classes_this_tdz():
	classes_error(c"class A {} class B extends A { constructor() { this.x = 1; super(); } } new B();", c"ReferenceError")
	classes_error(c"class A {} class B extends A { constructor() { super.x; } } new B();", c"ReferenceError")
	classes_error(c"class A {} class B extends A { constructor() { super(); super(); } } new B();", c"ReferenceError")
	classes_error(c"class A {} class B extends A { constructor() {} } new B();", c"ReferenceError")
	classes_error(c"class A {} class B extends A { constructor() { return 1; } } new B();", c"TypeError")
	# An arrow can call super() and initialize the constructor's this.
	classes_true(c"class A { constructor() { this.a = 1; } } class B extends A { constructor() { var f = () => super(); f(); this.b = 2; } } var b = new B(); b.a + b.b === 3;")
	# Base constructors ignore primitive return values.
	classes_true(c"class A { constructor() { this.v = 1; return 5; } } new A().v === 1;")


void classes_new_target():
	classes_true(c"var t; class A { constructor() { t = new.target; } } class B extends A {} new B(); t === B;")
	classes_true(c"var t = 0; function F() { t = new.target; } F(); var u = t; new F(); u === undefined && t === F;")
	classes_true(c"var t; function F() { t = (() => new.target)(); } new F(); t === F;")
	# new.target.prototype decides the instance prototype for a base class.
	classes_true(c"class A { constructor() { this.p = new.target.prototype; } } class B extends A {} var b = new B(); b.p === B.prototype;")


void classes_errors():
	classes_error(c"class A {} A();", c"TypeError")
	classes_error(c"class A { m() { A = 1; } } new A().m();", c"TypeError")
	classes_error(c"var C = class D { m() { D = 1; } }; new C().m();", c"TypeError")
	# The outer declaration binding stays mutable.
	classes_true(c"class A {} A = 1; A === 1;")
	# The class binding is in its TDZ during heritage evaluation and before the declaration.
	classes_error(c"class Q extends Q {}", c"ReferenceError")
	classes_error(c"new A(); class A {}", c"ReferenceError")
	classes_error(c"class A { [A]() {} }", c"ReferenceError")
	classes_true(c"var r = 0; { class A { static m() { return 2; } } r = A.m(); } r === 2 && typeof A === 'undefined';")


void classes_unsupported_forms():
	classes_unsupported(c"class A { *g() {} }")
	classes_unsupported(c"class A { async m() {} }")
	classes_unsupported(c"var o = { m() { return super.x; } };")


int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1):
		malloc_force_debug_mode()
		classes_true(c"var t; class A { constructor(x) { this.x = x; t = new.target; } get g() { return this.x; } } class B extends A { constructor() { super(2); } get g() { return super.g + 1; } } new B().g === 3 && t === B;")
		classes_error(c"class A {} class B extends A { constructor() { this.x = 1; } } new B();", c"ReferenceError")
		assert_equal(0, debug_alloc_report_leaks())
		println(c"javascript_runtime_classes_test: OK")
		return 0
	classes_members()
	classes_inheritance()
	classes_this_tdz()
	classes_new_target()
	classes_errors()
	classes_unsupported_forms()
	println(c"javascript_runtime_classes_test: OK")
	return 0
