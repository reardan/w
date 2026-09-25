import lib.testing
import lib.setjmp
# wbuild: x64 arch=arm64

/*
lib/setjmp.w: setjmp/longjmp under their C names (issue #435).
*/


jmp_buf env
int trace


void mark(int digit):
	trace = trace * 10 + digit


void thrower(int depth, int value):
	if (depth == 0):
		mark(3)
		longjmp(&env, value)
		mark(9)
	int padding = depth * 2
	thrower(depth - 1, value + padding - padding)


void test_setjmp_returns_zero_then_longjmp_value():
	trace = 0
	int r = setjmp(&env)
	if (r == 0):
		mark(1)
		thrower(5, 7)
		mark(8)
	else: mark(4)
	assert_equal(7, r)
	assert_equal(134, trace)


void test_locals_keep_latest_value():
	int attempts = 0
	int r = setjmp(&env)
	attempts = attempts + 1
	if (attempts < 4): thrower(2, attempts)
	assert_equal(4, attempts)
	assert_equal(3, r)


int checked_divide(jmp_buf* e, int a, int b):
	int scratch = a
	if (b == 0): longjmp(e, 1)
	return scratch / b


# A buffer on the stack, and a jump out of a nested helper frame that
# itself has locals
int protected_divide(int a, int b):
	jmp_buf local_env
	if (setjmp(&local_env)): return -1
	return checked_divide(&local_env, a, b)


void test_stack_buffer():
	assert_equal(5, protected_divide(10, 2))
	assert_equal(-1, protected_divide(10, 0))
	# The stack is intact after the jump: calls keep working
	assert_equal(3, protected_divide(9, 3))
