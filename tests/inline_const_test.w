# wbuild: x64
# wbuild: step="bin/wv2 --no-inline tests/inline_const_test.w -o bin/inline_const_noinline_test"
# wbuild: step="bin/inline_const_noinline_test" expect_stdout="inline_const_test passed"
# wbuild: step="bin/wv2 x64 --inline tests/inline_const_test.w -o bin/inline_const_inline_64_test"
# wbuild: step="bin/inline_const_inline_64_test" expect_stdout="inline_const_test passed"
# wbuild: step="bin/wv2 x64 --stats tests/inline_const_test.w -o bin/inline_const_stats_test" expect_stderr="constant arguments: "
# Default-on inlining of tiny leaf callees and the binding of constant
# arguments (compiler/inline_table.w, grammar/inline_call.w): without
# any flag, a call to a loop-free leaf whose definition took at most
# inline_budget_tiny bytes is emitted as its body, and a plain 'int'
# parameter the body never writes or takes the address of is bound to
# an integer-literal argument, so the body reads the immediate instead
# of the argument's stack word. Every case asserts a computed value, so
# the test passes whether or not a call was inlined or a parameter
# bound; the extra steps run it with --no-inline (the reference) and
# with --inline, and check that the default build reports constant
# arguments in its --stats. The shapes cover each rule of the
# read-only scan (inline_param_read_only): plain reads, '&&', a write
# by '=', by a compound operator, by '++'/'--' on either side, by a
# shift-assign, by ':=' and a redeclaration, an address taken, a
# parallel assignment, and arguments that are not literals (a ternary,
# a variable, a struct-returning call that leaks its buffer), negative
# and zero literals, nested bodies passing a bound parameter on, and a
# prototype (a definition without a body is no record).
import lib.lib
import lib.assert


int ic_prototype(int a);


# --- reads only: bound when the argument is a literal -----------------------
int ic_clamp(int a):
	if (a < 0): return 0
	return a


int ic_both(int a, int b):
	if ((a > 0) && (b > 0)): return a + b
	return 0


int ic_mix(int a, int b, int c):
	return a + b * c


int ic_shift(int a, int n):
	return a << n


int ic_cmp(int a):
	if (a <= 3): return 1
	if (a >= 9): return 2
	if (a != 5): return 3
	return 4


# Nested: the bound parameter is the next body's constant argument
int ic_outer(int a):
	return ic_clamp(a) + 1


# A narrow parameter is never bound (its word is not its value as read)
int ic_byte(char c):
	return c + 1


# --- writes: never bound ------------------------------------------------------
int ic_assign(int a):
	a = a + 1
	return a


int ic_compound(int a):
	a += 2
	return a


int ic_post(int a):
	a++
	return a


int ic_pre(int a):
	--a
	return a


int ic_shl(int a):
	a <<= 1
	return a


int ic_redeclare(int a):
	if (a > 0):
		int a = 7
		return a
	return a


int ic_addr(int a):
	int* p = &a
	*p = 40
	return a


int ic_swap(int a, int b):
	a, b = b, a
	return a - b


struct ic_pair:
	int x
	int y


ic_pair ic_make(int x):
	ic_pair p
	p.x = x
	p.y = x + 1
	return p


int ic_first(int a, int b):
	return a * 10 + b


int ic_prototype(int a):
	return a - 1


int main():
	assert_equal(0, ic_clamp(-5))
	assert_equal(7, ic_clamp(7))
	assert_equal(0, ic_clamp(0))
	assert_equal(5, ic_both(2, 3))
	assert_equal(0, ic_both(2, -3))
	assert_equal(7, ic_mix(1, 2, 3))
	assert_equal(-5, ic_mix(1, -2, 3))
	assert_equal(40, ic_shift(5, 3))
	assert_equal(1, ic_cmp(3))
	assert_equal(2, ic_cmp(10))
	assert_equal(3, ic_cmp(6))
	assert_equal(4, ic_cmp(5))
	assert_equal(1, ic_outer(-4))
	assert_equal(9, ic_outer(8))
	assert_equal(66, ic_byte(65))
	assert_equal(2, ic_assign(1))
	assert_equal(5, ic_compound(3))
	assert_equal(10, ic_post(9))
	assert_equal(8, ic_pre(9))
	assert_equal(12, ic_shl(6))
	assert_equal(7, ic_redeclare(1))
	assert_equal(-2, ic_redeclare(-2))
	assert_equal(40, ic_addr(3))
	assert_equal(-3, ic_swap(5, 2))
	# Arguments that are not literals
	int v = 4
	assert_equal(4, ic_clamp(v))
	assert_equal(3, ic_clamp(v > 3 ? 3 : -3))
	assert_equal(0, ic_clamp(v < 3 ? 3 : -3))
	ic_pair q = ic_make(2)
	assert_equal(23, ic_first(ic_make(2).x, q.y))
	assert_equal(52, ic_first(5, ic_make(1).y))
	# A literal after an operand parked in a register
	assert_equal(10, v + ic_mix(0, 2, 3))
	assert_equal(6, ic_prototype(7))
	println(c"inline_const_test passed")
	return 0
