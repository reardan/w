import lib.testing
import lib.math


void test_min_max():
	assert_equal(3, min(3, 9))
	assert_equal(9, max(3, 9))
	assert_equal(-9, min(-9, -3))
	assert_equal(-3, max(-9, -3))


void test_abs():
	assert_equal(5, abs(-5))
	assert_equal(5, abs(5))
	assert_equal(0, abs(0))


void test_sign():
	assert_equal(-1, sign(-42))
	assert_equal(0, sign(0))
	assert_equal(1, sign(7))


void test_gcd():
	assert_equal(6, gcd(54, 24))
	assert_equal(6, gcd(24, 54))
	assert_equal(7, gcd(7, 0))
	assert_equal(7, gcd(0, 7))
	assert_equal(0, gcd(0, 0))
	assert_equal(4, gcd(-8, 12))
	assert_equal(1, gcd(17, 13))


void test_pow():
	assert_equal(1, pow(5, 0))
	assert_equal(5, pow(5, 1))
	assert_equal(1024, pow(2, 10))
	assert_equal(-27, pow(-3, 3))
	assert_equal(0, pow(2, -1))
	assert_equal(1, pow(1, 100))
