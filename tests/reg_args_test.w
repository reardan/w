# Register arguments for direct calls (unit O5, compiler/regalloc_scan.w's
# "register arguments" section): on x64 a direct call to a W function
# that published a register entry passes its arguments in the
# parameters' registers; everything else keeps the stack ABI. Each
# result is checked, and the same program built with --no-reg-args and
# with --streaming (the extra steps) must pass too.
# wbuild: x64
# wbuild: step="bin/wv2 x64 --no-reg-args tests/reg_args_test.w -o bin/reg_args_stack_64_test"
# wbuild: step="bin/reg_args_stack_64_test"
# wbuild: step="bin/wv2 x64 --streaming tests/reg_args_test.w -o bin/reg_args_streaming_64_test"
# wbuild: step="bin/reg_args_streaming_64_test"
import lib.assert


# leaf callees: every parameter in a region register. The region only
# takes a name that a register makes shorter (compiler/regalloc_scan.w's
# rs_gain: compare left sides, subscript bases, ...), so each parameter
# is range-checked twice.
const int big = 1000000


int add3(int a, int b, int c):
	if ((a < -big) || (b < -big) || (c < -big)): return 0
	if ((a > big) || (b > big) || (c > big)): return 0
	return a * 100 + b * 10 + c


int pick(char* s, int i):
	if (i < 0): return 0
	if (i > big): return 0
	return s[i] + s[i] - s[i]


int six(int a, int b, int c, int d, int e, int f):
	if ((a < -big) || (b < -big) || (c < -big) || (d < -big) || (e < -big) || (f < -big)): return 0
	if ((a > big) || (b > big) || (c > big) || (d > big) || (e > big) || (f > big)): return 0
	return a + b * 2 + c * 3 + d * 4 + e * 5 + f * 6


int swap_sub(int a, int b):
	if ((a < -big) || (b < -big)): return 0
	if ((a > big) || (b > big)): return 0
	return a - b


int one(int x):
	if (x < -big): return 0
	if (x > big): return 0
	return x + 1


# a loop inside the leaf: its parameters go to the loop's registers
# (R3), not the function region, so it keeps the stack ABI
int sum_to(int* p, int n):
	int t = 0
	int i = 0
	while (i < n):
		t = t + p[i]
		i = i + 1
	return t


# not register-shaped: a narrow parameter, a struct return, an
# address-taken parameter, an unused parameter, a call inside
int narrow(int32 a, int b):
	return a + b


struct pair:
	int x
	int y


pair make_pair(int a, int b):
	pair p
	p.x = a
	p.y = b
	return p


int addr_taken(int a):
	int* p = &a
	return *p + 1


int unused(int a, int b):
	return a


int calls_inside(int a, int b):
	return one(a) + one(b)


int side_count


int bump(int v):
	side_count = side_count + v
	return side_count


# a self call keeps the stack ABI (the entry is published at the end)
int fact(int n):
	if (n <= 1): return 1
	return n * fact(n - 1)


# called before its definition: the stack ABI
int later(int a, int b);


int use_later():
	return later(7, 8)


int later(int a, int b):
	return a * b


# a call only in a branch: the region spills the parameters to their
# homes around it, frame words below the saved registers in both entries
int guarded(int a, int b):
	if ((a < -big) || (b < -big)): return 0
	if ((a > big) || (b > big)): return 0
	int t = a * 10 + b
	if (t > 100): t = t + calls_inside(a, b)
	return t + a - b


type ra_unary = fn(int) -> int


int apply(ra_unary* f, int x):
	return f(x)


void test_simple():
	assert_equal(123, add3(1, 2, 3))
	int x = 4
	int y = 5
	assert_equal(456, add3(x, y, x + 2))
	assert_equal(98, pick(c"abc", 1))
	assert_equal(1*1 + 2*2 + 3*3 + 4*4 + 5*5 + 6*6, six(1, 2, 3, 4, 5, 6))
	assert_equal(3, one(2))


# arguments whose evaluation moves parked registers around: nested
# calls (a register call inside an argument spills the earlier parks),
# the parameters' registers already holding other arguments
void test_nested():
	assert_equal(add3(1, 2, 3) - 1, swap_sub(add3(1, 2, 3), 1))
	assert_equal(-1, swap_sub(swap_sub(1, 2), 0))
	assert_equal(1, swap_sub(2, swap_sub(2, 1)))
	assert_equal(add3(add3(0, 0, 1), add3(0, 0, 2), add3(0, 0, 3)), 123)
	int a = 3
	int b = 9
	assert_equal(6, swap_sub(b, a))
	assert_equal(-6, swap_sub(a, b))
	assert_equal(10 + one(one(one(1))), 14)
	assert_equal(5 * one(4) + add3(1, one(1), 3), 5 * 5 + 123)


# evaluation order: left to right, side effects included
void test_order():
	side_count = 0
	assert_equal(1 * 100 + 3 * 10 + 6, add3(bump(1), bump(2), bump(3)))
	assert_equal(6, side_count)


# a caller with loop-owned registers around a register call
void test_loop():
	int[8] buf
	for i in range(8): buf[i] = i + 1
	int total = 0
	int i = 0
	while (i < 8):
		total = total + swap_sub(buf[i], i) + one(i)
		i = i + 1
	assert_equal(8 + 36, total)
	assert_equal(36, sum_to(&buf[0], 8))
	int k = 0
	int acc = 0
	while (k < 100):
		acc = acc + add3(k, k + 1, k + 2) - six(k, 1, 1, 1, 1, 1)
		k = k + 1
	int expect = 0
	for j in range(100): expect = expect + (j * 100 + (j + 1) * 10 + j + 2) - (j + 2 + 3 + 4 + 5 + 6)
	assert_equal(expect, acc)


void test_not_shaped():
	assert_equal(7, narrow(3, 4))
	pair p = make_pair(5, 6)
	assert_equal(11, p.x + p.y)
	assert_equal(6, addr_taken(5))
	assert_equal(9, unused(9, 10))
	assert_equal(5, calls_inside(1, 2))
	assert_equal(12 + 1 - 2, guarded(1, 2))
	assert_equal(200 + 3 + 25 + 20 - 3, guarded(20, 3))
	assert_equal(110 + 1 + 14 + 11 - 1, guarded(guarded(1, 2), 1))
	assert_equal(120, fact(5))
	assert_equal(56, use_later())
	assert_equal(56, later(7, 8))
	# through a function value: the stack ABI at the function's address
	assert_equal(10, apply(one, 9))
	ra_unary* f = one
	assert_equal(12, f(11))


int main():
	test_simple()
	test_nested()
	test_order()
	test_loop()
	test_not_shaped()
	println(c"reg_args_test: ok")
	return 0
