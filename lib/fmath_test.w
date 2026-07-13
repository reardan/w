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


# Sign-corrected monotone integer ordering of a float's bit pattern:
# negatives map below positives, so the ulp distance between two floats
# is a plain integer subtraction of their ordered bits.
int ulp_order_bits(float f):
	int b = float_bits(f)
	if (b < 0):
		return cast(int, 0x80000000) - b
	return b


# Assert got is within tol ulps of the float whose bits are want_bits.
# The expected bits are glibc float results baked in by the throwaway C
# generator described in lib/fmath.w's transcendental section; tol is
# that function's measured bound plus 1 ulp of margin. NaN expectations
# are asserted separately through fis_nan.
void assert_fulp(int want_bits, float got, int tol):
	float want = float_from_bits(want_bits)
	int d = ulp_order_bits(want) - ulp_order_bits(got)
	if (d < 0):
		d = 0 - d
	if (d > tol):
		print2(c"Assertion failed: wanted float bits ")
		print2(hex(want_bits))
		print2(c" got ")
		print2(hex(float_bits(got)))
		print2(c" ulp distance ")
		print2(itoa(d))
		println2(c"")
		exit(1)


void test_fexp2_golden():
	assert_fulp(cast(int, 0x3f800000), fexp2(float_from_bits(cast(int, 0x00000000))), 2)	# fexp2(0) = 1
	assert_fulp(cast(int, 0x40000000), fexp2(float_from_bits(cast(int, 0x3f800000))), 2)	# fexp2(1) = 2
	assert_fulp(cast(int, 0x3f000000), fexp2(float_from_bits(cast(int, 0xbf800000))), 2)	# fexp2(-1) = 0.5
	assert_fulp(cast(int, 0x3fb504f3), fexp2(float_from_bits(cast(int, 0x3f000000))), 2)	# fexp2(0.5) = 1.41421354
	assert_fulp(cast(int, 0x3f3504f3), fexp2(float_from_bits(cast(int, 0xbf000000))), 2)	# fexp2(-0.5) = 0.707106769
	assert_fulp(cast(int, 0x414fefc6), fexp2(float_from_bits(cast(int, 0x406ccccd))), 2)	# fexp2(3.70000005) = 12.9960384
	assert_fulp(cast(int, 0x3d9d9624), fexp2(float_from_bits(cast(int, 0xc06ccccd))), 2)	# fexp2(-3.70000005) = 0.0769465268
	assert_fulp(cast(int, 0x458b95c2), fexp2(float_from_bits(cast(int, 0x41420000))), 2)	# fexp2(12.125) = 4466.71973
	assert_fulp(cast(int, 0x396ac0c7), fexp2(float_from_bits(cast(int, 0xc1420000))), 2)	# fexp2(-12.125) = 0.000223877942
	assert_fulp(cast(int, 0x4d1d961e), fexp2(float_from_bits(cast(int, 0x41da6666))), 2)	# fexp2(27.2999992) = 165241312
	assert_fulp(cast(int, 0x31cfefcd), fexp2(float_from_bits(cast(int, 0xc1da6666))), 2)	# fexp2(-27.2999992) = 6.0517551e-09
	assert_fulp(cast(int, 0x6bc202f3), fexp2(float_from_bits(cast(int, 0x42b13333))), 2)	# fexp2(88.5999985) = 4.69091073e+26
	assert_fulp(cast(int, 0x1328e5ae), fexp2(float_from_bits(cast(int, 0xc2b13333))), 2)	# fexp2(-88.5999985) = 2.1317822e-27
	assert_fulp(cast(int, 0x71892fd6), fexp2(float_from_bits(cast(int, 0x42c83333))), 2)	# fexp2(100.099998) = 1.35863285e+30
	assert_fulp(cast(int, 0x0d6edb51), fexp2(float_from_bits(cast(int, 0xc2c83333))), 2)	# fexp2(-100.099998) = 7.36034048e-31
	assert_fulp(cast(int, 0x7eeedb51), fexp2(float_from_bits(cast(int, 0x42fdcccd))), 2)	# fexp2(126.900002) = 1.58747509e+38
	assert_fulp(cast(int, 0x00534925), fexp2(float_from_bits(cast(int, 0xc2fd3d71))), 2)	# fexp2(-126.620003) = 7.64858549e-39
	assert_fulp(cast(int, 0x7f7ffb7f), fexp2(float_from_bits(cast(int, 0x42fffff3))), 2)	# fexp2(127.999901) = 3.40258981e+38
	assert_fulp(cast(int, 0x3f800006), fexp2(float_from_bits(cast(int, 0x358637bd))), 2)	# fexp2(9.99999997e-07) = 1.00000072
	assert_fulp(cast(int, 0x3f7ffff4), fexp2(float_from_bits(cast(int, 0xb58637bd))), 2)	# fexp2(-9.99999997e-07) = 0.999999285
	assert_fulp(cast(int, 0x0005a828), fexp2(float_from_bits(cast(int, 0xc3028000))), 2)	# fexp2(-130.5) = 5.19500577e-40
	assert_fulp(cast(int, 0x000001be), fexp2(float_from_bits(cast(int, 0xc30c3333))), 2)	# fexp2(-140.199997) = 6.24979115e-43
	assert_fulp(cast(int, 0x00000001), fexp2(float_from_bits(cast(int, 0xc3148000))), 2)	# fexp2(-148.5) = 1.40129846e-45
	assert_fulp(cast(int, 0x00000000), fexp2(float_from_bits(cast(int, 0xc3168000))), 2)	# fexp2(-150.5) = 0


void test_fexp_golden():
	assert_fulp(cast(int, 0x3f800000), fexp(float_from_bits(cast(int, 0x00000000))), 2)	# fexp(0) = 1
	assert_fulp(cast(int, 0x402df854), fexp(float_from_bits(cast(int, 0x3f800000))), 2)	# fexp(1) = 2.71828175
	assert_fulp(cast(int, 0x3ebc5ab2), fexp(float_from_bits(cast(int, 0xbf800000))), 2)	# fexp(-1) = 0.36787945
	assert_fulp(cast(int, 0x3fd3094c), fexp(float_from_bits(cast(int, 0x3f000000))), 2)	# fexp(0.5) = 1.64872122
	assert_fulp(cast(int, 0x4142eb7f), fexp(float_from_bits(cast(int, 0x40200000))), 2)	# fexp(2.5) = 12.1824942
	assert_fulp(cast(int, 0x3da81c2e), fexp(float_from_bits(cast(int, 0xc0200000))), 2)	# fexp(-2.5) = 0.0820849985
	assert_fulp(cast(int, 0x439d1868), fexp(float_from_bits(cast(int, 0x40b80000))), 2)	# fexp(5.75) = 314.190674
	assert_fulp(cast(int, 0x3b509633), fexp(float_from_bits(cast(int, 0xc0b80000))), 2)	# fexp(-5.75) = 0.0031827807
	assert_fulp(cast(int, 0x46be2e0a), fexp(float_from_bits(cast(int, 0x4121999a))), 2)	# fexp(10.1000004) = 24343.0195
	assert_fulp(cast(int, 0x382c4cd2), fexp(float_from_bits(cast(int, 0xc121999a))), 2)	# fexp(-10.1000004) = 4.10795401e-05
	assert_fulp(cast(int, 0x4e1486bb), fexp(float_from_bits(cast(int, 0x41a20000))), 2)	# fexp(20.25) = 622964416
	assert_fulp(cast(int, 0x5f70bfe2), fexp(float_from_bits(cast(int, 0x42313333))), 2)	# fexp(44.2999992) = 1.73478328e+19
	assert_fulp(cast(int, 0x1f881bb7), fexp(float_from_bits(cast(int, 0xc2313333))), 2)	# fexp(-44.2999992) = 5.76440908e-20
	assert_fulp(cast(int, 0x727fbd7c), fexp(float_from_bits(cast(int, 0x428d6666))), 2)	# fexp(70.6999969) = 5.065456e+30
	assert_fulp(cast(int, 0x0c80214b), fexp(float_from_bits(cast(int, 0xc28d6666))), 2)	# fexp(-70.6999969) = 1.97415601e-31
	assert_fulp(cast(int, 0x7e76d06e), fexp(float_from_bits(cast(int, 0x42ae999a))), 2)	# fexp(87.3000031) = 8.20180789e+37
	assert_fulp(cast(int, 0x0084c38b), fexp(float_from_bits(cast(int, 0xc2ae999a))), 2)	# fexp(-87.3000031) = 1.21924331e-38
	assert_fulp(cast(int, 0x7f7f4648), fexp(float_from_bits(cast(int, 0x42b170a4))), 2)	# fexp(88.7200012) = 3.3931806e+38
	assert_fulp(cast(int, 0x0000000b), fexp(float_from_bits(cast(int, 0xc2c9cccd))), 2)	# fexp(-100.900002) = 1.54142831e-44
	assert_fulp(cast(int, 0x3f800054), fexp(float_from_bits(cast(int, 0x3727c5ac))), 2)	# fexp(9.99999975e-06) = 1.00001001
	assert_fulp(cast(int, 0x3f7fff58), fexp(float_from_bits(cast(int, 0xb727c5ac))), 2)	# fexp(-9.99999975e-06) = 0.999989986


void test_flog2_golden():
	assert_fulp(cast(int, 0x00000000), flog2(float_from_bits(cast(int, 0x3f800000))), 2)	# flog2(1) = 0
	assert_fulp(cast(int, 0x3f800000), flog2(float_from_bits(cast(int, 0x40000000))), 2)	# flog2(2) = 1
	assert_fulp(cast(int, 0xbf800000), flog2(float_from_bits(cast(int, 0x3f000000))), 2)	# flog2(0.5) = -1
	assert_fulp(cast(int, 0x3fcae00d), flog2(float_from_bits(cast(int, 0x40400000))), 2)	# flog2(3) = 1.58496249
	assert_fulp(cast(int, 0x40549a78), flog2(float_from_bits(cast(int, 0x41200000))), 2)	# flog2(10) = 3.32192802
	assert_fulp(cast(int, 0x40d49a78), flog2(float_from_bits(cast(int, 0x42c80000))), 2)	# flog2(100) = 6.64385605
	assert_fulp(cast(int, 0xc1549a78), flog2(float_from_bits(cast(int, 0x38d1b717))), 2)	# flog2(9.99999975e-05) = -13.2877121
	assert_fulp(cast(int, 0x3f15c01a), flog2(float_from_bits(cast(int, 0x3fc00000))), 2)	# flog2(1.5) = 0.584962487
	assert_fulp(cast(int, 0xbed47fcc), flog2(float_from_bits(cast(int, 0x3f400000))), 2)	# flog2(0.75) = -0.415037513
	assert_fulp(cast(int, 0x40000000), flog2(float_from_bits(cast(int, 0x40800000))), 2)	# flog2(4) = 2
	assert_fulp(cast(int, 0x41200000), flog2(float_from_bits(cast(int, 0x44800000))), 2)	# flog2(1024) = 10
	assert_fulp(cast(int, 0x3438aa3a), flog2(float_from_bits(cast(int, 0x3f800001))), 2)	# flog2(1.00000012) = 1.71982634e-07
	assert_fulp(cast(int, 0xb3b8aa3b), flog2(float_from_bits(cast(int, 0x3f7fffff))), 2)	# flog2(0.99999994) = -8.59913243e-08
	assert_fulp(cast(int, 0xc3150000), flog2(float_from_bits(cast(int, 0x00000001))), 2)	# flog2(1.40129846e-45) = -149
	assert_fulp(cast(int, 0xc2fc0000), flog2(float_from_bits(cast(int, 0x00800000))), 2)	# flog2(1.17549435e-38) = -126
	assert_fulp(cast(int, 0x3ffffffd), flog2(float_from_bits(cast(int, 0x407ffffc))), 2)	# flog2(3.99999905) = 1.99999964
	assert_fulp(cast(int, 0x42fc776f), flog2(float_from_bits(cast(int, 0x7e967699))), 2)	# flog2(9.99999968e+37) = 126.233269
	assert_fulp(cast(int, 0xc11a96f8), flog2(float_from_bits(cast(int, 0x3aa1cef2))), 2)	# flog2(0.00123449997) = -9.6618576
	assert_fulp(cast(int, 0x4033abb4), flog2(float_from_bits(cast(int, 0x40e00000))), 2)	# flog2(7) = 2.80735493
	assert_fulp(cast(int, 0x3fb8aa3b), flog2(float_from_bits(cast(int, 0x402df854))), 2)	# flog2(2.71828175) = 1.44269502
	assert_fulp(cast(int, 0x3fd3643a), flog2(float_from_bits(cast(int, 0x40490fdb))), 2)	# flog2(3.14159274) = 1.65149617


void test_flog_golden():
	assert_fulp(cast(int, 0x00000000), flog(float_from_bits(cast(int, 0x3f800000))), 2)	# flog(1) = 0
	assert_fulp(cast(int, 0x3f317218), flog(float_from_bits(cast(int, 0x40000000))), 2)	# flog(2) = 0.693147182
	assert_fulp(cast(int, 0xbf317218), flog(float_from_bits(cast(int, 0x3f000000))), 2)	# flog(0.5) = -0.693147182
	assert_fulp(cast(int, 0x3f8c9f54), flog(float_from_bits(cast(int, 0x40400000))), 2)	# flog(3) = 1.09861231
	assert_fulp(cast(int, 0x40135d8e), flog(float_from_bits(cast(int, 0x41200000))), 2)	# flog(10) = 2.30258512
	assert_fulp(cast(int, 0x40935d8e), flog(float_from_bits(cast(int, 0x42c80000))), 2)	# flog(100) = 4.60517025
	assert_fulp(cast(int, 0xc1135d8e), flog(float_from_bits(cast(int, 0x38d1b717))), 2)	# flog(9.99999975e-05) = -9.2103405
	assert_fulp(cast(int, 0x3ecf991f), flog(float_from_bits(cast(int, 0x3fc00000))), 2)	# flog(1.5) = 0.405465096
	assert_fulp(cast(int, 0xbe934b11), flog(float_from_bits(cast(int, 0x3f400000))), 2)	# flog(0.75) = -0.287682086
	assert_fulp(cast(int, 0x3fb17218), flog(float_from_bits(cast(int, 0x40800000))), 2)	# flog(4) = 1.38629436
	assert_fulp(cast(int, 0x40ddce9e), flog(float_from_bits(cast(int, 0x44800000))), 2)	# flog(1024) = 6.93147182
	assert_fulp(cast(int, 0x33ffffff), flog(float_from_bits(cast(int, 0x3f800001))), 2)	# flog(1.00000012) = 1.19209282e-07
	assert_fulp(cast(int, 0xb3800000), flog(float_from_bits(cast(int, 0x3f7fffff))), 2)	# flog(0.99999994) = -5.96046448e-08
	assert_fulp(cast(int, 0xc2ce8ed0), flog(float_from_bits(cast(int, 0x00000001))), 2)	# flog(1.40129846e-45) = -103.278931
	assert_fulp(cast(int, 0xc2aeac50), flog(float_from_bits(cast(int, 0x00800000))), 2)	# flog(1.17549435e-38) = -87.3365479
	assert_fulp(cast(int, 0x3fb17216), flog(float_from_bits(cast(int, 0x407ffffc))), 2)	# flog(3.99999905) = 1.38629413
	assert_fulp(cast(int, 0x42aeff18), flog(float_from_bits(cast(int, 0x7e967699))), 2)	# flog(9.99999968e+37) = 87.49823
	assert_fulp(cast(int, 0xc0d64e8e), flog(float_from_bits(cast(int, 0x3aa1cef2))), 2)	# flog(0.00123449997) = -6.6970892
	assert_fulp(cast(int, 0x3ff91395), flog(float_from_bits(cast(int, 0x40e00000))), 2)	# flog(7) = 1.9459101
	assert_fulp(cast(int, 0x3f7fffff), flog(float_from_bits(cast(int, 0x402df854))), 2)	# flog(2.71828175) = 0.99999994
	assert_fulp(cast(int, 0x3f928683), flog(float_from_bits(cast(int, 0x40490fdb))), 2)	# flog(3.14159274) = 1.14472997


void test_flog10_golden():
	assert_fulp(cast(int, 0x00000000), flog10(float_from_bits(cast(int, 0x3f800000))), 3)	# flog10(1) = 0
	assert_fulp(cast(int, 0x3e9a209b), flog10(float_from_bits(cast(int, 0x40000000))), 3)	# flog10(2) = 0.30103001
	assert_fulp(cast(int, 0xbe9a209b), flog10(float_from_bits(cast(int, 0x3f000000))), 3)	# flog10(0.5) = -0.30103001
	assert_fulp(cast(int, 0x3ef4493c), flog10(float_from_bits(cast(int, 0x40400000))), 3)	# flog10(3) = 0.477121234
	assert_fulp(cast(int, 0x3f800000), flog10(float_from_bits(cast(int, 0x41200000))), 3)	# flog10(10) = 1
	assert_fulp(cast(int, 0x40000000), flog10(float_from_bits(cast(int, 0x42c80000))), 3)	# flog10(100) = 2
	assert_fulp(cast(int, 0xc0800000), flog10(float_from_bits(cast(int, 0x38d1b717))), 3)	# flog10(9.99999975e-05) = -4
	assert_fulp(cast(int, 0x3e345144), flog10(float_from_bits(cast(int, 0x3fc00000))), 3)	# flog10(1.5) = 0.176091254
	assert_fulp(cast(int, 0xbdffdfe3), flog10(float_from_bits(cast(int, 0x3f400000))), 3)	# flog10(0.75) = -0.124938749
	assert_fulp(cast(int, 0x3f1a209b), flog10(float_from_bits(cast(int, 0x40800000))), 3)	# flog10(4) = 0.60206002
	assert_fulp(cast(int, 0x4040a8c1), flog10(float_from_bits(cast(int, 0x44800000))), 3)	# flog10(1024) = 3.01029992
	assert_fulp(cast(int, 0x335e5bd8), flog10(float_from_bits(cast(int, 0x3f800001))), 3)	# flog10(1.00000012) = 5.17719343e-08
	assert_fulp(cast(int, 0xb2de5bd9), flog10(float_from_bits(cast(int, 0x3f7fffff))), 3)	# flog10(0.99999994) = -2.58859689e-08
	assert_fulp(cast(int, 0xc23369f4), flog10(float_from_bits(cast(int, 0x00000001))), 3)	# flog10(1.40129846e-45) = -44.8534698
	assert_fulp(cast(int, 0xc217b818), flog10(float_from_bits(cast(int, 0x00800000))), 3)	# flog10(1.17549435e-38) = -37.9297791
	assert_fulp(cast(int, 0x3f1a2099), flog10(float_from_bits(cast(int, 0x407ffffc))), 3)	# flog10(3.99999905) = 0.602059901
	assert_fulp(cast(int, 0x42180000), flog10(float_from_bits(cast(int, 0x7e967699))), 3)	# flog10(9.99999968e+37) = 38
	assert_fulp(cast(int, 0xc03a2503), flog10(float_from_bits(cast(int, 0x3aa1cef2))), 3)	# flog10(0.00123449997) = -2.90850902
	assert_fulp(cast(int, 0x3f585858), flog10(float_from_bits(cast(int, 0x40e00000))), 3)	# flog10(7) = 0.845098019
	assert_fulp(cast(int, 0x3ede5bd8), flog10(float_from_bits(cast(int, 0x402df854))), 3)	# flog10(2.71828175) = 0.434294462
	assert_fulp(cast(int, 0x3efe8a6e), flog10(float_from_bits(cast(int, 0x40490fdb))), 3)	# flog10(3.14159274) = 0.497149885


void test_fpow_golden():
	assert_fulp(cast(int, 0x41000000), fpow(float_from_bits(cast(int, 0x40000000)), float_from_bits(cast(int, 0x40400000))), 2)	# fpow(2, 3) = 8
	assert_fulp(cast(int, 0x3fb504f3), fpow(float_from_bits(cast(int, 0x40000000)), float_from_bits(cast(int, 0x3f000000))), 2)	# fpow(2, 0.5) = 1.41421354
	assert_fulp(cast(int, 0x3f000000), fpow(float_from_bits(cast(int, 0x40000000)), float_from_bits(cast(int, 0xbf800000))), 2)	# fpow(2, -1) = 0.5
	assert_fulp(cast(int, 0x447a0000), fpow(float_from_bits(cast(int, 0x41200000)), float_from_bits(cast(int, 0x40400000))), 2)	# fpow(10, 3) = 1000
	assert_fulp(cast(int, 0x3c23d70a), fpow(float_from_bits(cast(int, 0x41200000)), float_from_bits(cast(int, 0xc0000000))), 2)	# fpow(10, -2) = 0.00999999978
	assert_fulp(cast(int, 0x4b60189f), fpow(float_from_bits(cast(int, 0x3fc00000)), float_from_bits(cast(int, 0x4222cccd))), 2)	# fpow(1.5, 40.7000008) = 14686367
	assert_fulp(cast(int, 0x3f623b49), fpow(float_from_bits(cast(int, 0x3f7fff58)), float_from_bits(cast(int, 0x4640e400))), 2)	# fpow(0.999989986, 12345) = 0.88371712
	assert_fulp(cast(int, 0x7e800000), fpow(float_from_bits(cast(int, 0x3f000000)), float_from_bits(cast(int, 0xc2fc0000))), 2)	# fpow(0.5, -126) = 8.50705917e+37
	assert_fulp(cast(int, 0x7eb504f3), fpow(float_from_bits(cast(int, 0x40000000)), float_from_bits(cast(int, 0x42fd0000))), 2)	# fpow(2, 126.5) = 1.20307983e+38
	assert_fulp(cast(int, 0x00000001), fpow(float_from_bits(cast(int, 0x40000000)), float_from_bits(cast(int, 0xc3148000))), 2)	# fpow(2, -148.5) = 1.40129846e-45
	assert_fulp(cast(int, 0x3d17b426), fpow(float_from_bits(cast(int, 0x40400000)), float_from_bits(cast(int, 0xc0400000))), 2)	# fpow(3, -3) = 0.0370370373
	assert_fulp(cast(int, 0xc1000000), fpow(float_from_bits(cast(int, 0xc0000000)), float_from_bits(cast(int, 0x40400000))), 2)	# fpow(-2, 3) = -8
	assert_fulp(cast(int, 0x41800000), fpow(float_from_bits(cast(int, 0xc0000000)), float_from_bits(cast(int, 0x40800000))), 2)	# fpow(-2, 4) = 16
	assert_fulp(cast(int, 0x28b67f38), fpow(float_from_bits(cast(int, 0x3f333333)), float_from_bits(cast(int, 0x42b0cccd))), 2)	# fpow(0.699999988, 88.4000015) = 2.02612314e-14
	assert_fulp(cast(int, 0x2c063fd9), fpow(float_from_bits(cast(int, 0x3fb33333)), float_from_bits(cast(int, 0xc2a06666))), 2)	# fpow(1.39999998, -80.1999969) = 1.90779879e-12
	assert_fulp(cast(int, 0x4e99a4d7), fpow(float_from_bits(cast(int, 0x418d999a)), float_from_bits(cast(int, 0x40e9999a))), 2)	# fpow(17.7000008, 7.30000019) = 1.2888585e+09
	assert_fulp(cast(int, 0x3e361887), fpow(float_from_bits(cast(int, 0x3a83126f)), float_from_bits(cast(int, 0x3e800000))), 2)	# fpow(0.00100000005, 0.25) = 0.177827939
	assert_fulp(cast(int, 0x7f800000), fpow(float_from_bits(cast(int, 0x0da24260)), float_from_bits(cast(int, 0xc0800000))), 2)	# fpow(1e-30, -4) = inf
	assert_fulp(cast(int, 0x4232c1cb), fpow(float_from_bits(cast(int, 0x42f6e979)), float_from_bits(cast(int, 0x3f49fbe7))), 2)	# fpow(123.456001, 0.788999975) = 44.6892509
	assert_fulp(cast(int, 0x40304bb1), fpow(float_from_bits(cast(int, 0x3f7fffef)), float_from_bits(cast(int, 0xc9742400))), 2)	# fpow(0.999998987, -1000000) = 2.75461984
	assert_fulp(cast(int, 0x4052d05e), fpow(float_from_bits(cast(int, 0x3f800001)), float_from_bits(cast(int, 0x4b189680))), 2)	# fpow(1.00000012, 10000000) = 3.29396772
	assert_fulp(cast(int, 0x42290000), fpow(float_from_bits(cast(int, 0x40d00000)), float_from_bits(cast(int, 0x40000000))), 2)	# fpow(6.5, 2) = 42.25
	assert_fulp(cast(int, 0x44800000), fpow(float_from_bits(cast(int, 0x40000000)), float_from_bits(cast(int, 0x41200000))), 2)	# fpow(2, 10) = 1024
	assert_fulp(cast(int, 0x40400000), fpow(float_from_bits(cast(int, 0x41100000)), float_from_bits(cast(int, 0x3f000000))), 2)	# fpow(9, 0.5) = 3


void test_fsin_golden():
	assert_fulp(cast(int, 0x3ef57744), fsin(float_from_bits(cast(int, 0x3f000000))), 3)	# fsin(0.5) = 0.47942555
	assert_fulp(cast(int, 0x3f576aa4), fsin(float_from_bits(cast(int, 0x3f800000))), 3)	# fsin(1) = 0.841470957
	assert_fulp(cast(int, 0x3f800000), fsin(float_from_bits(cast(int, 0x3fc90fda))), 3)	# fsin(1.57079625) = 1
	assert_fulp(cast(int, 0x3f68c7b7), fsin(float_from_bits(cast(int, 0x40000000))), 3)	# fsin(2) = 0.909297407
	assert_fulp(cast(int, 0x3e1081c3), fsin(float_from_bits(cast(int, 0x40400000))), 3)	# fsin(3) = 0.141120002
	assert_fulp(cast(int, 0xb3bbbd2e), fsin(float_from_bits(cast(int, 0x40490fdb))), 3)	# fsin(3.14159274) = -8.74227766e-08
	assert_fulp(cast(int, 0xbf7ffaf8), fsin(float_from_bits(cast(int, 0x40966666))), 3)	# fsin(4.69999981) = -0.999923229
	assert_fulp(cast(int, 0x343bbd2e), fsin(float_from_bits(cast(int, 0x40c90fdb))), 3)	# fsin(6.28318548) = 1.74845553e-07
	assert_fulp(cast(int, 0xbef57744), fsin(float_from_bits(cast(int, 0xbf000000))), 3)	# fsin(-0.5) = -0.47942555
	assert_fulp(cast(int, 0xbf03f7e7), fsin(float_from_bits(cast(int, 0xc0266666))), 3)	# fsin(-2.5999999) = -0.51550144
	assert_fulp(cast(int, 0xbf6133be), fsin(float_from_bits(cast(int, 0x41280000))), 3)	# fsin(10.5) = -0.879695773
	assert_fulp(cast(int, 0x3f738a4c), fsin(float_from_bits(cast(int, 0x42053333))), 3)	# fsin(33.2999992) = 0.951328993
	assert_fulp(cast(int, 0x3e2c4407), fsin(float_from_bits(cast(int, 0x42c96666))), 3)	# fsin(100.699997) = 0.168228254
	assert_fulp(cast(int, 0xbf7f3936), fsin(float_from_bits(cast(int, 0x43960ccd))), 3)	# fsin(300.100006) = -0.99696672
	assert_fulp(cast(int, 0x3e14e299), fsin(float_from_bits(cast(int, 0x449a5000))), 3)	# fsin(1234.5) = 0.145395651
	assert_fulp(cast(int, 0x3c86c8cc), fsin(float_from_bits(cast(int, 0x463b839a))), 3)	# fsin(12000.9004) = 0.0164531693
	assert_fulp(cast(int, 0x3a83126e), fsin(float_from_bits(cast(int, 0x3a83126f))), 3)	# fsin(0.00100000005) = 0.000999999931
	assert_fulp(cast(int, 0xb8d1b717), fsin(float_from_bits(cast(int, 0xb8d1b717))), 3)	# fsin(-9.99999975e-05) = -9.99999975e-05
	assert_fulp(cast(int, 0x3f3504f3), fsin(float_from_bits(cast(int, 0x3f490fdb))), 3)	# fsin(0.785398185) = 0.707106769
	assert_fulp(cast(int, 0xbe086dee), fsin(float_from_bits(cast(int, 0xc14b3333))), 3)	# fsin(-12.6999998) = -0.133231848


void test_fcos_golden():
	assert_fulp(cast(int, 0x3f60a940), fcos(float_from_bits(cast(int, 0x3f000000))), 3)	# fcos(0.5) = 0.87758255
	assert_fulp(cast(int, 0x3f0a5140), fcos(float_from_bits(cast(int, 0x3f800000))), 3)	# fcos(1) = 0.540302277
	assert_fulp(cast(int, 0x33a22169), fcos(float_from_bits(cast(int, 0x3fc90fda))), 3)	# fcos(1.57079625) = 7.54979013e-08
	assert_fulp(cast(int, 0xbed51133), fcos(float_from_bits(cast(int, 0x40000000))), 3)	# fcos(2) = -0.416146845
	assert_fulp(cast(int, 0xbf7d7026), fcos(float_from_bits(cast(int, 0x40400000))), 3)	# fcos(3) = -0.989992499
	assert_fulp(cast(int, 0xbf800000), fcos(float_from_bits(cast(int, 0x40490fdb))), 3)	# fcos(3.14159274) = -1
	assert_fulp(cast(int, 0xbc4afa9f), fcos(float_from_bits(cast(int, 0x40966666))), 3)	# fcos(4.69999981) = -0.0123888543
	assert_fulp(cast(int, 0x3f800000), fcos(float_from_bits(cast(int, 0x40c90fdb))), 3)	# fcos(6.28318548) = 1
	assert_fulp(cast(int, 0x3f60a940), fcos(float_from_bits(cast(int, 0xbf000000))), 3)	# fcos(-0.5) = 0.87758255
	assert_fulp(cast(int, 0xbf5b5d0f), fcos(float_from_bits(cast(int, 0xc0266666))), 3)	# fcos(-2.5999999) = -0.856888711
	assert_fulp(cast(int, 0xbef37993), fcos(float_from_bits(cast(int, 0x41280000))), 3)	# fcos(10.5) = -0.475536913
	assert_fulp(cast(int, 0xbe9dc967), fcos(float_from_bits(cast(int, 0x42053333))), 3)	# fcos(33.2999992) = -0.308177203
	assert_fulp(cast(int, 0x3f7c59fc), fcos(float_from_bits(cast(int, 0x42c96666))), 3)	# fcos(100.699997) = 0.985748053
	assert_fulp(cast(int, 0x3d9f64c2), fcos(float_from_bits(cast(int, 0x43960ccd))), 3)	# fcos(300.100006) = 0.077828899
	assert_fulp(cast(int, 0xbf7d4796), fcos(float_from_bits(cast(int, 0x449a5000))), 3)	# fcos(1234.5) = -0.989373565
	assert_fulp(cast(int, 0x3f7ff721), fcos(float_from_bits(cast(int, 0x463b839a))), 3)	# fcos(12000.9004) = 0.999864638
	assert_fulp(cast(int, 0x3f7ffff8), fcos(float_from_bits(cast(int, 0x3a83126f))), 3)	# fcos(0.00100000005) = 0.999999523
	assert_fulp(cast(int, 0x3f800000), fcos(float_from_bits(cast(int, 0xb8d1b717))), 3)	# fcos(-9.99999975e-05) = 1
	assert_fulp(cast(int, 0x3f3504f3), fcos(float_from_bits(cast(int, 0x3f490fdb))), 3)	# fcos(0.785398185) = 0.707106769
	assert_fulp(cast(int, 0x3f7db7bd), fcos(float_from_bits(cast(int, 0xc14b3333))), 3)	# fcos(-12.6999998) = 0.991084874


void test_ftan_golden():
	assert_fulp(cast(int, 0x3f0bda7b), ftan(float_from_bits(cast(int, 0x3f000000))), 4)	# ftan(0.5) = 0.546302497
	assert_fulp(cast(int, 0x3fc75923), ftan(float_from_bits(cast(int, 0x3f800000))), 4)	# ftan(1) = 1.55740774
	assert_fulp(cast(int, 0x41619f6b), ftan(float_from_bits(cast(int, 0x3fc00000))), 4)	# ftan(1.5) = 14.1014204
	assert_fulp(cast(int, 0x4b4a1bd9), ftan(float_from_bits(cast(int, 0x3fc90fda))), 4)	# ftan(1.57079625) = 13245401
	assert_fulp(cast(int, 0xc00bd7b1), ftan(float_from_bits(cast(int, 0x40000000))), 4)	# ftan(2) = -2.18503976
	assert_fulp(cast(int, 0xbe11f7b9), ftan(float_from_bits(cast(int, 0x40400000))), 4)	# ftan(3) = -0.142546549
	assert_fulp(cast(int, 0x42a16c4c), ftan(float_from_bits(cast(int, 0x40966666))), 4)	# ftan(4.69999981) = 80.7115173
	assert_fulp(cast(int, 0xbf0bda7b), ftan(float_from_bits(cast(int, 0xbf000000))), 4)	# ftan(-0.5) = -0.546302497
	assert_fulp(cast(int, 0x3f1a023f), ftan(float_from_bits(cast(int, 0xc0266666))), 4)	# ftan(-2.5999999) = 0.601596773
	assert_fulp(cast(int, 0x3fecc986), ftan(float_from_bits(cast(int, 0x41280000))), 4)	# ftan(10.5) = 1.84990001
	assert_fulp(cast(int, 0xc04590aa), ftan(float_from_bits(cast(int, 0x42053333))), 4)	# ftan(33.2999992) = -3.08695459
	assert_fulp(cast(int, 0x3e2ec1a0), ftan(float_from_bits(cast(int, 0x42c96666))), 4)	# ftan(100.699997) = 0.170660496
	assert_fulp(cast(int, 0xbe167bf8), ftan(float_from_bits(cast(int, 0x449a5000))), 4)	# ftan(1234.5) = -0.146957278
	assert_fulp(cast(int, 0x3a831272), ftan(float_from_bits(cast(int, 0x3a83126f))), 4)	# ftan(0.00100000005) = 0.0010000004
	assert_fulp(cast(int, 0x3f800000), ftan(float_from_bits(cast(int, 0x3f490fdb))), 4)	# ftan(0.785398185) = 1
	assert_fulp(cast(int, 0xbe09a81a), ftan(float_from_bits(cast(int, 0xc14b3333))), 4)	# ftan(-12.6999998) = -0.134430319
	assert_fulp(cast(int, 0xc14cf4a2), ftan(float_from_bits(cast(int, 0x43960ccd))), 4)	# ftan(300.100006) = -12.8097248


void test_fatan_golden():
	assert_fulp(cast(int, 0x3d4ca12d), fatan(float_from_bits(cast(int, 0x3d4ccccd))), 4)	# fatan(0.0500000007) = 0.0499583967
	assert_fulp(cast(int, 0x3dcc1f14), fatan(float_from_bits(cast(int, 0x3dcccccd))), 4)	# fatan(0.100000001) = 0.0996686518
	assert_fulp(cast(int, 0x3e9539d4), fatan(float_from_bits(cast(int, 0x3e99999a))), 4)	# fatan(0.300000012) = 0.291456819
	assert_fulp(cast(int, 0x3ec737c0), fatan(float_from_bits(cast(int, 0x3ed1eb85))), 4)	# fatan(0.409999996) = 0.389097214
	assert_fulp(cast(int, 0x3eed6338), fatan(float_from_bits(cast(int, 0x3f000000))), 4)	# fatan(0.5) = 0.463647604
	assert_fulp(cast(int, 0x3f3b99c5), fatan(float_from_bits(cast(int, 0x3f666666))), 4)	# fatan(0.899999976) = 0.732815087
	assert_fulp(cast(int, 0x3f490fdb), fatan(float_from_bits(cast(int, 0x3f800000))), 4)	# fatan(1) = 0.785398185
	assert_fulp(cast(int, 0x3f7b985f), fatan(float_from_bits(cast(int, 0x3fc00000))), 4)	# fatan(1.5) = 0.982793748
	assert_fulp(cast(int, 0x3f968757), fatan(float_from_bits(cast(int, 0x4019999a))), 4)	# fatan(2.4000001) = 1.17600524
	assert_fulp(cast(int, 0x3f9fe0bb), fatan(float_from_bits(cast(int, 0x40400000))), 4)	# fatan(3) = 1.24904573
	assert_fulp(cast(int, 0x3fbc4de9), fatan(float_from_bits(cast(int, 0x41200000))), 4)	# fatan(10) = 1.47112763
	assert_fulp(cast(int, 0x3fc7c82f), fatan(float_from_bits(cast(int, 0x42c80000))), 4)	# fatan(100) = 1.56079662
	assert_fulp(cast(int, 0x3fc90c94), fatan(float_from_bits(cast(int, 0x461c4000))), 4)	# fatan(10000) = 1.57069635
	assert_fulp(cast(int, 0x3fc90fdb), fatan(float_from_bits(cast(int, 0x7149f2ca))), 4)	# fatan(1.00000002e+30) = 1.57079637
	assert_fulp(cast(int, 0xbe9539d4), fatan(float_from_bits(cast(int, 0xbe99999a))), 4)	# fatan(-0.300000012) = -0.291456819
	assert_fulp(cast(int, 0xbf490fdb), fatan(float_from_bits(cast(int, 0xbf800000))), 4)	# fatan(-1) = -0.785398185
	assert_fulp(cast(int, 0xbf985b6c), fatan(float_from_bits(cast(int, 0xc0200000))), 4)	# fatan(-2.5) = -1.19028997
	assert_fulp(cast(int, 0xbfc90fd2), fatan(float_from_bits(cast(int, 0xc9742400))), 4)	# fatan(-1000000) = -1.5707953
	assert_fulp(cast(int, 0x38d1b717), fatan(float_from_bits(cast(int, 0x38d1b717))), 4)	# fatan(9.99999975e-05) = 9.99999975e-05
	assert_fulp(cast(int, 0x3f1c5889), fatan(float_from_bits(cast(int, 0x3f333333))), 4)	# fatan(0.699999988) = 0.610725939


void test_fatan2_golden():
	assert_fulp(cast(int, 0x3f490fdb), fatan2(float_from_bits(cast(int, 0x3f800000)), float_from_bits(cast(int, 0x3f800000))), 4)	# fatan2(1, 1) = 0.785398185
	assert_fulp(cast(int, 0x4016cbe4), fatan2(float_from_bits(cast(int, 0x3f800000)), float_from_bits(cast(int, 0xbf800000))), 4)	# fatan2(1, -1) = 2.3561945
	assert_fulp(cast(int, 0xbf490fdb), fatan2(float_from_bits(cast(int, 0xbf800000)), float_from_bits(cast(int, 0x3f800000))), 4)	# fatan2(-1, 1) = -0.785398185
	assert_fulp(cast(int, 0xc016cbe4), fatan2(float_from_bits(cast(int, 0xbf800000)), float_from_bits(cast(int, 0xbf800000))), 4)	# fatan2(-1, -1) = -2.3561945
	assert_fulp(cast(int, 0x4048ff78), fatan2(float_from_bits(cast(int, 0x3a83126f)), float_from_bits(cast(int, 0xbf800000))), 4)	# fatan2(0.00100000005, -1) = 3.14059258
	assert_fulp(cast(int, 0x3fc90ec3), fatan2(float_from_bits(cast(int, 0x40400000)), float_from_bits(cast(int, 0x38d1b717))), 4)	# fatan2(3, 9.99999975e-05) = 1.57076299
	assert_fulp(cast(int, 0x3eca220f), fatan2(float_from_bits(cast(int, 0x40a00000)), float_from_bits(cast(int, 0x41400000))), 4)	# fatan2(5, 12) = 0.394791096
	assert_fulp(cast(int, 0xbe914d76), fatan2(float_from_bits(cast(int, 0xc0e00000)), float_from_bits(cast(int, 0x41c00000))), 4)	# fatan2(-7, 24) = -0.283794105
	assert_fulp(cast(int, 0x40278d01), fatan2(float_from_bits(cast(int, 0x3f000000)), float_from_bits(cast(int, 0xbf5db22d))), 4)	# fatan2(0.5, -0.865999997) = 2.6179812
	assert_fulp(cast(int, 0x3fc90fdb), fatan2(float_from_bits(cast(int, 0x7e967699)), float_from_bits(cast(int, 0x3a83126f))), 4)	# fatan2(9.99999968e+37, 0.00100000005) = 1.57079637
	assert_fulp(cast(int, 0x0015c730), fatan2(float_from_bits(cast(int, 0x006ce3ee)), float_from_bits(cast(int, 0x40a00000))), 4)	# fatan2(9.99999935e-39, 5) = 2.00000043e-39
	assert_fulp(cast(int, 0xc0490fdb), fatan2(float_from_bits(cast(int, 0x806ce3ee)), float_from_bits(cast(int, 0xc0000000))), 4)	# fatan2(-9.99999935e-39, -2) = -3.14159274
	assert_fulp(cast(int, 0x3fce2de0), fatan2(float_from_bits(cast(int, 0x40200000)), float_from_bits(cast(int, 0xbdcccccd))), 4)	# fatan2(2.5, -0.100000001) = 1.61077499
	assert_fulp(cast(int, 0xc0322be6), fatan2(float_from_bits(cast(int, 0xc06ccccd)), float_from_bits(cast(int, 0xc11e6666))), 4)	# fatan2(-3.70000005, -9.89999962) = -2.78392935
	assert_fulp(cast(int, 0x3fc789c7), fatan2(float_from_bits(cast(int, 0x42280000)), float_from_bits(cast(int, 0x3f000000))), 4)	# fatan2(42, 0.5) = 1.55889213


void test_fasin_golden():
	assert_fulp(cast(int, 0x00000000), fasin(float_from_bits(cast(int, 0x00000000))), 3)	# fasin(0) = 0
	assert_fulp(cast(int, 0x3dcd2494), fasin(float_from_bits(cast(int, 0x3dcccccd))), 3)	# fasin(0.100000001) = 0.100167423
	assert_fulp(cast(int, 0xbdcd2494), fasin(float_from_bits(cast(int, 0xbdcccccd))), 3)	# fasin(-0.100000001) = -0.100167423
	assert_fulp(cast(int, 0x3e815f4e), fasin(float_from_bits(cast(int, 0x3e800000))), 3)	# fasin(0.25) = 0.252680242
	assert_fulp(cast(int, 0x3f031851), fasin(float_from_bits(cast(int, 0x3efae148))), 3)	# fasin(0.49000001) = 0.512089789
	assert_fulp(cast(int, 0x3f060a92), fasin(float_from_bits(cast(int, 0x3f000000))), 3)	# fasin(0.5) = 0.52359879
	assert_fulp(cast(int, 0x3f0901de), fasin(float_from_bits(cast(int, 0x3f028f5c))), 3)	# fasin(0.50999999) = 0.535184741
	assert_fulp(cast(int, 0xbf0901de), fasin(float_from_bits(cast(int, 0xbf028f5c))), 3)	# fasin(-0.50999999) = -0.535184741
	assert_fulp(cast(int, 0x3f24bc7e), fasin(float_from_bits(cast(int, 0x3f19999a))), 3)	# fasin(0.600000024) = 0.643501163
	assert_fulp(cast(int, 0x3f591a99), fasin(float_from_bits(cast(int, 0x3f400000))), 3)	# fasin(0.75) = 0.848062098
	assert_fulp(cast(int, 0xbf591a99), fasin(float_from_bits(cast(int, 0xbf400000))), 3)	# fasin(-0.75) = -0.848062098
	assert_fulp(cast(int, 0x3f8f549b), fasin(float_from_bits(cast(int, 0x3f666666))), 3)	# fasin(0.899999976) = 1.11976945
	assert_fulp(cast(int, 0x3fb6f1e4), fasin(float_from_bits(cast(int, 0x3f7d70a4))), 3)	# fasin(0.99000001) = 1.42925692
	assert_fulp(cast(int, 0x3fc74067), fasin(float_from_bits(cast(int, 0x3f7ff972))), 3)	# fasin(0.999899983) = 1.5566529
	assert_fulp(cast(int, 0x3fc90fdb), fasin(float_from_bits(cast(int, 0x3f800000))), 3)	# fasin(1) = 1.57079637
	assert_fulp(cast(int, 0xbfc90fdb), fasin(float_from_bits(cast(int, 0xbf800000))), 3)	# fasin(-1) = -1.57079637
	assert_fulp(cast(int, 0x3a831270), fasin(float_from_bits(cast(int, 0x3a83126f))), 3)	# fasin(0.00100000005) = 0.00100000016
	assert_fulp(cast(int, 0x39000000), fasin(float_from_bits(cast(int, 0x39000000))), 3)	# fasin(0.000122070312) = 0.000122070312
	assert_fulp(cast(int, 0xbeadff1a), fasin(float_from_bits(cast(int, 0xbeaaaaaa))), 3)	# fasin(-0.333333313) = -0.339836895
	assert_fulp(cast(int, 0x3f860a92), fasin(float_from_bits(cast(int, 0x3f5db3d7))), 3)	# fasin(0.866025388) = 1.04719758


void test_facos_golden():
	assert_fulp(cast(int, 0x3fc90fdb), facos(float_from_bits(cast(int, 0x00000000))), 3)	# facos(0) = 1.57079637
	assert_fulp(cast(int, 0x3fbc3d91), facos(float_from_bits(cast(int, 0x3dcccccd))), 3)	# facos(0.100000001) = 1.47062886
	assert_fulp(cast(int, 0x3fd5e224), facos(float_from_bits(cast(int, 0xbdcccccd))), 3)	# facos(-0.100000001) = 1.67096376
	assert_fulp(cast(int, 0x3fa8b807), facos(float_from_bits(cast(int, 0x3e800000))), 3)	# facos(0.25) = 1.31811607
	assert_fulp(cast(int, 0x3f8783b2), facos(float_from_bits(cast(int, 0x3efae148))), 3)	# facos(0.49000001) = 1.05870652
	assert_fulp(cast(int, 0x3f860a92), facos(float_from_bits(cast(int, 0x3f000000))), 3)	# facos(0.5) = 1.04719758
	assert_fulp(cast(int, 0x3f848eeb), facos(float_from_bits(cast(int, 0x3f028f5c))), 3)	# facos(0.50999999) = 1.03561151
	assert_fulp(cast(int, 0x4006c865), facos(float_from_bits(cast(int, 0xbf028f5c))), 3)	# facos(-0.50999999) = 2.10598111
	assert_fulp(cast(int, 0x3f6d6338), facos(float_from_bits(cast(int, 0x3f19999a))), 3)	# facos(0.600000024) = 0.927295208
	assert_fulp(cast(int, 0x3f39051d), facos(float_from_bits(cast(int, 0x3f400000))), 3)	# facos(0.75) = 0.722734272
	assert_fulp(cast(int, 0x401ace94), facos(float_from_bits(cast(int, 0xbf400000))), 3)	# facos(-0.75) = 2.41885853
	assert_fulp(cast(int, 0x3ee6ecfe), facos(float_from_bits(cast(int, 0x3f666666))), 3)	# facos(0.899999976) = 0.451026857
	assert_fulp(cast(int, 0x3e10efb5), facos(float_from_bits(cast(int, 0x3f7d70a4))), 3)	# facos(0.99000001) = 0.14153941
	assert_fulp(cast(int, 0x3c67b9d5), facos(float_from_bits(cast(int, 0x3f7ff972))), 3)	# facos(0.999899983) = 0.0141434269
	assert_fulp(cast(int, 0x00000000), facos(float_from_bits(cast(int, 0x3f800000))), 3)	# facos(1) = 0
	assert_fulp(cast(int, 0x40490fdb), facos(float_from_bits(cast(int, 0xbf800000))), 3)	# facos(-1) = 3.14159274
	assert_fulp(cast(int, 0x3fc8ef16), facos(float_from_bits(cast(int, 0x3a83126f))), 3)	# facos(0.00100000005) = 1.56979632
	assert_fulp(cast(int, 0x3fc90bdb), facos(float_from_bits(cast(int, 0x39000000))), 3)	# facos(0.000122070312) = 1.5706743
	assert_fulp(cast(int, 0x3ff48fa1), facos(float_from_bits(cast(int, 0xbeaaaaaa))), 3)	# facos(-0.333333313) = 1.91063321
	assert_fulp(cast(int, 0x3f060a92), facos(float_from_bits(cast(int, 0x3f5db3d7))), 3)	# facos(0.866025388) = 0.52359879



void test_fexp_edge_cases():
	# NaN in -> NaN out
	assert_equal(1, fis_nan(fexp(float_from_bits(0x7fc00000))))
	assert_equal(1, fis_nan(fexp2(float_from_bits(0x7fc00000))))
	# overflow -> +inf, including +inf itself
	assert_float_bits(0x7f800000, fexp(90.0))
	assert_float_bits(0x7f800000, fexp(float_from_bits(0x7f800000)))
	assert_float_bits(0x7f800000, fexp2(128.0))
	assert_float_bits(0x7f800000, fexp2(129.0))
	assert_float_bits(0x7f800000, fexp2(float_from_bits(0x7f800000)))
	# big negative -> 0, including -inf
	assert_float_bits(0x00000000, fexp(-106.0))
	assert_float_bits(0x00000000, fexp(float_from_bits(cast(int, 0xff800000))))
	assert_float_bits(0x00000000, fexp2(-153.0))
	assert_float_bits(0x00000000, fexp2(float_from_bits(cast(int, 0xff800000))))
	# exact anchors
	assert_float_bits(0x3f800000, fexp(0.0))
	assert_float_bits(0x3f800000, fexp2(0.0))
	assert_float_bits(0x44800000, fexp2(10.0))


void test_flog_edge_cases():
	# NaN -> NaN
	assert_equal(1, fis_nan(flog(float_from_bits(0x7fc00000))))
	assert_equal(1, fis_nan(flog2(float_from_bits(0x7fc00000))))
	assert_equal(1, fis_nan(flog10(float_from_bits(0x7fc00000))))
	# +-0 -> -inf
	assert_float_bits(cast(int, 0xff800000), flog(0.0))
	assert_float_bits(cast(int, 0xff800000), flog2(float_from_bits(cast(int, 0x80000000))))
	assert_float_bits(cast(int, 0xff800000), flog10(0.0))
	# negative (including -inf) -> NaN
	assert_equal(1, fis_nan(flog(-1.0)))
	assert_equal(1, fis_nan(flog2(-2.5)))
	assert_equal(1, fis_nan(flog10(float_from_bits(cast(int, 0xff800000)))))
	# +inf -> +inf
	assert_float_bits(0x7f800000, flog(float_from_bits(0x7f800000)))
	assert_float_bits(0x7f800000, flog2(float_from_bits(0x7f800000)))
	# exact anchors
	assert_float_bits(0x00000000, flog(1.0))
	assert_float_bits(0x00000000, flog2(1.0))
	assert_float_bits(0x00000000, flog10(1.0))
	assert_float_bits(0x41200000, flog2(1024.0))


void test_fpow_edge_cases():
	# pow(x, +-0) = 1 for any x, even NaN
	assert_float_bits(0x3f800000, fpow(float_from_bits(0x7fc00000), 0.0))
	assert_float_bits(0x3f800000, fpow(0.0, 0.0))
	assert_float_bits(0x3f800000, fpow(float_from_bits(0x7f800000), float_from_bits(cast(int, 0x80000000))))
	# pow(1, y) = 1 for any y, even NaN
	assert_float_bits(0x3f800000, fpow(1.0, float_from_bits(0x7fc00000)))
	assert_float_bits(0x3f800000, fpow(1.0, float_from_bits(0x7f800000)))
	# NaN propagates otherwise
	assert_equal(1, fis_nan(fpow(float_from_bits(0x7fc00000), 2.0)))
	assert_equal(1, fis_nan(fpow(2.0, float_from_bits(0x7fc00000))))
	# negative base: non-integer y -> NaN, integer y signs by parity
	assert_equal(1, fis_nan(fpow(-2.0, 3.5)))
	assert_float_bits(cast(int, 0xc1000000), fpow(-2.0, 3.0))
	assert_float_bits(0x41800000, fpow(-2.0, 4.0))
	# zero base: y's sign picks 0 or inf; -0 with odd integer y keeps sign
	assert_float_bits(0x7f800000, fpow(0.0, -3.0))
	assert_float_bits(cast(int, 0xff800000), fpow(float_from_bits(cast(int, 0x80000000)), -3.0))
	assert_float_bits(cast(int, 0x80000000), fpow(float_from_bits(cast(int, 0x80000000)), 3.0))
	assert_float_bits(0x00000000, fpow(0.0, 4.0))
	# infinite base
	assert_float_bits(0x7f800000, fpow(float_from_bits(0x7f800000), 2.0))
	assert_float_bits(0x00000000, fpow(float_from_bits(0x7f800000), -2.0))
	assert_float_bits(cast(int, 0xff800000), fpow(float_from_bits(cast(int, 0xff800000)), 3.0))
	assert_float_bits(0x7f800000, fpow(float_from_bits(cast(int, 0xff800000)), 4.0))
	assert_float_bits(cast(int, 0x80000000), fpow(float_from_bits(cast(int, 0xff800000)), -3.0))
	# infinite exponent picks 0/1/inf by |x| against 1
	assert_float_bits(0x7f800000, fpow(2.0, float_from_bits(0x7f800000)))
	assert_float_bits(0x00000000, fpow(0.5, float_from_bits(0x7f800000)))
	assert_float_bits(0x3f800000, fpow(-1.0, float_from_bits(0x7f800000)))
	assert_float_bits(0x00000000, fpow(2.0, float_from_bits(cast(int, 0xff800000))))
	assert_float_bits(0x7f800000, fpow(0.5, float_from_bits(cast(int, 0xff800000))))
	# finite overflow / underflow
	assert_float_bits(0x7f800000, fpow(10.0, 100.0))
	assert_float_bits(0x00000000, fpow(10.0, -100.0))
	# pow(x, 1) = x
	assert_float_bits(0x40b00000, fpow(5.5, 1.0))


void test_ftrig_edge_cases():
	# NaN and +-inf -> NaN
	assert_equal(1, fis_nan(fsin(float_from_bits(0x7fc00000))))
	assert_equal(1, fis_nan(fsin(float_from_bits(0x7f800000))))
	assert_equal(1, fis_nan(fcos(float_from_bits(cast(int, 0xff800000)))))
	assert_equal(1, fis_nan(fcos(float_from_bits(0x7fc00000))))
	assert_equal(1, fis_nan(ftan(float_from_bits(0x7f800000))))
	assert_equal(1, fis_nan(ftan(float_from_bits(0x7fc00000))))
	# signed zero preserved by sin/tan, cos(+-0) = 1
	assert_float_bits(0x00000000, fsin(0.0))
	assert_float_bits(cast(int, 0x80000000), fsin(float_from_bits(cast(int, 0x80000000))))
	assert_float_bits(cast(int, 0x80000000), ftan(float_from_bits(cast(int, 0x80000000))))
	assert_float_bits(0x3f800000, fcos(0.0))
	assert_float_bits(0x3f800000, fcos(float_from_bits(cast(int, 0x80000000))))
	# tiny arguments return x (correctly rounded there)
	assert_float_bits(0x39000000, fsin(float_from_bits(0x39000000)))
	assert_float_bits(cast(int, 0xb9000000), ftan(float_from_bits(cast(int, 0xb9000000))))


void test_finvtrig_edge_cases():
	# NaN -> NaN
	assert_equal(1, fis_nan(fatan(float_from_bits(0x7fc00000))))
	assert_equal(1, fis_nan(fasin(float_from_bits(0x7fc00000))))
	assert_equal(1, fis_nan(facos(float_from_bits(0x7fc00000))))
	# atan(+-inf) = +-pi/2, atan(+-0) = +-0
	assert_float_bits(0x3fc90fdb, fatan(float_from_bits(0x7f800000)))
	assert_float_bits(cast(int, 0xbfc90fdb), fatan(float_from_bits(cast(int, 0xff800000))))
	assert_float_bits(0x00000000, fatan(0.0))
	assert_float_bits(cast(int, 0x80000000), fatan(float_from_bits(cast(int, 0x80000000))))
	# out-of-domain asin/acos -> NaN
	assert_equal(1, fis_nan(fasin(1.5)))
	assert_equal(1, fis_nan(fasin(-1.5)))
	assert_equal(1, fis_nan(fasin(float_from_bits(0x3f800001))))
	assert_equal(1, fis_nan(facos(float_from_bits(0x3f800001))))
	assert_equal(1, fis_nan(facos(-2.0)))
	# exact endpoints
	assert_float_bits(0x3fc90fdb, fasin(1.0))
	assert_float_bits(cast(int, 0xbfc90fdb), fasin(-1.0))
	assert_float_bits(cast(int, 0x80000000), fasin(float_from_bits(cast(int, 0x80000000))))
	assert_float_bits(0x00000000, facos(1.0))
	assert_float_bits(0x40490fdb, facos(-1.0))


void test_fatan2_edge_cases():
	# NaN in -> NaN out
	assert_equal(1, fis_nan(fatan2(float_from_bits(0x7fc00000), 1.0)))
	assert_equal(1, fis_nan(fatan2(1.0, float_from_bits(0x7fc00000))))
	# zero/zero quadrants (glibc bit-exact)
	assert_float_bits(0x00000000, fatan2(0.0, 0.0))
	assert_float_bits(cast(int, 0x80000000), fatan2(float_from_bits(cast(int, 0x80000000)), 0.0))
	assert_float_bits(0x40490fdb, fatan2(0.0, float_from_bits(cast(int, 0x80000000))))
	assert_float_bits(cast(int, 0xc0490fdb), fatan2(float_from_bits(cast(int, 0x80000000)), float_from_bits(cast(int, 0x80000000))))
	# y = +-0 with x nonzero
	assert_float_bits(0x40490fdb, fatan2(0.0, -3.0))
	assert_float_bits(cast(int, 0xc0490fdb), fatan2(float_from_bits(cast(int, 0x80000000)), -3.0))
	assert_float_bits(0x00000000, fatan2(0.0, 3.0))
	assert_float_bits(cast(int, 0x80000000), fatan2(float_from_bits(cast(int, 0x80000000)), 3.0))
	# x = +-0 with y nonzero
	assert_float_bits(0x3fc90fdb, fatan2(2.0, 0.0))
	assert_float_bits(cast(int, 0xbfc90fdb), fatan2(-2.0, float_from_bits(cast(int, 0x80000000))))
	# infinities
	assert_float_bits(0x3f490fdb, fatan2(float_from_bits(0x7f800000), float_from_bits(0x7f800000)))
	assert_float_bits(0x4016cbe4, fatan2(float_from_bits(0x7f800000), float_from_bits(cast(int, 0xff800000))))
	assert_float_bits(cast(int, 0xbfc90fdb), fatan2(float_from_bits(cast(int, 0xff800000)), 5.0))
	assert_float_bits(0x00000000, fatan2(3.0, float_from_bits(0x7f800000)))
	assert_float_bits(0x40490fdb, fatan2(3.0, float_from_bits(cast(int, 0xff800000))))
	assert_float_bits(0x3fc90fdb, fatan2(float_from_bits(0x7f800000), 3.0))


void test_fexp_flog_round_trip():
	# exp(log(x)) and exp2(log2(x)) return to x; the tolerance grows
	# with |log x| because a 1-ulp log error is amplified by exp.
	int i = 0
	float x = 0.05
	float factor = 1.65
	while (i < 12):
		assert_fulp(float_bits(x), fexp(flog(x)), 8)
		assert_fulp(float_bits(x), fexp2(flog2(x)), 8)
		x = x * factor
		i = i + 1


void test_fsin_fcos_identity():
	# sin^2 + cos^2 = 1 across a spread of arguments
	int i = 0
	float x = -9.7
	float step = 1.3
	while (i < 15):
		float s = fsin(x)
		float c = fcos(x)
		assert_near(1.0, s * s + c * c)
		x = x + step
		i = i + 1


void test_fasin_facos_identity():
	# asin(x) + acos(x) = pi/2 across [-1, 1]
	int i = 0
	float x = -1.0
	float step = 0.125
	while (i < 17):
		assert_near(1.5707964, fasin(x) + facos(x))
		x = x + step
		i = i + 1


void test_fpow_identities():
	# x^0.5 tracks fsqrt, x^2 tracks x*x, integer powers of 2 are exact
	assert_fulp(float_bits(fsqrt(7.3)), fpow(7.3, 0.5), 4)
	assert_fulp(float_bits(fsqrt(123.456)), fpow(123.456, 0.5), 4)
	float a = 9.7
	assert_fulp(float_bits(a * a), fpow(a, 2.0), 2)
	assert_float_bits(0x42800000, fpow(2.0, 6.0))
	assert_float_bits(0x3d800000, fpow(2.0, -4.0))


void test_flog10_powers_of_ten():
	# within the measured flog10 bound of the mathematically exact values
	assert_fulp(0x40400000, flog10(1000.0), 3)
	assert_fulp(0x40c00000, flog10(1000000.0), 3)
	assert_fulp(cast(int, 0xc0400000), flog10(0.001), 3)
