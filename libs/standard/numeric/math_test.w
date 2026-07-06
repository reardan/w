import lib.testing
import libs.standard.numeric.math


void test_math_gcd_zero_negative_and_symmetry():
	assert_equal(0, math_gcd(0, 0))
	assert_equal(12, math_gcd(0, -12))
	assert_equal(6, math_gcd(54, 24))
	assert_equal(6, math_gcd(24, 54))
	assert_equal(9, math_gcd(-81, 153))


void test_math_lcm_and_overflow_policy():
	assert_equal(0, math_lcm(0, 7))
	assert_equal(42, math_lcm(21, 6))
	assert_equal(42, math_lcm(-21, 6))
	# Positive results that do not fit signed 32-bit int return 0.
	assert_equal(0, math_lcm(50000, 50021))


void test_math_isqrt_edges():
	assert_equal(-1, math_isqrt(-1))
	assert_equal(0, math_isqrt(0))
	assert_equal(1, math_isqrt(1))
	assert_equal(4, math_isqrt(16))
	assert_equal(4, math_isqrt(17))
	assert_equal(46340, math_isqrt(2147483647))


void test_math_comb_samples_and_overflow_policy():
	assert_equal(1, math_comb(5, 0))
	assert_equal(10, math_comb(5, 2))
	assert_equal(120, math_comb(10, 3))
	assert_equal(155117520, math_comb(30, 15))
	assert_equal(0, math_comb(5, 6))
	assert_equal(0, math_comb(-1, 1))
	# 34 choose 17 is 2333606220, beyond signed 32-bit int.
	assert_equal(0, math_comb(34, 17))


void test_math_perm_samples_and_overflow_policy():
	assert_equal(1, math_perm(5, 0))
	assert_equal(20, math_perm(5, 2))
	assert_equal(604800, math_perm(10, 7))
	assert_equal(0, math_perm(4, 5))
	assert_equal(0, math_perm(13, 12))
