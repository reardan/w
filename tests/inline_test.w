# wbuild: x64
# wbuild: step="bin/wv2 --inline tests/inline_test.w -o bin/inline_inline_test"
# wbuild: step="bin/inline_inline_test" expect_stdout="inline_test passed"
# wbuild: step="bin/wv2 x64 --inline tests/inline_test.w -o bin/inline_inline_64_test"
# wbuild: step="bin/inline_inline_64_test" expect_stdout="inline_test passed"
# wbuild: step="bin/wv2 --inline --stats tests/inline_test.w -o bin/inline_stats_test" expect_stderr="inline: bodies recorded"
# Inlining of small leaf callees (docs/projects/codegen_gap_plan.md
# §2.4, unit A5; compiler/inline_table.w, grammar/inline_call.w): under
# --inline (or --profile-use, for profile-hot sites) a call to a small,
# loop-free function whose body was already compiled is
# emitted as the body itself, with the arguments bound as fresh locals
# and 'return' lowered to a jump. Every shape the decision and the
# re-parse distinguish is exercised here, each asserting a computed
# value, so the test passes whether or not a given call was inlined --
# what it pins is that inlining never changes what a program computes:
# one and several parameters, argument order and single evaluation,
# a parameter shadowing a caller local and a caller local shadowing a
# global the body reads (the capture rule keeps that call a call),
# globals read and written, early returns, void bodies, bodies with
# locals, nested inlining, struct returns (never inlined) and struct
# pointers, recursion, defaults, narrow and float parameters, hidden
# runtime calls inside the body, calls inside loops that own registers,
# a callee defined after the caller, calls as arguments of calls, a
# switch, defer (never inlined), and an inlined callee that is also
# used through a function pointer, and calls as operands of condition
# chains and of subscripts and field accesses. The default build
# inlines only the tiniest of these (tests/inline_const_test.w); the
# extra steps run the same program built with --inline on both widths,
# and check that such a build reports inlining in its --stats.
import lib.lib
import lib.assert


# --- one and several parameters ---------------------------------------------
int in_inc(int x):
	return x + 1


int in_fma(int a, int b, int c):
	return a * b + c


int in_twice_inc(int x):
	return in_inc(in_inc(x))


# --- globals ------------------------------------------------------------------
int in_g = 0
int in_log = 0


void in_set_g(int v):
	in_g = v


int in_get_g():
	return in_g


int in_bump_g():
	in_g = in_g + 1
	return 10


int in_read_g(int x):
	return x + in_g


# in_log = in_log * 10 + n, so the evaluation order shows in the digits
int in_next(int n):
	in_log = in_log * 10 + n
	return n


# --- early returns, locals, switch --------------------------------------------
int in_clamp(int v):
	if (v < 0): return 0
	if (v > 9): return 9
	return v


int in_sq_plus(int x):
	int t = x * x
	return t + 1


int in_sign(int v):
	int r = 0
	if (v > 0):
		int one = 1
		r = one
	elif (v < 0):
		r = 0 - 1
	return r


int in_sw(int k):
	int r = 100
	switch (k):
		case 1:
			r = 11
		case 2:
			r = 22
		default:
			r = 33
	return r


# --- structs ------------------------------------------------------------------
struct in_pair:
	int a
	int b


in_pair in_make(int a):
	in_pair p
	p.a = a
	p.b = a * 10
	return p


int in_sum(in_pair* p):
	return p.a + p.b


void in_store(int* p, int v):
	*p = v


# --- recursion ----------------------------------------------------------------
int in_fact(int n):
	if (n <= 1): return 1
	return n * in_fact(n - 1)


# --- defaults, narrow and float parameters -----------------------------------
int in_def(int a, int b = 5):
	return a * 100 + b


int in_isdigit(char c):
	return (c >= '0') && (c <= '9')


int in_narrow(int32 a, int16 b):
	return a - b


float32 in_half(float32 x):
	return x / 2.0


# --- hidden runtime calls inside the body -------------------------------------
int in_first(list[int] l):
	return l[0]


int in_len(char* s):
	return strlen(s)


# --- defer: never inlined -------------------------------------------------------
int in_defer_log = 0


int in_with_defer(int x):
	defer in_defer_log = in_defer_log + x
	return x * 2


# --- a callee defined after the caller stays a call ---------------------------
int in_later(int x);


int in_before(int x):
	return in_later(x) + 1


int in_later(int x):
	return x * 3


int in_after(int x):
	return in_later(x) + 2


# --- function pointers ---------------------------------------------------------
type in_binop = fn(int, int) -> int


int in_mul(int a, int b):
	return a * b


int in_apply(in_binop* f, int a, int b):
	return f(a, b)


# --- calls inside loops ---------------------------------------------------------
int in_loop(int n):
	int s = 0
	int i = 0
	int j = 7
	while (i < n):
		# a leaf callee inlined inside a loop whose word-sized locals
		# may own caller-saved registers on x64
		s = s + in_fma(i, 3, j) + in_clamp(i - 2)
		i = i + 1
		j = j + 1
	return s * 100 + j


int in_loop_nested(int n):
	int s = 0
	for i in range(n):
		for k in range(3):
			s = s + in_twice_inc(i * k)
	return s


# --- a call as an operand of a condition chain or a subscript -----------------
int in_arr_get(int* a, int i):
	return a[i]


int in_cond_chain(int a, int b):
	# the inlined bodies are operands of && / || / ! in condition
	# context (grammar/cond_branch.w: branch-on-flags, unit A6), and of
	# a comparison a value consumer reads
	int r = 0
	if ((in_inc(a) > 2) && (in_clamp(b) == 0)): r = r + 1
	if ((in_inc(a) > 2) || in_isdigit(cast(char, b + '0'))): r = r + 10
	if (!in_sign(a - b)): r = r + 100
	if ((a > 0 || b > 0) == in_sign(a + b)): r = r + 1000
	while (in_inc(r) < 1105): r = r + 1
	return r


int in_subscripts(int* a, int n):
	# the inlined bodies are index and base operands of subscripts and
	# field accesses (x86 addressing modes, unit A2)
	int s = 0
	for i in range(n):
		s = s + a[in_clamp(i)] + in_arr_get(a, in_inc(i) - 1) * 10
	a[in_clamp(n + 5)] = in_fma(s, 1, 1)
	in_pair p
	p.a = a[in_sign(n)]
	p.b = in_arr_get(&p.a, 0) + in_sq_plus(a[in_clamp(1)])
	return s * 1000 + a[9] + p.b


# --- tests ----------------------------------------------------------------------
void test_parameters():
	assert_equal(2, in_inc(1))
	assert_equal(7, in_fma(2, 3, 1))
	assert_equal(12, in_twice_inc(10))
	assert_equal(5, in_inc(in_inc(in_inc(2))))
	assert_equal(2 * 3 + 4, in_fma(in_inc(1), in_inc(2), in_inc(3)))
	assert_equal(in_fma(in_fma(1, 2, 3), in_fma(1, 1, 1), in_inc(0)), 5 * 2 + 1)


void test_evaluation_order():
	in_log = 0
	assert_equal(1 * 2 + 3, in_fma(in_next(1), in_next(2), in_next(3)))
	assert_equal(123, in_log)
	in_g = 4
	# the argument's side effect happens once, before the body reads in_g
	assert_equal(10 + 5, in_read_g(in_bump_g()))
	assert_equal(5, in_g)
	in_log = 0
	int v = in_inc(in_next(7)) + in_inc(in_next(8))
	assert_equal(8 + 9, v)
	assert_equal(78, in_log)


void test_shadowing():
	# the caller's x is not the callee's parameter x
	int x = 100
	assert_equal(6, in_inc(5))
	assert_equal(100, x)
	assert_equal(101, in_inc(x))
	# a caller local named like a global the body reads: the body must
	# still read the global (the call is not inlined here)
	int in_g = 1000
	in_set_g(3)
	assert_equal(3, in_get_g())
	assert_equal(1000, in_g)
	assert_equal(7 + 3, in_read_g(7))
	in_g = in_g + 1
	assert_equal(1001, in_g)
	assert_equal(3, in_get_g())


void test_globals():
	in_set_g(7)
	assert_equal(7, in_get_g())
	in_set_g(in_get_g() + in_inc(in_get_g()))
	assert_equal(15, in_g)
	assert_equal(15, in_get_g())


void test_control_flow():
	assert_equal(0, in_clamp(0 - 5))
	assert_equal(9, in_clamp(50))
	assert_equal(4, in_clamp(4))
	assert_equal(0 + 9 + 4, in_clamp(0 - 1) + in_clamp(10) + in_clamp(4))
	assert_equal(26, in_sq_plus(5))
	assert_equal(1, in_sign(8))
	assert_equal(0 - 1, in_sign(0 - 8))
	assert_equal(0, in_sign(0))
	assert_equal(11, in_sw(1))
	assert_equal(22, in_sw(2))
	assert_equal(33, in_sw(9))


void test_structs():
	in_pair p = in_make(3)
	assert_equal(3, p.a)
	assert_equal(30, p.b)
	assert_equal(33, in_sum(&p))
	in_pair q = in_make(in_inc(1))
	assert_equal(22, in_sum(&q))
	int slot = 0
	in_store(&slot, 41)
	assert_equal(41, slot)
	in_store(&p.b, in_inc(slot))
	assert_equal(3 + 42, in_sum(&p))


void test_recursion_and_defaults():
	assert_equal(120, in_fact(5))
	assert_equal(1, in_fact(0))
	assert_equal(305, in_def(3))
	assert_equal(302, in_def(3, 2))
	assert_equal(1, in_isdigit('7'))
	assert_equal(0, in_isdigit('x'))
	int32 a = 1000
	int16 b = 7
	assert_equal(993, in_narrow(a, b))
	float32 h = in_half(3.0)
	asserts(c"float parameter", h == 1.5)


void test_runtime_calls_in_body():
	list[int] l = new list[int]
	l.push(42)
	l.push(43)
	assert_equal(42, in_first(l))
	assert_equal(5, in_len(c"hello"))
	assert_equal(42 + 5, in_first(l) + in_len(c"hello"))


void test_defer():
	in_defer_log = 0
	assert_equal(6, in_with_defer(3))
	assert_equal(3, in_defer_log)


void test_definition_order():
	assert_equal(7, in_before(2))
	assert_equal(8, in_after(2))
	assert_equal(6, in_later(2))


void test_function_values():
	assert_equal(12, in_apply(in_mul, 3, 4))
	assert_equal(12, in_mul(3, 4))
	in_binop* f = in_mul
	assert_equal(20, f(4, 5))
	assert_equal(20, in_mul(4, 5))
	asserts(c"an inlined callee still has an address", cast(int, in_inc) != 0)
	asserts(c"distinct functions differ", cast(int, in_inc) != cast(int, in_mul))


void test_loops():
	# i = 0..4: fma = i*3+j with j = 7..11, clamp(i-2) = 0 0 0 1 2
	int want = (0 + 7) + (3 + 8) + (6 + 9) + (9 + 10) + (12 + 11) + 3
	assert_equal(want * 100 + 12, in_loop(5))
	# i = 0..2, k = 0..2: twice_inc(i*k) = i*k + 2
	assert_equal(9 * 2 + (0 + 1 + 2) * (0 + 1 + 2), in_loop_nested(3))


void test_condition_and_subscript_operands():
	# a=5, b=0: inc(5)=6>2 && clamp(0)==0 -> +1; 6>2 -> +10; sign(5)=1,
	# !1 -> no; (1) == sign(5)=1 -> +1000; the while leaves r = 1104
	assert_equal(1104, in_cond_chain(5, 0))
	# a=0, b=0: inc(0)=1>2 no; isdigit('0') -> +10; !sign(0) -> +100;
	# (0) == sign(0)=0 -> +1000; the while never runs: 1110
	assert_equal(1110, in_cond_chain(0, 0))
	# a=1, b=3: inc(1)=2>2 no; isdigit('3') -> +10; sign(-2)=-1, !(-1) no;
	# (1) == sign(4)=1 -> +1000; while: 1010 -> 1104
	assert_equal(1104, in_cond_chain(1, 3))
	int* a = cast(int*, malloc(10 * __word_size__))
	for i in range(10): a[i] = i * i
	# s over i=0..2: a[clamp(i)] = 0,1,4; arr_get(a, inc(i)-1) = a[i] -> 0,1,4
	# s = (0+0) + (1+10) + (4+40) = 55; a[clamp(8)] = a[8] = fma(55,1,1) = 56
	# p.a = a[sign(3)] = a[1] = 1; p.b = 1 + sq_plus(a[1]) = 1 + 2 = 3
	# result = 55*1000 + a[9] (81) + 3
	assert_equal(55 * 1000 + 81 + 3, in_subscripts(a, 3))
	assert_equal(56, a[8])


int main():
	test_parameters()
	test_condition_and_subscript_operands()
	test_evaluation_order()
	test_shadowing()
	test_globals()
	test_control_flow()
	test_structs()
	test_recursion_and_defaults()
	test_runtime_calls_in_body()
	test_defer()
	test_definition_order()
	test_function_values()
	test_loops()
	println(c"inline_test passed")
	return 0
