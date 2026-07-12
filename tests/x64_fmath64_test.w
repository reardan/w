# float64 port of fmath_test's coverage (fmath_test itself doesn't exist
# as a standalone file -- fmath is exercised indirectly -- so this follows
# tests/x64_float_test.w's house style instead: exact bit-pattern
# assertions split into lo/hi 32-bit halves, since lib.testing's ELF-symtab
# discovery doesn't work on the x64 backend yet). Golden bits for
# fsqrt64/fmod64 come from a throwaway C generator against glibc (sqrt(),
# and a - floor(a/b)*b for fmod64's glm-style modulo, which is NOT libc's
# fmod: fmod64 takes the sign of the divisor, libc's fmod takes the sign
# of the dividend).
import lib.lib
import lib.assert
import lib.fmath64


void assert_float64_bits(int want_lo, int want_hi, float64 got):
	char* p = &got
	assert_equal_hex(want_lo, load_int32(p))
	assert_equal_hex(want_hi, load_int32(p + 4))


# Like assert_float64_bits but allows the low/high halves, read back
# together as one 64-bit magnitude, to differ by up to max_ulp -- for
# fsqrt64, which is not correctly rounded. Every value compared here is
# positive, so the raw bit pattern orders the same as the value and a
# plain integer subtraction is a valid ulp distance.
void assert_float64_close(int want_lo, int want_hi, float64 got, int max_ulp):
	char* p = &got
	int got_lo = load_int32(p)
	int got_hi = load_int32(p + 4)
	# load_int32 (and a cast(int, ...) literal with bit 31 set) sign-extend
	# on a 64-bit host, so both sides need the same low-32-bits mask before
	# combining into one 64-bit magnitude. (1 << 32) - 1 builds that mask
	# without writing a literal wider than 32 significant bits (see
	# lib/fmath64.w's header comment for why that matters on x64).
	int mask32 = (1 << 32) - 1
	int want_bits = (want_hi << 32) | (want_lo & mask32)
	int got_bits = (got_hi << 32) | (got_lo & mask32)
	int diff = want_bits - got_bits
	if (diff < 0):
		diff = 0 - diff
	if (diff > max_ulp):
		print2(c"Assertion failed: fsqrt64 ulp diff too large. want_hi=")
		print2(hex(want_hi))
		print2(c" want_lo=")
		print2(hex(want_lo))
		print2(c" got_hi=")
		print2(hex(got_hi))
		print2(c" got_lo=")
		print2(hex(got_lo))
		print2(c" diff=")
		println2(itoa(diff))
		print_stack_trace()
		exit(1)


int main(int argc, int argv):
	# -- float64_bits / float64_from_bits: exact bit round-trips --
	assert_float64_bits(0x00000000, 0x3ff80000, 1.5)
	assert_float64_bits(cast(int, 0x9999999a), 0x3fb99999, 0.1)
	assert_float64_bits(0x00000000, cast(int, 0x80000000), -0.0)
	# from_bits(bits(f)) == f for an arbitrary pattern with no special
	# meaning, built from clean 32-bit halves (neither has bit 31 set, so
	# no sign-extension juggling is needed for this one).
	int arbitrary = (0x12345678 << 32) | 0x789abcde
	assert_equal_hex(arbitrary, float64_bits(float64_from_bits(arbitrary)))

	# -- f64is_nan: exponent all ones + mantissa nonzero, on both quiet
	# (top mantissa bit set) and signaling-style (top mantissa bit clear,
	# low bit set) patterns; infinities (mantissa zero) are not NaN --
	int exp_all_ones = 0x7ff << 52
	int quiet_nan = exp_all_ones | (1 << 51)
	int signaling_nan = exp_all_ones | 1
	assert_equal(0, f64is_nan(0.0))
	assert_equal(0, f64is_nan(1.5))
	assert_equal(0, f64is_nan(-3.5))
	assert_equal(1, f64is_nan(float64_from_bits(quiet_nan)))
	assert_equal(1, f64is_nan(float64_from_bits(signaling_nan)))
	assert_equal(0, f64is_nan(float64_from_bits(exp_all_ones)))              /* +inf */
	assert_equal(0, f64is_nan(float64_from_bits((1 << 63) | exp_all_ones)))  /* -inf */

	# -- fabs64: clears the sign bit, including on zero and on NaN (passed
	# through rather than compared, since NaN == NaN is true in W) --
	assert_float64_bits(0x00000000, 0x400c0000, fabs64(-3.5))
	assert_float64_bits(0x00000000, 0x400c0000, fabs64(3.5))
	assert_float64_bits(0x00000000, 0x00000000, fabs64(-0.0))
	int negative_nan = (1 << 63) | quiet_nan
	assert_equal_hex(quiet_nan, float64_bits(fabs64(float64_from_bits(negative_nan))))

	# -- ffloor64: largest whole value not above f --
	assert_float64_bits(0x00000000, 0x40080000, ffloor64(3.7))    /* 3.0 */
	assert_float64_bits(0x00000000, cast(int, 0xc0100000), ffloor64(-3.7))  /* -4.0 */
	assert_float64_bits(0x00000000, cast(int, 0xc0080000), ffloor64(-3.0))  /* -3.0, already whole */
	assert_float64_bits(0x00000000, 0x40080000, ffloor64(3.0))    /* 3.0, already whole */
	assert_float64_bits(0x00000000, 0x00000000, ffloor64(0.0))

	# -- fmod64: glm-style a - floor(a / b) * b, sign of the result follows
	# b (the divisor), unlike libc fmod which follows a (the dividend) --
	assert_float64_bits(0x00000000, 0x3ff80000, fmod64(5.5, 2.0))    /* 1.5 */
	assert_float64_bits(0x00000000, 0x3fe00000, fmod64(-5.5, 2.0))   /* 0.5, sign of +b */
	assert_float64_bits(0x00000000, cast(int, 0xbfe00000), fmod64(5.5, -2.0))  /* -0.5, sign of -b */
	assert_float64_bits(cast(int, 0x999999a0), 0x3fc99999, fmod64(1.1, 0.3))
	assert_float64_bits(0x00000000, 0x3ff00000, fmod64(10.0, 3.0))   /* 1.0 */
	assert_float64_bits(0x00000000, 0x00000000, fmod64(-7.5, 2.5))   /* 0.0 exactly */
	assert_float64_bits(cast(int, 0x999999a0), cast(int, 0xbfc99999), fmod64(-1.1, -0.3))

	# -- fsqrt64: exact on perfect squares and powers of two with an even
	# exponent, <= 1 ulp elsewhere (golden bits from glibc sqrt(), gcc -O0
	# -fno-fast-math) --
	assert_float64_bits(0x00000000, 0x40000000, fsqrt64(4.0))     /* 2.0, exact */
	assert_float64_bits(0x00000000, 0x40080000, fsqrt64(9.0))     /* 3.0, exact */
	assert_float64_close(0x667f3bcd, 0x3ff6a09e, fsqrt64(2.0), 1)
	assert_float64_close(cast(int, 0xe8584caa), 0x3ffbb67a, fsqrt64(3.0), 1)
	assert_float64_close(cast(int, 0xb16948f6), 0x4075f5d3, fsqrt64(123456.789), 1)
	assert_float64_bits(0x00000000, 0x40f86a00, fsqrt64(1e10))    /* 100000.0, exact */
	assert_float64_close(cast(int, 0x88e368f1), 0x3ee4f8b5, fsqrt64(1e-10), 1)
	assert_float64_close(cast(int, 0xffffffff), 0x5fefffff, fsqrt64(1.7976931348623157e308), 1)  /* sqrt(DBL_MAX) */
	assert_float64_bits(0x00000000, 0x20000000, fsqrt64(2.2250738585072014e-308))  /* sqrt(DBL_MIN), exact: 2^-511 */
	assert_float64_bits(0x00000000, 0x00000000, fsqrt64(0.0))
	assert_float64_bits(0x00000000, 0x00000000, fsqrt64(-4.0))    /* negative input convention, like fsqrt */

	println(c"x64 fmath64 OK")
	return 0
