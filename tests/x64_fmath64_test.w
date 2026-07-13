# float64 port of fmath_test's coverage (fmath_test itself doesn't exist
# as a standalone file -- fmath is exercised indirectly -- so this follows
# tests/x64_float_test.w's house style instead: exact bit-pattern
# assertions split into lo/hi 32-bit halves, since lib.testing's ELF-symtab
# discovery doesn't work on the x64 backend yet). Golden bits for
# fsqrt64/fmod64 come from a throwaway C generator against glibc (sqrt(),
# and a - floor(a/b)*b for fmod64's glm-style modulo, which is NOT libc's
# fmod: fmod64 takes the sign of the divisor, libc's fmod takes the sign
# of the dividend).
#
# The transcendental section below asserts three layers, mirroring what
# fmath's float32 work asserted and lib/fmath64.w's headers claim:
# - decimal-literal round-trips for every precision-critical constant the
#   library builds its split arithmetic from (the algorithm depends on
#   their exact bit patterns, e.g. the trailing-zero words of the Dekker
#   splits and the Cody-Waite pi/2 parts);
# - golden ulp bounds: expected bits from glibc's double functions
#   (throwaway C generator, gcc -O0 -fno-fast-math -ffp-contract=off),
#   tolerance = the sweep-measured bound + 1, per function and domain;
#   the W build was proven bit-identical to the swept C model on a
#   37k-point deterministic grid, so these tolerances are not guesses;
# - the edge-case ladders, bit-exactly (each verified equal to glibc's
#   own edge behavior by the same C harness, NaN payloads aside).
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


# Map a float64 bit pattern to an integer that orders like the value it
# encodes (sign-corrected ordering: negatives count down from zero), so
# subtracting two mapped patterns is a true ulp distance even across the
# +-0 boundary. Never fed NaNs -- those are asserted bit-exactly.
int f64_ord(int bits):
	if (bits < 0):
		return 0 - (bits & ((1 << 63) - 1))
	return bits


# Assert got is within max_ulp of the golden bit pattern, given as lo/hi
# 32-bit halves like assert_float64_bits. The failure print uses
# hex_word, not itoa: a wildly wrong result (e.g. an infinity where a
# finite value was expected) makes diff too large for itoa's buffer.
void assert_f64_ulp(int want_lo, int want_hi, float64 got, int max_ulp):
	int mask32 = (1 << 32) - 1
	int want_bits = (want_hi << 32) | (want_lo & mask32)
	int diff = f64_ord(want_bits) - f64_ord(float64_bits(got))
	if (diff < 0):
		diff = 0 - diff
	if (diff > max_ulp):
		print2(c"Assertion failed: f64 ulp diff too large. want=")
		print2(hex_word(want_bits))
		print2(c" got=")
		print2(hex_word(float64_bits(got)))
		print2(c" diff=")
		println2(hex_word(diff))
		print_stack_trace()
		exit(1)


# Like assert_f64_ulp but between two computed float64s, for identity
# checks where both sides went through the library.
void assert_f64_close2(float64 want, float64 got, int max_ulp):
	int diff = f64_ord(float64_bits(want)) - f64_ord(float64_bits(got))
	if (diff < 0):
		diff = 0 - diff
	if (diff > max_ulp):
		print2(c"Assertion failed: f64 identity diff too large. want=")
		print2(hex_word(float64_bits(want)))
		print2(c" got=")
		print2(hex_word(float64_bits(got)))
		print2(c" diff=")
		println2(hex_word(diff))
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

	########## transcendentals ##########

	# -- decimal-literal round-trips for every constant whose exact bit
	# pattern the library's split arithmetic depends on (lib/fmath64.w
	# builds them as bare decimal literals; a parser off by one ulp here
	# would silently break the exact-product invariants) --
	assert_float64_bits(0x00000000, 0x3ff71547, 1.4426946640014648e+00)    /* l2eh */
	assert_float64_bits(cast(int, 0xbf85ddf4), 0x3e994ae0, 3.7688749856360991e-07)    /* l2el */
	assert_float64_bits(0x652b82fe, 0x3ff71547, 1.4426950408889634e+00)    /* l2e */
	assert_float64_bits(0x00000000, 0x3fe62e42, 6.9314670562744141e-01)    /* ln2h */
	assert_float64_bits(0x3de6af28, 0x3e9fdf47, 4.7493250390316726e-07)    /* ln2l */
	assert_float64_bits(cast(int, 0xfefa39ef), 0x3fe62e42, 6.9314718055994529e-01)    /* ln2 */
	assert_float64_bits(0x00000000, 0x3fd34413, 3.0102992057800293e-01)    /* lgh */
	assert_float64_bits(0x7fbcc47c, 0x3e7427de, 7.5085978265526235e-08)    /* lgl */
	assert_float64_bits(0x509f79ff, 0x3fd34413, 3.0102999566398120e-01)    /* lg */
	assert_float64_bits(0x00000000, 0x3feec709, 9.6179628372192383e-01)    /* cph */
	assert_float64_bits(0x7fae93f8, 0x3e9b8740, 4.1020405177678161e-07)    /* cpl */
	assert_float64_bits(cast(int, 0xdc3a03fd), 0x3feec709, 9.6179669392597555e-01)    /* cp */
	assert_float64_bits(0x667f3bcd, 0x3ff6a09e, 1.4142135623730951e+00)    /* sqrt2 */
	assert_float64_bits(0x6dc9c883, 0x3fe45f30, 6.3661977236758138e-01)    /* 2/pi */
	assert_float64_bits(0x00000000, 0x3ff921fb, 1.5707960128784180e+00)    /* pi/2 p1 */
	assert_float64_bits(0x00000000, 0x3e95110b, 3.1391641641675960e-07)    /* pi/2 p2 */
	assert_float64_bits(cast(int, 0x80000000), 0x3d318469, 6.2233719696699885e-14)    /* pi/2 p3 */
	assert_float64_bits(0x2e037073, 0x3ba3198a, 2.0222662487959506e-21)    /* pi/2 p4 */
	assert_float64_bits(0x54442d18, 0x3ff921fb, 1.5707963267948966e+00)    /* pi/2 */
	assert_float64_bits(0x33145c07, 0x3c91a626, 6.1232339957367660e-17)    /* pi/2 lo */
	assert_float64_bits(0x54442d18, 0x400921fb, 3.1415926535897931e+00)    /* pi */
	assert_float64_bits(0x33145c07, 0x3ca1a626, 1.2246467991473532e-16)    /* pi lo */
	assert_float64_bits(0x7f3321d2, 0x4002d97c, 2.3561944901923448e+00)    /* 3pi/4 */
	assert_float64_bits(0x54442d18, 0x3fe921fb, 7.8539816339744828e-01)    /* pi/4 */
	assert_float64_bits(0x333f9de6, 0x4003504f, 2.4142135623730949e+00)    /* tan(3pi/8) */
	assert_float64_bits(cast(int, 0x99fcef32), 0x3fda8279, 4.1421356237309503e-01)    /* tan(pi/8) */
	assert_float64_bits(0x00000000, 0x43400000, 9007199254740992.0)    /* 2^53 */
	assert_float64_bits(0x00000000, 0x43500000, 18014398509481984.0)    /* 2^54 */
	assert_float64_bits(0x55555555, cast(int, 0xbfc55555), -1.6666666666666666e-01)    /* sin s1 */

	# -- fexp264 golden (glibc exp2, tolerance = measured 1 + 1) --
	assert_f64_ulp(0x667f3bcd, 0x3ff6a09e, fexp264(0.5), 2)    /* 1.4142135623730951 */
	assert_f64_ulp(0x667f3bcd, 0x3fe6a09e, fexp264(-0.5), 2)    /* 0.70710678118654757 */
	assert_f64_ulp(cast(int, 0xbcce533e), 0x4029fdf8, fexp264(3.7), 2)    /* 12.996038341699769 */
	assert_f64_ulp(cast(int, 0xbcce533a), 0x3f49fdf8, fexp264(-10.3), 2)    /* 7.9321523081663588e-4 */
	assert_f64_ulp(0x0a31b715, 0x463306fe, fexp264(100.25), 2)    /* 1.5074991131288803e+30 */
	assert_f64_ulp(0x53b9530f, 0x01651cb4, fexp264(-1000.6), 2)    /* 6.1572436372575722e-302 */
	assert_f64_ulp(cast(int, 0xbcce5424), 0x7fe9fdf8, fexp264(1023.7), 2)    /* 1.4601805567051154e+308 */
	assert_f64_ulp(0x00000001, 0x00000000, fexp264(-1074.3), 2)    /* 4.9e-324, smallest subnormal */
	assert_f64_ulp(cast(int, 0xaf2c3dba), 0x3ff00048, fexp264(0.0001), 2)    /* 1.0000693171203765 */

	# -- fexp64 golden (glibc exp, tolerance = measured 1 + 1) --
	assert_f64_ulp(cast(int, 0x8b145769), 0x4005bf0a, fexp64(1.0), 2)    /* e */
	assert_f64_ulp(0x362cef38, 0x3fd78b56, fexp64(-1.0), 2)    /* 0.36787944117144233 */
	assert_f64_ulp(cast(int, 0x8e1e069c), 0x3ffa6129, fexp64(0.5), 2)    /* 1.6487212707001282 */
	assert_f64_ulp(0x15e84d3b, 0x40e1bb70, fexp64(10.5), 2)    /* 36315.502674246636 */
	assert_f64_ulp(0x1e27ca3b, 0x3e1b93de, fexp64(-20.25), 2)    /* 1.6052280551856116e-09 */
	assert_f64_ulp(0x4b52d0c9, 0x7fe81e9b, fexp64(709.5), 2)    /* 1.3549863193146328e+308 */
	assert_f64_ulp(0x00000001, 0x00000000, fexp64(-745.0), 2)    /* 4.9e-324, smallest subnormal */
	assert_f64_ulp(0x0044b830, 0x3ff00000, fexp64(1e-9), 2)    /* 1.0000000010000001 */

	# -- flog264 golden (glibc log2, tolerance = measured 1 + 1) --
	assert_f64_ulp(cast(int, 0xa39fbd68), 0x3ff95c01, flog264(3.0), 2)    /* 1.5849625007211561 */
	assert_f64_ulp(0x28967d13, cast(int, 0xbfe07762), flog264(0.7), 2)    /* -0.51457317282975834 */
	assert_f64_ulp(cast(int, 0x9f1a8b89), 0x408f24a0, flog264(1e300), 2)    /* 996.57842846620872 */
	assert_f64_ulp(cast(int, 0x9f1a8b89), cast(int, 0xc08f24a0), flog264(1e-300), 2)    /* -996.57842846620872 */
	assert_f64_ulp(cast(int, 0xea5fccb7), 0x3e835d0f, flog264(1.0000001), 2)    /* 1.4426949695965583e-07 */
	assert_f64_ulp(cast(int, 0xff971811), cast(int, 0xc090c1a8), flog264(float64_from_bits(3)), 2)    /* subnormal in: -1072.4150374992789 */

	# -- flog64 golden (glibc log, tolerance = measured 1 + 1) --
	assert_f64_ulp(cast(int, 0xfefa39ef), 0x3fe62e42, flog64(2.0), 2)    /* ln 2 */
	assert_f64_ulp(cast(int, 0xbbb55516), 0x40026bb1, flog64(10.0), 2)    /* 2.3025850929940459 */
	assert_f64_ulp(cast(int, 0xbbb55515), cast(int, 0xc0026bb1), flog64(0.1), 2)    /* -2.3025850929940455 */
	assert_f64_ulp(cast(int, 0xd5d62a5e), 0x40862991, flog64(1e308), 2)    /* 709.19620864216608 */
	assert_f64_ulp(cast(int, 0xdd7abcd2), cast(int, 0xc086232b), flog64(2.2250738585072014e-308), 2)    /* ln DBL_MIN */
	assert_f64_ulp(cast(int, 0xecbf984c), 0x3fd9f323, flog64(1.5), 2)    /* 0.40546510810816438 */

	# -- flog1064 golden (glibc log10, tolerance = measured 2 + 1) --
	assert_f64_ulp(0x509f79ff, 0x3fd34413, flog1064(2.0), 3)    /* 0.3010299956639812 */
	assert_f64_ulp(0x00000000, 0x40080000, flog1064(1000.0), 3)    /* 3.0 */
	assert_f64_ulp(0x00000000, cast(int, 0xc0080000), flog1064(0.001), 3)    /* -3.0 */
	assert_f64_ulp(cast(int, 0x92374dd5), 0x3feb87e3, flog1064(7.25), 3)    /* 0.86033800657099369 */

	# -- fpow64 golden (glibc pow, tolerance = measured 1 + 1) --
	assert_f64_ulp(0x00000000, 0x40900000, fpow64(2.0, 10.0), 2)    /* 1024.0 */
	assert_f64_ulp(cast(int, 0xd2f1a9fc), 0x3f50624d, fpow64(10.0, -3.0), 2)    /* 0.001 */
	assert_f64_ulp(cast(int, 0x8771be68), 0x400b7ec1, fpow64(1.0000001, 12345678.0), 2)    /* 3.4368925649248929 */
	assert_f64_ulp(0x667f3bcd, 0x3ff6a09e, fpow64(2.0, 0.5), 2)    /* sqrt(2) */
	assert_f64_ulp(cast(int, 0xd8cd9f64), 0x3aff4ca8, fpow64(0.3, 45.5), 2)    /* 1.6181437113020293e-24 */
	assert_f64_ulp(0x00000000, cast(int, 0xc0200000), fpow64(-2.0, 3.0), 2)    /* -8.0 */
	assert_f64_ulp(0x00000000, 0x40300000, fpow64(-2.0, 4.0), 2)    /* 16.0 */
	assert_f64_ulp(0x2c2ff804, 0x5986382d, fpow64(1.5, 700.0), 2)    /* 1.8360366198426334e+123 */
	assert_f64_ulp(0x00000001, 0x00000000, fpow64(2.0, -1074.5), 2)    /* subnormal out */
	assert_f64_ulp(0x32373620, 0x3fd78b56, fpow64(0.99999999, 1e8), 2)    /* 0.36787943748353946 */

	# -- fsin64 golden (glibc sin; tolerance = measured 1 + 1 for
	# |x| <= 100, measured 2 + 1 beyond) --
	assert_f64_ulp(0x744b05f0, 0x3fdeaee8, fsin64(0.5), 2)    /* 0.47942553860420301 */
	assert_f64_ulp(cast(int, 0x8f090cee), 0x3feaed54, fsin64(1.0), 2)    /* 0.8414709848078965 */
	assert_f64_ulp(0x0dcfcab1, cast(int, 0xbfe326af), fsin64(-2.5), 2)    /* -0.59847214410395655 */
	assert_f64_ulp(cast(int, 0xf7fd16df), cast(int, 0xbfef0a38), fsin64(10.75), 2)    /* -0.96999786792067855 */
	assert_f64_ulp(0x33470ff1, cast(int, 0xbf9fb3f8), fsin64(100.5), 2)    /* -0.030959966783271346 */
	assert_f64_ulp(0x633145c0, 0x3ced1a62, fsin64(3.14159265358979), 2)    /* near-pi cancellation: 3.23e-15 */
	assert_f64_ulp(0x56f648b8, cast(int, 0xbfbb7bbd), fsin64(1000000.25), 3)    /* -0.10735686657997945 */
	assert_f64_ulp(0x62e20b07, cast(int, 0xbfedcd9f), fsin64(2500000000.5), 3)    /* -0.93135041535455876 */

	# -- fcos64 golden (glibc cos, tolerance = measured 2 + 1) --
	assert_f64_ulp(0x065b7d50, 0x3fec1528, fcos64(0.5), 3)    /* 0.87758256189037276 */
	assert_f64_ulp(0x0fb5068c, 0x3fe14a28, fcos64(1.0), 3)    /* 0.54030230586813977 */
	assert_f64_ulp(cast(int, 0xef858b7d), cast(int, 0xbfe9a2f7), fcos64(-2.5), 3)    /* -0.8011436155469337 */
	assert_f64_ulp(0x338f22e5, cast(int, 0xbfcf1e57), fcos64(10.75), 3)    /* -0.24311342256103 */
	assert_f64_ulp(cast(int, 0xadaecec2), 0x3feffc12, fcos64(100.5), 3)    /* 0.99952062532835151 */
	assert_f64_ulp(0x33145c07, 0x3c91a626, fcos64(1.5707963267948966), 3)    /* cos(pi/2 rounded) = 6.12e-17 */
	assert_f64_ulp(cast(int, 0x9db83ee8), 0x3fefd0a7, fcos64(1000000.25), 3)    /* 0.99422055058127246 */
	assert_f64_ulp(0x6b9b8c61, 0x3fd74dcf, fcos64(2500000000.5), 3)    /* 0.36412415989452113 */

	# -- ftan64 golden (glibc tan; tolerance = measured 3 + 1 for
	# |x| <= 100, measured 4 + 1 beyond) --
	assert_f64_ulp(0x5bf3474a, 0x3fe17b4f, ftan64(0.5), 4)    /* 0.54630248984379048 */
	assert_f64_ulp(0x5cbee3a6, 0x3ff8eb24, ftan64(1.0), 4)    /* 1.5574077246549023 */
	assert_f64_ulp(0x4e00bb15, 0x3fe7e79b, ftan64(-2.5), 4)    /* 0.74702229723866032 */
	assert_f64_ulp(cast(int, 0xe0f2d081), 0x400feb4f, ftan64(10.75), 4)    /* 3.989898450288877 */
	assert_f64_ulp(cast(int, 0xab49130d), cast(int, 0xbf9fb7dc), ftan64(100.5), 4)    /* -0.030974815325197236 */
	assert_f64_ulp(cast(int, 0xffffffff), 0x3fefffff, ftan64(0.7853981633974483), 4)    /* tan(pi/4 rounded) */
	assert_f64_ulp(cast(int, 0x80c33a62), cast(int, 0xbfbba4a3), ftan64(1000000.25), 5)    /* -0.10798093694322966 */
	assert_f64_ulp(cast(int, 0xb00d2f7a), cast(int, 0xc0047656), ftan64(2500000000.5), 5)    /* -2.5577825311683542 */

	# -- fatan64 golden (glibc atan, tolerance = measured 2 + 1) --
	assert_f64_ulp(0x661eaf06, 0x3fd2a73a, fatan64(0.3), 3)    /* 0.2914567944778671 */
	assert_f64_ulp(0x54442d18, 0x3fe921fb, fatan64(1.0), 3)    /* pi/4 */
	assert_f64_ulp(cast(int, 0xf9403197), cast(int, 0xbff7030c), fatan64(-7.5), 3)    /* -1.4382447944982226 */
	assert_f64_ulp(cast(int, 0x88e06854), 0x3ee4f8b5, fatan64(1e-5), 3)    /* 9.9999999996666679e-06 */
	assert_f64_ulp(0x54442d18, 0x3ff921fb, fatan64(1e300), 3)    /* pi/2 */
	assert_f64_ulp(0x54442d18, 0x3fd921fb, fatan64(0.41421356237309503), 3)    /* pi/8, fold boundary */
	assert_f64_ulp(0x7f3321d2, 0x3ff2d97c, fatan64(2.4142135623730951), 3)    /* 3pi/8, fold boundary */

	# -- fatan264 golden (glibc atan2, tolerance = measured 3 + 1) --
	assert_f64_ulp(0x0561bb4f, 0x3fddac67, fatan264(1.0, 2.0), 4)    /* 0.46364760900080609 */
	assert_f64_ulp(cast(int, 0xa3269ee1), cast(int, 0xbfe4978f), fatan264(-3.0, 4.0), 4)    /* -0.64350110879328437 */
	assert_f64_ulp(0x6347d276, 0x40039328, fatan264(5.0, -6.0), 4)    /* 2.4468543773930902 */
	assert_f64_ulp(0x62e61b8b, cast(int, 0xc00361d1), fatan264(-7.0, -8.0), 4)    /* -2.4227626539681686 */
	assert_f64_ulp(0x54442d18, 0x3fe921fb, fatan264(1.0, 1.0), 4)    /* pi/4 */

	# -- fasin64 golden (glibc asin, tolerance = measured 2 + 1) --
	assert_f64_ulp(cast(int, 0x9e14f6ff), 0x3fd38015, fasin64(0.3), 3)    /* 0.30469265401539752 */
	assert_f64_ulp(0x382d7366, cast(int, 0xbfe0c152), fasin64(-0.5), 3)    /* -pi/6 */
	assert_f64_ulp(0x7a9974f2, 0x3fec1f77, fasin64(0.77), 3)    /* 0.87884115166857968 */
	assert_f64_ulp(0x6b2c13ad, 0x3ff91c30, fasin64(0.999999), 3)    /* 1.5693821131146521 */
	assert_f64_ulp(cast(int, 0xe2308c3a), 0x3e45798e, fasin64(1e-8), 3)    /* 1e-08 */
	assert_f64_ulp(0x6f33d51d, cast(int, 0xbff6de3c), fasin64(-0.99), 3)    /* -1.4292568534704693 */

	# -- facos64 golden (glibc acos, tolerance = measured 1 + 1) --
	assert_f64_ulp(cast(int, 0xecbeef59), 0x3ff441f5, facos64(0.3), 2)    /* 1.2661036727794992 */
	assert_f64_ulp(0x382d7366, 0x4000c152, facos64(-0.5), 2)    /* 2pi/3 */
	assert_f64_ulp(0x2deee53e, 0x3fe6247f, facos64(0.77), 2)    /* 0.69195517512631688 */
	assert_f64_ulp(cast(int, 0xb722c141), 0x40090504, facos64(-0.9999), 2)    /* 3.1274504001122811 */
	assert_f64_ulp(0x6065af16, 0x3f572ba4, facos64(0.999999), 2)    /* 0.0014142136802445852 */
	assert_f64_ulp(cast(int, 0xc0c3fca6), 0x3ff91de2, facos64(0.001), 2)    /* 1.56979632662823 */

	# -- edge-case ladders, bit-exact (each case verified equal to
	# glibc's behavior by the C harness; NaNs propagate their payload,
	# which glibc also does for these quiet inputs). nan_payload is a
	# quiet NaN with a nonzero low bit so propagation (return x) is
	# distinguishable from manufacture (0x7ff8 << 48). --
	int nan_payload = (0x7ff8 << 48) | 5
	int plus_inf = 0x7ff << 52
	int minus_inf = 0xfff << 52

	# exp2/exp: NaN -> itself, +inf -> +inf, -inf -> +0, +-0 -> 1,
	# overflow -> +inf, deep underflow -> +0, exact powers of two
	assert_equal_hex(nan_payload, float64_bits(fexp264(float64_from_bits(nan_payload))))
	assert_float64_bits(0x00000000, 0x7ff00000, fexp264(float64_from_bits(plus_inf)))
	assert_float64_bits(0x00000000, 0x00000000, fexp264(float64_from_bits(minus_inf)))
	assert_float64_bits(0x00000000, 0x3ff00000, fexp264(0.0))
	assert_float64_bits(0x00000000, 0x3ff00000, fexp264(-0.0))
	assert_float64_bits(0x00000000, 0x40900000, fexp264(10.0))    /* 1024, exact */
	assert_float64_bits(0x00000000, 0x3fe00000, fexp264(-1.0))    /* 0.5, exact */
	assert_float64_bits(0x00000000, 0x7ff00000, fexp264(1024.0))    /* overflow edge */
	assert_float64_bits(0x00000001, 0x00000000, fexp264(-1074.0))    /* smallest subnormal, exact */
	assert_float64_bits(0x00000000, 0x00000000, fexp264(-1075.0))    /* 2^-1075 ties to even 0 */
	assert_float64_bits(0x00000000, 0x00000000, fexp264(-1076.0))
	assert_equal_hex(nan_payload, float64_bits(fexp64(float64_from_bits(nan_payload))))
	assert_float64_bits(0x00000000, 0x7ff00000, fexp64(float64_from_bits(plus_inf)))
	assert_float64_bits(0x00000000, 0x00000000, fexp64(float64_from_bits(minus_inf)))
	assert_float64_bits(0x00000000, 0x3ff00000, fexp64(0.0))
	assert_float64_bits(0x00000000, 0x7ff00000, fexp64(709.9))    /* overflow, inside the guard */
	assert_float64_bits(0x00000000, 0x7ff00000, fexp64(710.5))    /* overflow, beyond the guard */
	assert_float64_bits(0x00000000, 0x00000000, fexp64(-745.5))    /* underflow, inside the guard */
	assert_float64_bits(0x00000000, 0x00000000, fexp64(-746.5))    /* underflow, beyond the guard */

	# logs: NaN -> itself, +-0 -> -inf, negative (incl. -inf) -> NaN,
	# +inf -> +inf, exact anchor points
	assert_equal_hex(nan_payload, float64_bits(flog264(float64_from_bits(nan_payload))))
	assert_float64_bits(0x00000000, cast(int, 0xfff00000), flog264(0.0))
	assert_float64_bits(0x00000000, cast(int, 0xfff00000), flog264(-0.0))
	assert_float64_bits(0x00000000, 0x7ff80000, flog264(-2.0))
	assert_float64_bits(0x00000000, 0x7ff80000, flog264(float64_from_bits(minus_inf)))
	assert_float64_bits(0x00000000, 0x7ff00000, flog264(float64_from_bits(plus_inf)))
	assert_float64_bits(0x00000000, 0x40080000, flog264(8.0))    /* 3.0, exact */
	assert_float64_bits(0x00000000, cast(int, 0xc0000000), flog264(0.25))    /* -2.0, exact */
	assert_float64_bits(0x00000000, cast(int, 0xc090c800), flog264(float64_from_bits(1)))    /* -1074, exact */
	assert_equal_hex(nan_payload, float64_bits(flog64(float64_from_bits(nan_payload))))
	assert_float64_bits(0x00000000, cast(int, 0xfff00000), flog64(0.0))
	assert_float64_bits(0x00000000, 0x7ff80000, flog64(-2.0))
	assert_float64_bits(0x00000000, 0x7ff00000, flog64(float64_from_bits(plus_inf)))
	assert_float64_bits(0x00000000, 0x00000000, flog64(1.0))    /* +0, exact */
	assert_equal_hex(nan_payload, float64_bits(flog1064(float64_from_bits(nan_payload))))
	assert_float64_bits(0x00000000, cast(int, 0xfff00000), flog1064(0.0))
	assert_float64_bits(0x00000000, 0x7ff80000, flog1064(-2.0))
	assert_float64_bits(0x00000000, 0x7ff00000, flog1064(float64_from_bits(plus_inf)))
	assert_float64_bits(0x00000000, 0x00000000, flog1064(1.0))    /* +0, exact */

	# fpow64: the IEEE 754 pow ladder
	assert_float64_bits(0x00000000, 0x3ff00000, fpow64(float64_from_bits(nan_payload), 0.0))
	assert_float64_bits(0x00000000, 0x3ff00000, fpow64(float64_from_bits(nan_payload), -0.0))
	assert_float64_bits(0x00000000, 0x3ff00000, fpow64(float64_from_bits(plus_inf), 0.0))
	assert_float64_bits(0x00000000, 0x3ff00000, fpow64(float64_from_bits(minus_inf), -0.0))
	assert_float64_bits(0x00000000, 0x3ff00000, fpow64(-0.0, -0.0))
	assert_float64_bits(0x00000000, 0x3ff00000, fpow64(2.5, 0.0))
	assert_float64_bits(0x00000000, 0x3ff00000, fpow64(1.0, float64_from_bits(nan_payload)))
	assert_float64_bits(0x00000000, 0x3ff00000, fpow64(1.0, float64_from_bits(plus_inf)))
	assert_float64_bits(0x00000000, 0x3ff00000, fpow64(1.0, float64_from_bits(minus_inf)))
	assert_float64_bits(0x00000000, 0x3ff00000, fpow64(1.0, 2.5))
	assert_equal_hex(nan_payload, float64_bits(fpow64(float64_from_bits(nan_payload), 2.0)))
	assert_equal_hex(nan_payload, float64_bits(fpow64(2.0, float64_from_bits(nan_payload))))
	assert_float64_bits(0x00000000, 0x40040000, fpow64(2.5, 1.0))    /* x^1 = x */
	assert_equal_hex(nan_payload, float64_bits(fpow64(float64_from_bits(nan_payload), 1.0)))
	assert_float64_bits(0x00000000, cast(int, 0x80000000), fpow64(-0.0, 1.0))    /* -0 */
	# y = +-inf against |x| vs 1
	assert_float64_bits(0x00000000, 0x00000000, fpow64(0.5, float64_from_bits(plus_inf)))
	assert_float64_bits(0x00000000, 0x7ff00000, fpow64(2.0, float64_from_bits(plus_inf)))
	assert_float64_bits(0x00000000, 0x3ff00000, fpow64(-1.0, float64_from_bits(plus_inf)))
	assert_float64_bits(0x00000000, 0x3ff00000, fpow64(-1.0, float64_from_bits(minus_inf)))
	assert_float64_bits(0x00000000, 0x7ff00000, fpow64(0.5, float64_from_bits(minus_inf)))
	assert_float64_bits(0x00000000, 0x00000000, fpow64(2.0, float64_from_bits(minus_inf)))
	assert_float64_bits(0x00000000, 0x7ff00000, fpow64(-2.0, float64_from_bits(plus_inf)))
	assert_float64_bits(0x00000000, 0x7ff00000, fpow64(-0.5, float64_from_bits(minus_inf)))
	# +-0 base: sign only for -0 with odd integer y
	assert_float64_bits(0x00000000, 0x00000000, fpow64(0.0, 3.0))
	assert_float64_bits(0x00000000, cast(int, 0x80000000), fpow64(-0.0, 3.0))
	assert_float64_bits(0x00000000, 0x7ff00000, fpow64(0.0, -3.0))
	assert_float64_bits(0x00000000, cast(int, 0xfff00000), fpow64(-0.0, -3.0))
	assert_float64_bits(0x00000000, 0x00000000, fpow64(0.0, 2.0))
	assert_float64_bits(0x00000000, 0x00000000, fpow64(-0.0, 2.0))
	assert_float64_bits(0x00000000, 0x7ff00000, fpow64(0.0, -2.0))
	assert_float64_bits(0x00000000, 0x7ff00000, fpow64(-0.0, -2.0))
	assert_float64_bits(0x00000000, 0x00000000, fpow64(0.0, 0.5))
	assert_float64_bits(0x00000000, 0x00000000, fpow64(-0.0, 0.5))
	assert_float64_bits(0x00000000, 0x7ff00000, fpow64(-0.0, -0.5))
	# +-inf base, mirroring the zero rules
	assert_float64_bits(0x00000000, 0x7ff00000, fpow64(float64_from_bits(plus_inf), 2.0))
	assert_float64_bits(0x00000000, 0x00000000, fpow64(float64_from_bits(plus_inf), -2.0))
	assert_float64_bits(0x00000000, cast(int, 0xfff00000), fpow64(float64_from_bits(minus_inf), 3.0))
	assert_float64_bits(0x00000000, 0x7ff00000, fpow64(float64_from_bits(minus_inf), 2.0))
	assert_float64_bits(0x00000000, cast(int, 0x80000000), fpow64(float64_from_bits(minus_inf), -3.0))
	assert_float64_bits(0x00000000, 0x00000000, fpow64(float64_from_bits(minus_inf), -2.0))
	# negative finite base: non-integer y -> NaN; huge y is an even integer
	assert_float64_bits(0x00000000, 0x7ff80000, fpow64(-2.0, 0.5))
	assert_float64_bits(0x00000000, 0x7ff00000, fpow64(-2.0, 9007199254740992.0))
	assert_float64_bits(0x00000000, 0x00000000, fpow64(-0.5, 9007199254740992.0))
	# overflow/underflow with the parity sign
	assert_float64_bits(0x00000000, 0x7ff00000, fpow64(2.0, 2000.0))
	assert_float64_bits(0x00000000, 0x00000000, fpow64(2.0, -2000.0))
	assert_float64_bits(0x00000000, cast(int, 0xfff00000), fpow64(-2.0, 2001.0))
	assert_float64_bits(0x00000000, cast(int, 0x80000000), fpow64(-2.0, -2001.0))

	# trig: NaN -> itself, +-inf -> NaN, signed zeros, the tiny-x
	# shortcut, and the documented |x| >= 2^52 fixed values
	assert_equal_hex(nan_payload, float64_bits(fsin64(float64_from_bits(nan_payload))))
	assert_equal_hex(nan_payload, float64_bits(fcos64(float64_from_bits(nan_payload))))
	assert_equal_hex(nan_payload, float64_bits(ftan64(float64_from_bits(nan_payload))))
	assert_float64_bits(0x00000000, 0x7ff80000, fsin64(float64_from_bits(plus_inf)))
	assert_float64_bits(0x00000000, 0x7ff80000, fsin64(float64_from_bits(minus_inf)))
	assert_float64_bits(0x00000000, 0x7ff80000, fcos64(float64_from_bits(plus_inf)))
	assert_float64_bits(0x00000000, 0x7ff80000, ftan64(float64_from_bits(minus_inf)))
	assert_float64_bits(0x00000000, 0x00000000, fsin64(0.0))
	assert_float64_bits(0x00000000, cast(int, 0x80000000), fsin64(-0.0))
	assert_float64_bits(0x00000000, 0x3ff00000, fcos64(0.0))
	assert_float64_bits(0x00000000, 0x3ff00000, fcos64(-0.0))
	assert_float64_bits(0x00000000, 0x00000000, ftan64(0.0))
	assert_float64_bits(0x00000000, cast(int, 0x80000000), ftan64(-0.0))
	assert_equal_hex(float64_bits(1e-30), float64_bits(fsin64(1e-30)))    /* below 2^-27: returns x */
	assert_equal_hex(float64_bits(1e-30), float64_bits(ftan64(1e-30)))
	assert_float64_bits(0x00000000, 0x00000000, fsin64(float64_from_bits(0x433 << 52)))    /* 2^52 contract */
	assert_float64_bits(0x00000000, 0x3ff00000, fcos64(float64_from_bits(0x433 << 52)))
	assert_float64_bits(0x00000000, 0x00000000, ftan64(float64_from_bits(0x434 << 52)))    /* 2^53 too */

	# atan: NaN -> itself, +-inf -> +-pi/2, +-0 -> +-0
	assert_equal_hex(nan_payload, float64_bits(fatan64(float64_from_bits(nan_payload))))
	assert_float64_bits(0x54442d18, 0x3ff921fb, fatan64(float64_from_bits(plus_inf)))
	assert_float64_bits(0x54442d18, cast(int, 0xbff921fb), fatan64(float64_from_bits(minus_inf)))
	assert_float64_bits(0x00000000, 0x00000000, fatan64(0.0))
	assert_float64_bits(0x00000000, cast(int, 0x80000000), fatan64(-0.0))

	# atan2: the full quadrant ladder
	assert_equal_hex(nan_payload, float64_bits(fatan264(float64_from_bits(nan_payload), 1.0)))
	assert_equal_hex(nan_payload, float64_bits(fatan264(1.0, float64_from_bits(nan_payload))))
	assert_float64_bits(0x00000000, 0x00000000, fatan264(0.0, 5.0))
	assert_float64_bits(0x00000000, cast(int, 0x80000000), fatan264(-0.0, 5.0))
	assert_float64_bits(0x00000000, 0x00000000, fatan264(0.0, 0.0))
	assert_float64_bits(0x00000000, cast(int, 0x80000000), fatan264(-0.0, 0.0))
	assert_float64_bits(0x54442d18, 0x400921fb, fatan264(0.0, -3.0))    /* pi */
	assert_float64_bits(0x54442d18, cast(int, 0xc00921fb), fatan264(-0.0, -3.0))    /* -pi */
	assert_float64_bits(0x54442d18, 0x400921fb, fatan264(0.0, -0.0))
	assert_float64_bits(0x54442d18, cast(int, 0xc00921fb), fatan264(-0.0, -0.0))
	assert_float64_bits(0x54442d18, 0x3ff921fb, fatan264(7.0, 0.0))    /* pi/2 */
	assert_float64_bits(0x54442d18, 0x3ff921fb, fatan264(7.0, -0.0))
	assert_float64_bits(0x54442d18, cast(int, 0xbff921fb), fatan264(-7.0, 0.0))
	assert_float64_bits(0x00000000, 0x00000000, fatan264(2.0, float64_from_bits(plus_inf)))
	assert_float64_bits(0x00000000, cast(int, 0x80000000), fatan264(-2.0, float64_from_bits(plus_inf)))
	assert_float64_bits(0x54442d18, 0x400921fb, fatan264(2.0, float64_from_bits(minus_inf)))
	assert_float64_bits(0x54442d18, cast(int, 0xc00921fb), fatan264(-2.0, float64_from_bits(minus_inf)))
	assert_float64_bits(0x54442d18, 0x3ff921fb, fatan264(float64_from_bits(plus_inf), 9.0))
	assert_float64_bits(0x54442d18, cast(int, 0xbff921fb), fatan264(float64_from_bits(minus_inf), 9.0))
	assert_float64_bits(0x54442d18, 0x3ff921fb, fatan264(float64_from_bits(plus_inf), -9.0))
	assert_float64_bits(0x54442d18, 0x3fe921fb, fatan264(float64_from_bits(plus_inf), float64_from_bits(plus_inf)))    /* pi/4 */
	assert_float64_bits(0x54442d18, cast(int, 0xbfe921fb), fatan264(float64_from_bits(minus_inf), float64_from_bits(plus_inf)))
	assert_float64_bits(0x7f3321d2, 0x4002d97c, fatan264(float64_from_bits(plus_inf), float64_from_bits(minus_inf)))    /* 3pi/4 */
	assert_float64_bits(0x7f3321d2, cast(int, 0xc002d97c), fatan264(float64_from_bits(minus_inf), float64_from_bits(minus_inf)))
	assert_float64_bits(0x00000000, 0x00000000, fatan264(1e-300, 1e300))    /* y/x underflows to +0 */
	assert_float64_bits(0x54442d18, 0x3ff921fb, fatan264(1e300, 1e-300))    /* y/x overflows: pi/2 */

	# asin/acos: NaN -> itself, |x| > 1 -> NaN, exact endpoints
	assert_equal_hex(nan_payload, float64_bits(fasin64(float64_from_bits(nan_payload))))
	assert_equal_hex(nan_payload, float64_bits(facos64(float64_from_bits(nan_payload))))
	assert_float64_bits(0x00000000, 0x7ff80000, fasin64(1.5))
	assert_float64_bits(0x00000000, 0x7ff80000, fasin64(-1.5))
	assert_float64_bits(0x00000000, 0x7ff80000, facos64(1.5))
	assert_float64_bits(0x54442d18, 0x3ff921fb, fasin64(1.0))    /* pi/2 */
	assert_float64_bits(0x54442d18, cast(int, 0xbff921fb), fasin64(-1.0))
	assert_float64_bits(0x00000000, 0x00000000, fasin64(0.0))
	assert_float64_bits(0x00000000, cast(int, 0x80000000), fasin64(-0.0))
	assert_float64_bits(0x00000000, 0x00000000, facos64(1.0))    /* +0 */
	assert_float64_bits(0x54442d18, 0x400921fb, facos64(-1.0))    /* pi */
	assert_float64_bits(0x54442d18, 0x3ff921fb, facos64(0.0))    /* pi/2 */
	assert_float64_bits(0x54442d18, 0x3ff921fb, facos64(-0.0))

	# -- identities tying the family together (tolerances from the same
	# C harness, + margin) --
	assert_f64_close2(7.25, fexp64(flog64(7.25)), 4)
	assert_f64_close2(0.037, fexp264(flog264(0.037)), 5)
	assert_f64_close2(fsqrt64(7.25), fpow64(7.25, 0.5), 3)
	float64 s13 = fsin64(1.3)
	float64 c13 = fcos64(1.3)
	assert_f64_close2(1.0, s13 * s13 + c13 * c13, 4)
	assert_f64_close2(2.0, flog1064(100.0), 3)
	# for x > 0 fatan264 delegates to fatan64, so this one is bit-exact
	assert_equal_hex(float64_bits(fatan64(0.75)), float64_bits(fatan264(3.0, 4.0)))

	println(c"x64 fmath64 OK")
	return 0
