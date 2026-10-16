# wbuild: x64
# wbuild: step="bin/intmath_test" env="W_TEST_LEAKS=1" expect_stdout="0 failed, 0 skipped [leak check]"
# Expected values are Python 3 math.factorial/comb/perm/isqrt results.
# Values wider than 31 bits are assembled at run time by dec3(): the
# compiler's tokenizer keeps integer literals to 32 bits on every target.
import lib.testing
import libs.standard.numeric.intmath


# (a * 10^6 + b) * 10^6 + c, for writing 64-bit expectations.
int dec3(int a, int b, int c):
	return (a * 1000000 + b) * 1000000 + c


int is64():
	return __word_size__ == 8


void test_int_max():
	if (is64()):
		assert_equal(dec3(9223372, 36854, 775807), math_int_max())
	else:
		assert_equal(2147483647, math_int_max())


void test_checked_mul():
	assert_equal(0, math_checked_mul(0, math_int_max()))
	assert_equal(math_int_max(), math_checked_mul(1, math_int_max()))
	assert_equal(-1, math_checked_mul(2, math_int_max()))
	assert_equal(-1, math_checked_mul(-1, 5))
	assert_equal(2147483646, math_checked_mul(1073741823, 2))
	if (is64() == 0):
		assert_equal(-1, math_checked_mul(46341, 46341))
	assert_equal(2147395600, math_checked_mul(46340, 46340))


void test_factorial():
	assert_equal(1, math_factorial(0))
	assert_equal(1, math_factorial(1))
	assert_equal(120, math_factorial(5))
	assert_equal(479001600, math_factorial(12))
	assert_equal(-1, math_factorial(-1))
	if (is64()):
		assert_equal(dec3(0, 6227, 20800), math_factorial(13))
		assert_equal(dec3(2432902, 8176, 640000), math_factorial(20))
		assert_equal(-1, math_factorial(21))
	else:
		assert_equal(-1, math_factorial(13))
	assert_equal(-1, math_factorial(1000))


void test_comb():
	assert_equal(1, math_comb(0, 0))
	assert_equal(1, math_comb(5, 0))
	assert_equal(1, math_comb(5, 5))
	assert_equal(10, math_comb(5, 2))
	assert_equal(0, math_comb(3, 4))
	assert_equal(-1, math_comb(-1, 0))
	assert_equal(-1, math_comb(5, -1))
	assert_equal(155117520, math_comb(30, 15))
	assert_equal(601080390, math_comb(32, 16))
	assert_equal(1855967520, math_comb(34, 15))
	assert_equal(499500, math_comb(1000, 2))
	if (is64()):
		# C(n, k) stays exact up to the last value that fits
		assert_equal(dec3(0, 2203, 961430), math_comb(34, 16))
		assert_equal(dec3(7219428, 434016, 265740), math_comb(66, 33))
		assert_equal(-1, math_comb(67, 33))
		assert_equal(dec3(0, 499999, 500000), math_comb(1000000, 2))
		assert_equal(dec3(2305843, 5992, 468481), math_comb(2147483647, 2))
	else:
		assert_equal(-1, math_comb(34, 16))
		assert_equal(-1, math_comb(1000000, 2))
	# symmetric: comb(n, k) == comb(n, n - k)
	assert_equal(math_comb(30, 7), math_comb(30, 23))


void test_perm():
	assert_equal(1, math_perm(5, 0))
	assert_equal(720, math_perm(10, 3))
	assert_equal(120, math_perm(5, 5))
	assert_equal(0, math_perm(3, 4))
	assert_equal(-1, math_perm(-2, 1))
	assert_equal(-1, math_perm(2, -1))
	assert_equal(479001600, math_perm(12, 12))
	assert_equal(2147483647, math_perm(2147483647, 1))
	assert_equal(2147349260, math_perm(46340, 2))
	if (is64()):
		assert_equal(dec3(2432902, 8176, 640000), math_perm(20, 20))
		assert_equal(-1, math_perm(21, 21))
	else:
		assert_equal(-1, math_perm(13, 12))
		assert_equal(-1, math_perm(46342, 2))
		assert_equal(2147441940, math_perm(46341, 2))


void test_isqrt():
	assert_equal(0, math_isqrt(0))
	assert_equal(1, math_isqrt(1))
	assert_equal(1, math_isqrt(3))
	assert_equal(2, math_isqrt(4))
	assert_equal(9, math_isqrt(99))
	assert_equal(10, math_isqrt(100))
	assert_equal(46340, math_isqrt(2147483647))
	assert_equal(46340, math_isqrt(2147395600))
	assert_equal(46339, math_isqrt(2147395599))
	assert_equal(-1, math_isqrt(-1))
	if (is64()):
		assert_equal(dec3(0, 3037, 499), math_isqrt(math_int_max()))
		assert_equal(1000000000, math_isqrt(dec3(1000000, 0, 0)))
		assert_equal(999999999, math_isqrt(dec3(1000000, 0, 0) - 1))


void test_isqrt_exhaustive_small():
	int n = 0
	while (n < 20000):
		int r = math_isqrt(n)
		assert1(r * r <= n)
		assert1((r + 1) * (r + 1) > n)
		n = n + 1
