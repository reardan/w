# wbuild: x64
import lib.testing
import lib.format
import lib.fmath


# Same tolerance as graphics/math_test.w: well within what float32
# callers need, loose enough to absorb iteration truncation.
void assert_near(float want, float got):
	if (fabs(want - got) > 0.0001):
		print2(c"Assertion failed. wanted float(")
		print2(ftoa(want))
		print2(c") got float(")
		print2(ftoa(got))
		println2(c")")
		exit(1)


void assert_float_bits(int want, float got):
	assert_equal_hex(want, float_bits(got))


void test_float_bits():
	assert_equal_hex(0x3f800000, float_bits(1.0))
	assert_equal_hex(0x40000000, float_bits(2.0))
	assert_equal_hex(cast(int, 0xbfc00000), float_bits(-1.5))
	assert_equal_hex(0x00000000, float_bits(0.0))


void test_float_from_bits():
	assert_near(3.1415927, float_from_bits(0x40490fdb))
	assert_float_bits(0x3f800000, float_from_bits(0x3f800000))
	# round trip through both directions
	assert_float_bits(cast(int, 0xc2280000), float_from_bits(float_bits(-42.0)))
	assert_near(0.5, float_from_bits(float_bits(0.5)))


void test_fis_nan():
	assert_equal(1, fis_nan(float_from_bits(0x7fc00000)))    # quiet NaN
	assert_equal(1, fis_nan(float_from_bits(0x7f800001)))    # signaling NaN
	assert_equal(1, fis_nan(float_from_bits(cast(int, 0xffc00000))))    # negative NaN
	assert_equal(0, fis_nan(float_from_bits(0x7f800000)))    # +inf
	assert_equal(0, fis_nan(float_from_bits(cast(int, 0xff800000))))    # -inf
	assert_equal(0, fis_nan(0.0))
	assert_equal(0, fis_nan(1.5))
	assert_equal(0, fis_nan(-1.5))


void test_fabs():
	assert_float_bits(0x3fc00000, fabs(-1.5))
	assert_float_bits(0x3fc00000, fabs(1.5))
	assert_float_bits(0x00000000, fabs(0.0))
	# negative zero: the sign bit clears
	assert_float_bits(0x00000000, fabs(float_from_bits(cast(int, 0x80000000))))
	# NaN passes through with the sign bit cleared, no comparison involved
	assert_float_bits(0x7fc00000, fabs(float_from_bits(cast(int, 0xffc00000))))


void test_ffloor():
	assert_float_bits(0x40000000, ffloor(2.75))      # 2.0
	assert_float_bits(cast(int, 0xc0400000), ffloor(-2.25))     # floor(-2.25) = -3
	assert_float_bits(0x40a00000, ffloor(5.0))       # already whole
	assert_float_bits(cast(int, 0xc0400000), ffloor(-3.0))
	assert_float_bits(0x00000000, ffloor(0.5))


void test_fmod2():
	assert_near(1.0, fmod2(7.0, 3.0))
	assert_near(2.0, fmod2(-7.0, 3.0))    # glm mod keeps the divisor's sign
	assert_near(0.5, fmod2(8.0, 2.5))
	assert_near(0.0, fmod2(9.0, 3.0))


void test_fsqrt():
	assert_near(2.0, fsqrt(4.0))
	assert_near(1.5, fsqrt(2.25))
	assert_near(12.0, fsqrt(144.0))
	assert_near(0.1, fsqrt(0.01))
	assert_near(31.622776, fsqrt(1000.0))
	assert_float_bits(0x00000000, fsqrt(0.0))
	assert_float_bits(0x00000000, fsqrt(-4.0))
