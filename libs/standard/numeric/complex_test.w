# wbuild: arch_only=x64
# wbuild: target=complex_leak_test tag=tests_x64 dep=complex_test
# wbuild: step="bin/complex_test" env="W_TEST_LEAKS=1" expect_stdout="0 failed, 0 skipped [leak check]"
# Tests for libs/standard/numeric/complex.w (x64-only: float64).
# Arithmetic is asserted bit-for-bit against CPython 3's complex type,
# whose + - * / algorithms complex.w reproduces; sqrt/exp/log against
# mpmath references correctly rounded per part, within the measured
# bounds rounded up (sqrt <= 1.6 ulp, exp and log <= 2.7 ulp, the latter
# two inherited from fsin64/fcos64/fatan264). Special values follow
# CPython's cmath (checked by hand against python3), except where
# Python raises.
import lib.testing
import libs.standard.numeric.complex


float64 f64(int hi, int lo):
	int mask32 = (1 << 32) - 1
	return float64_from_bits((hi << 32) | (lo & mask32))


int ulp_key(float64 f):
	int b = float64_bits(f)
	if (b < 0): return 0 - (b & ((1 << 63) - 1))
	return b


void fail_part(char* what, float64 want, float64 got):
	int mask32 = (1 << 32) - 1
	print2(c"Assertion failed: ")
	print2(what)
	print2(c" want=")
	print2(hex(float64_bits(want) >> 32))
	print2(c":")
	print2(hex(float64_bits(want) & mask32))
	print2(c" got=")
	print2(hex(float64_bits(got) >> 32))
	print2(c":")
	println2(hex(float64_bits(got) & mask32))
	print_stack_trace()
	assert_failure_exit()


void part_same(float64 want, float64 got):
	if (f64is_nan(want) && f64is_nan(got)): return
	if (float64_bits(want) != float64_bits(got)): fail_part(c"bits differ", want, got)


void part_near(float64 want, float64 got, int max_ulp):
	int d = ulp_key(got) - ulp_key(want)
	if (d < 0): d = 0 - d
	if (f64is_nan(got) || d > max_ulp): fail_part(c"ulp distance too large", want, got)


# Both parts bit-exact (any NaN matches any NaN).
void csame(complex got, int re_hi, int re_lo, int im_hi, int im_lo):
	part_same(f64(re_hi, re_lo), got.re)
	part_same(f64(im_hi, im_lo), got.im)


void cnear(complex got, int re_hi, int re_lo, int im_hi, int im_lo, int max_ulp):
	part_near(f64(re_hi, re_lo), got.re, max_ulp)
	part_near(f64(im_hi, im_lo), got.im, max_ulp)


void cis(complex got, float64 re, float64 im):
	part_same(re, got.re)
	part_same(im, got.im)


float64 inf():
	return float64_from_bits(0x7ff << 52)


float64 nan():
	return float64_from_bits(0x7ff8 << 48)


float64 negzero():
	return float64_from_bits(1 << 63)


void test_basic_ops():
	complex z = complex(3.0, 4.0)
	cis(complex_conj(z), 3.0, -4.0)
	cis(complex_neg(z), -3.0, -4.0)
	cis(complex_scale(z, 0.5), 1.5, 2.0)
	cis(z * complex_conj(z), 25.0, 0.0)
	cis(complex_add(z, complex(1.0, -1.0)), 4.0, 3.0)
	cis(complex_sub(z, complex(1.0, -1.0)), 2.0, 5.0)
	cis(complex_mul(complex(0.0, 1.0), complex(0.0, 1.0)), -1.0, 0.0)
	cis(complex(1.0, 0.0) / complex(0.0, 1.0), 0.0, -1.0)
	# chained operators resolve through the overloads
	complex w = (z + complex(1.0, 0.0)) * complex(2.0, 0.0) - z / complex(1.0, 0.0)
	cis(w, 5.0, 4.0)


void test_division_specials():
	# by zero: nan + nanj (Python raises ZeroDivisionError)
	complex q = complex(1.0, 1.0) / complex(0.0, 0.0)
	assert1(f64is_nan(q.re) && f64is_nan(q.im))
	q = complex(1.0, 1.0) / complex(nan(), 1.0)
	assert1(f64is_nan(q.re) && f64is_nan(q.im))
	# C11 Annex G (G.5.2) recovery of infinities and zeros; CPython 3.13
	# returns nan + nanj for the second case
	cis(complex(inf(), 0.0) / complex(1.0, 1.0), inf(), -inf())
	cis(complex(inf(), inf()) / complex(2.0, 0.0), inf(), inf())
	cis(complex(1.0, 1.0) / complex(inf(), 0.0), 0.0, 0.0)
	cis(complex(-1.0, 1.0) / complex(0.0, inf()), 0.0, 0.0)
	# Smith's scaling keeps large operands finite (b.re^2 alone would overflow)
	cis(complex(1.0e300, 1.0e300) / complex(1.0e300, 1.0e300), 1.0, 0.0)


void test_abs_phase_polar_rect():
	part_same(5.0, complex_abs(complex(3.0, -4.0)))
	part_same(inf(), complex_abs(complex(nan(), inf())))
	assert1(f64is_nan(complex_abs(complex(nan(), 1.0))))
	part_same(1.4142135623730952e300, complex_abs(complex(1.0e300, 1.0e300)))
	part_same(3.1415926535897931, complex_phase(complex(-1.0, 0.0)))
	part_same(-3.1415926535897931, complex_phase(complex(-1.0, negzero())))
	part_same(1.5707963267948966, complex_phase(complex(0.0, 2.0)))
	part_same(0.0, complex_phase(complex(0.0, 0.0)))
	float64 r = 0.0
	float64 phi = 0.0
	complex_polar(complex(0.0, -3.0), &r, &phi)
	part_same(3.0, r)
	part_same(-1.5707963267948966, phi)
	complex z = complex_rect(2.0, 0.5)
	part_near(1.7551651237807455, z.re, 1)
	part_near(0.958851077208406, z.im, 1)
	cis(complex_rect(2.0, negzero()), 2.0, negzero())
	cis(complex_rect(inf(), 0.0), inf(), 0.0)
	cis(complex_rect(-inf(), negzero()), -inf(), 0.0)
	z = complex_rect(inf(), nan())
	part_same(inf(), z.re)
	assert1(f64is_nan(z.im))
	cis(complex_rect(nan(), 0.0), nan(), 0.0)
	z = complex_rect(1.0, inf())
	assert1(f64is_nan(z.re) && f64is_nan(z.im))
	cis(complex_rect(inf(), 1.0), inf(), inf())


void test_cmath_specials():
	# sqrt (C99 Annex G / CPython)
	cis(complex_sqrt(complex(0.0, 0.0)), 0.0, 0.0)
	cis(complex_sqrt(complex(negzero(), negzero())), 0.0, negzero())
	cis(complex_sqrt(complex(-4.0, negzero())), 0.0, -2.0)
	cis(complex_sqrt(complex(nan(), inf())), inf(), inf())
	cis(complex_sqrt(complex(1.0, -inf())), inf(), -inf())
	cis(complex_sqrt(complex(-inf(), 1.0)), 0.0, inf())
	cis(complex_sqrt(complex(inf(), negzero())), inf(), negzero())
	cis(complex_sqrt(complex(inf(), nan())), inf(), nan())
	cis(complex_sqrt(complex(-inf(), nan())), nan(), inf())
	cis(complex_sqrt(complex(nan(), 1.0)), nan(), nan())
	# exp
	cis(complex_exp(complex(inf(), nan())), inf(), nan())
	cis(complex_exp(complex(-inf(), nan())), 0.0, 0.0)
	cis(complex_exp(complex(nan(), 0.0)), nan(), 0.0)
	cis(complex_exp(complex(nan(), inf())), nan(), nan())
	cis(complex_exp(complex(-inf(), 1.0)), 0.0, 0.0)
	cis(complex_exp(complex(inf(), 1.0)), inf(), inf())
	cis(complex_exp(complex(inf(), negzero())), inf(), negzero())
	cis(complex_exp(complex(1.0, inf())), nan(), nan())
	cis(complex_exp(complex(800.0, 0.0)), inf(), 0.0)
	cis(complex_exp(complex(-800.0, 1.0)), 0.0, 0.0)
	cis(complex_exp(complex(-1.0, negzero())), 0.36787944117144233, negzero())
	# log
	cis(complex_log(complex(inf(), nan())), inf(), nan())
	cis(complex_log(complex(nan(), inf())), inf(), nan())
	cis(complex_log(complex(-inf(), 0.0)), inf(), 3.1415926535897931)
	cis(complex_log(complex(inf(), negzero())), inf(), negzero())
	cis(complex_log(complex(nan(), 1.0)), nan(), nan())
	cis(complex_log(complex(0.0, 0.0)), -inf(), 0.0)
	cis(complex_log(complex(negzero(), negzero())), -inf(), -3.1415926535897931)
	cis(complex_log(complex(1.0, 0.0)), 0.0, 0.0)


void test_identities():
	complex z = complex(0.3, -1.7)
	assert1(complex_isclose(complex_exp(complex_log(z)), z))
	complex s = complex_sqrt(z)
	assert1(complex_isclose(s * s, z))
	assert1(complex_isclose(complex_log(complex_exp(z)), z))


void test_isclose():
	assert1(complex_isclose(complex(1.0, 1.0), complex(1.0, 1.0 + 1.0e-12)))
	assert1(complex_isclose(complex(1.0, 1.0), complex(1.0, 1.0 + 1.0e-6)) == 0)
	assert1(complex_isclose(complex(inf(), 0.0), complex(inf(), 0.0)))
	assert1(complex_isclose(complex(inf(), 0.0), complex(inf(), 1.0)) == 0)
	assert1(complex_isclose(complex(nan(), 0.0), complex(nan(), 0.0)) == 0)
	assert1(complex_isclose(complex(0.0, 0.0), complex(0.0, 1.0e-20)) == 0)
	assert1(complex_isclose_tol(complex(0.0, 0.0), complex(0.0, 1.0e-20), 1.0e-9, 1.0e-19))
	assert1(complex_isclose_tol(complex(1.0, 0.0), complex(1.0, 0.1), -1.0, 1.0) == 0)


void test_arithmetic_matches_cpython():
	csame(complex(1.50000000000000000e+00, -2.25000000000000000e+00) + complex(5.00000000000000000e-01, 3.00000000000000000e+00), 0x40000000, 0x00000000, 0x3fe80000, 0x00000000)    # (2+0.75j)
	csame(complex(1.50000000000000000e+00, -2.25000000000000000e+00) - complex(5.00000000000000000e-01, 3.00000000000000000e+00), 0x3ff00000, 0x00000000, cast(int, 0xc0150000), 0x00000000)    # (1-5.25j)
	csame(complex(1.50000000000000000e+00, -2.25000000000000000e+00) * complex(5.00000000000000000e-01, 3.00000000000000000e+00), 0x401e0000, 0x00000000, 0x400b0000, 0x00000000)    # (7.5+3.375j)
	csame(complex(1.50000000000000000e+00, -2.25000000000000000e+00) / complex(5.00000000000000000e-01, 3.00000000000000000e+00), cast(int, 0xbfe4c1ba), cast(int, 0xcf914c1b), cast(int, 0xbfe3759f), 0x2298375a)    # (-0.6486486486486486-0.6081081081081081j)
	csame(complex_div(complex(1.50000000000000000e+00, -2.25000000000000000e+00), complex(5.00000000000000000e-01, 3.00000000000000000e+00)), cast(int, 0xbfe4c1ba), cast(int, 0xcf914c1b), cast(int, 0xbfe3759f), 0x2298375a)
	csame(complex(1.00000000000000005e+300, 1.00000000000000005e+300) + complex(1.00000000000000003e-300, 2.00000000000000005e-300), 0x7e37e43c, cast(int, 0x8800759c), 0x7e37e43c, cast(int, 0x8800759c))    # (1e+300+1e+300j)
	csame(complex(1.00000000000000005e+300, 1.00000000000000005e+300) - complex(1.00000000000000003e-300, 2.00000000000000005e-300), 0x7e37e43c, cast(int, 0x8800759c), 0x7e37e43c, cast(int, 0x8800759c))    # (1e+300+1e+300j)
	csame(complex(1.00000000000000005e+300, 1.00000000000000005e+300) * complex(1.00000000000000003e-300, 2.00000000000000005e-300), cast(int, 0xbff00000), 0x00000000, 0x40080000, 0x00000000)    # (-1+3j)
	csame(complex(1.00000000000000005e+300, 1.00000000000000005e+300) / complex(1.00000000000000003e-300, 2.00000000000000005e-300), 0x7ff00000, 0x00000000, cast(int, 0xfff00000), 0x00000000)    # (inf-infj)
	csame(complex_div(complex(1.00000000000000005e+300, 1.00000000000000005e+300), complex(1.00000000000000003e-300, 2.00000000000000005e-300)), 0x7ff00000, 0x00000000, cast(int, 0xfff00000), 0x00000000)
	csame(complex(-7.00000000000000000e+00, 1.00000000000000006e-01) + complex(3.29999999999999982e+00, -4.40000000000000036e+00), cast(int, 0xc00d9999), cast(int, 0x9999999a), cast(int, 0xc0113333), 0x33333334)    # (-3.7-4.300000000000001j)
	csame(complex(-7.00000000000000000e+00, 1.00000000000000006e-01) - complex(3.29999999999999982e+00, -4.40000000000000036e+00), cast(int, 0xc0249999), cast(int, 0x9999999a), 0x40120000, 0x00000000)    # (-10.3+4.5j)
	csame(complex(-7.00000000000000000e+00, 1.00000000000000006e-01) * complex(3.29999999999999982e+00, -4.40000000000000036e+00), cast(int, 0xc036a8f5), cast(int, 0xc28f5c28), 0x403f2147, cast(int, 0xae147ae2))    # (-22.659999999999997+31.130000000000003j)
	csame(complex(-7.00000000000000000e+00, 1.00000000000000006e-01) / complex(3.29999999999999982e+00, -4.40000000000000036e+00), cast(int, 0xbfe8e6dd), cast(int, 0x8e6dd8e5), cast(int, 0xbff01dca), 0x01dca01e)    # (-0.778181818181818-1.0072727272727273j)
	csame(complex_div(complex(-7.00000000000000000e+00, 1.00000000000000006e-01), complex(3.29999999999999982e+00, -4.40000000000000036e+00)), cast(int, 0xbfe8e6dd), cast(int, 0x8e6dd8e5), cast(int, 0xbff01dca), 0x01dca01e)
	csame(complex(1.00000000000000006e-01, 2.00000000000000011e-01) + complex(2.99999999999999989e-01, 0.00000000000000000e+00), 0x3fd99999, cast(int, 0x9999999a), 0x3fc99999, cast(int, 0x9999999a))    # (0.4+0.2j)
	csame(complex(1.00000000000000006e-01, 2.00000000000000011e-01) - complex(2.99999999999999989e-01, 0.00000000000000000e+00), cast(int, 0xbfc99999), cast(int, 0x99999999), 0x3fc99999, cast(int, 0x9999999a))    # (-0.19999999999999998+0.2j)
	csame(complex(1.00000000000000006e-01, 2.00000000000000011e-01) * complex(2.99999999999999989e-01, 0.00000000000000000e+00), 0x3f9eb851, cast(int, 0xeb851eb8), 0x3faeb851, cast(int, 0xeb851eb8))    # (0.03+0.06j)
	csame(complex(1.00000000000000006e-01, 2.00000000000000011e-01) / complex(2.99999999999999989e-01, 0.00000000000000000e+00), 0x3fd55555, 0x55555556, 0x3fe55555, 0x55555556)    # (0.33333333333333337+0.6666666666666667j)
	csame(complex_div(complex(1.00000000000000006e-01, 2.00000000000000011e-01), complex(2.99999999999999989e-01, 0.00000000000000000e+00)), 0x3fd55555, 0x55555556, 0x3fe55555, 0x55555556)
	csame(complex(2.00000000000000000e+00, 0.00000000000000000e+00) + complex(0.00000000000000000e+00, fldexp64(20240225330731.0, -1074)), 0x40000000, 0x00000000, 0x00001268, cast(int, 0x8b70e62b))    # (2+1e-310j)
	csame(complex(2.00000000000000000e+00, 0.00000000000000000e+00) - complex(0.00000000000000000e+00, fldexp64(20240225330731.0, -1074)), 0x40000000, 0x00000000, cast(int, 0x80001268), cast(int, 0x8b70e62b))    # (2-1e-310j)
	csame(complex(2.00000000000000000e+00, 0.00000000000000000e+00) * complex(0.00000000000000000e+00, fldexp64(20240225330731.0, -1074)), 0x00000000, 0x00000000, 0x000024d1, 0x16e1cc56)    # 2e-310j
	csame(complex(2.00000000000000000e+00, 0.00000000000000000e+00) / complex(0.00000000000000000e+00, fldexp64(20240225330731.0, -1074)), 0x00000000, 0x00000000, cast(int, 0xfff00000), 0x00000000)    # -infj
	csame(complex_div(complex(2.00000000000000000e+00, 0.00000000000000000e+00), complex(0.00000000000000000e+00, fldexp64(20240225330731.0, -1074))), 0x00000000, 0x00000000, cast(int, 0xfff00000), 0x00000000)


void test_complex_sqrt_reference():
	cnear(complex_sqrt(complex(4.00000000000000000e+00, 0.00000000000000000e+00)), 0x40000000, 0x00000000, 0x00000000, 0x00000000, 2)    # (2+0j)
	cnear(complex_sqrt(complex(-4.00000000000000000e+00, 0.00000000000000000e+00)), 0x00000000, 0x00000000, 0x40000000, 0x00000000, 2)    # 2j
	cnear(complex_sqrt(complex(-4.00000000000000000e+00, -0.00000000000000000e+00)), 0x00000000, 0x00000000, cast(int, 0xc0000000), 0x00000000, 2)    # -2j
	cnear(complex_sqrt(complex(0.00000000000000000e+00, 2.00000000000000000e+00)), 0x3ff00000, 0x00000000, 0x3ff00000, 0x00000000, 2)    # (1+1j)
	cnear(complex_sqrt(complex(3.00000000000000000e+00, 4.00000000000000000e+00)), 0x40000000, 0x00000000, 0x3ff00000, 0x00000000, 2)    # (2+1j)
	cnear(complex_sqrt(complex(-3.00000000000000000e+00, 4.00000000000000000e+00)), 0x3ff00000, 0x00000000, 0x40000000, 0x00000000, 2)    # (1+2j)
	cnear(complex_sqrt(complex(1.00000000000000003e-300, 1.00000000000000003e-300)), 0x20ccc579, 0x08682513, 0x20b7d5c1, cast(int, 0xe7ac01d9), 2)    # (1.09868411346781e-150+4.5508986056222734e-151j)
	cnear(complex_sqrt(complex(1.00000000000000005e+300, -1.00000000000000005e+300)), 0x5f157b24, 0x68f15c93, cast(int, 0xdf01cba3), 0x7a2eacf6, 2)    # (1.09868411346781e+150-4.550898605622274e+149j)
	cnear(complex_sqrt(complex(-fldexp64(2024.0, -1074), fldexp64(1012.0, -1074))), 0x1e95dbd1, cast(int, 0xfed4d2c3), 0x1eb72611, cast(int, 0x9c30a848), 2)    # (2.4293278360388177e-161+1.0290797853092896e-160j)
	cnear(complex_sqrt(complex(1.00000000000000000e+00, 9.99999999999999945e-21)), 0x3ff00000, 0x00000000, 0x3bb79ca1, 0x0c924223, 2)    # (1+5e-21j)
	cnear(complex_sqrt(complex(-2.50000000000000000e+00, -7.50000000000000000e-01)), 0x3fce0774, 0x0fc6075e, cast(int, 0xbff9933e), cast(int, 0xf74f50b5), 2)    # (0.23460245866959445-1.5984487209835099j)
	cnear(complex_sqrt(complex(1.00000000000000001e+308, 1.00000000000000001e+308)), 0x5fea38d1, cast(int, 0xf21aa181), 0x5fd5b915, 0x0ea5fa22, 2)    # (1.09868411346781e+154+4.5508986056222734e+153j)


void test_complex_exp_reference():
	cnear(complex_exp(complex(0.00000000000000000e+00, 0.00000000000000000e+00)), 0x3ff00000, 0x00000000, 0x00000000, 0x00000000, 3)    # (1+0j)
	cnear(complex_exp(complex(1.00000000000000000e+00, 0.00000000000000000e+00)), 0x4005bf0a, cast(int, 0x8b145769), 0x00000000, 0x00000000, 3)    # (2.718281828459045+0j)
	cnear(complex_exp(complex(1.00000000000000000e+00, 1.00000000000000000e+00)), 0x3ff77fc5, 0x377c5a96, 0x40024c80, cast(int, 0xedc62064), 3)    # (1.4686939399158851+2.2873552871788423j)
	cnear(complex_exp(complex(-1.50000000000000000e+00, 3.00000000000000000e+00)), cast(int, 0xbfcc465b), cast(int, 0xe3331f2b), 0x3fa01f36, 0x511ca59f, 3)    # (-0.22089718431220126+0.03148812999854588j)
	cnear(complex_exp(complex(5.00000000000000000e-01, -1.00000000000000000e+02)), 0x3ff6bf61, 0x1b2261c3, 0x3feab723, cast(int, 0x847a9e6f), 3)    # (1.4217234668668517+0.8348558032493666j)
	cnear(complex_exp(complex(7.09500000000000000e+02, 5.00000000000000000e-01)), 0x7fe52aba, 0x22deb5cc, 0x7fd72087, 0x3894974b, 3)    # (1.1891123654305422e+308+6.496150459387445e+307j)
	cnear(complex_exp(complex(7.10500000000000000e+02, 1.00000000000000000e+00)), 0x7ff00000, 0x00000000, 0x7ff00000, 0x00000000, 3)    # (inf+infj)
	cnear(complex_exp(complex(-7.45000000000000000e+02, 2.00000000000000000e+00)), cast(int, 0x80000000), 0x00000000, 0x00000000, 0x00000001, 3)    # (-0+5e-324j)
	cnear(complex_exp(complex(1.00000000000000004e-10, -1.00000000000000004e-10)), 0x3ff00000, 0x0006df38, cast(int, 0xbddb7cdf), cast(int, 0xd9e38c0c), 3)    # (1.0000000001-1.0000000001000001e-10j)
	cnear(complex_exp(complex(2.00000000000000000e+01, 1.57079632679489656e+00)), 0x3e5fe604, cast(int, 0x974c195f), 0x41bceb08, cast(int, 0x8b68e804), 3)    # (2.9707800180814988e-08+485165195.4097903j)


void test_complex_log_reference():
	cnear(complex_log(complex(1.00000000000000000e+00, 0.00000000000000000e+00)), 0x00000000, 0x00000000, 0x00000000, 0x00000000, 3)    # 0j
	cnear(complex_log(complex(-1.00000000000000000e+00, 0.00000000000000000e+00)), 0x00000000, 0x00000000, 0x400921fb, 0x54442d18, 3)    # 3.141592653589793j
	cnear(complex_log(complex(-1.00000000000000000e+00, -0.00000000000000000e+00)), 0x00000000, 0x00000000, cast(int, 0xc00921fb), 0x54442d18, 3)    # -3.141592653589793j
	cnear(complex_log(complex(0.00000000000000000e+00, 1.00000000000000000e+00)), 0x00000000, 0x00000000, 0x3ff921fb, 0x54442d18, 3)    # 1.5707963267948966j
	cnear(complex_log(complex(3.00000000000000000e+00, 4.00000000000000000e+00)), 0x3ff9c041, cast(int, 0xf7ed8d33), 0x3fedac67, 0x0561bb4f, 3)    # (1.6094379124341003+0.9272952180016122j)
	cnear(complex_log(complex(5.99999999999999978e-01, 8.00000000000000044e-01)), 0x3c799999, cast(int, 0x9999999a), 0x3fedac67, 0x0561bb50, 3)    # (2.2204460492503132e-17+0.9272952180016123j)
	cnear(complex_log(complex(1.00000010000000006e+00, 1.00000000000000008e-05)), 0x3e7adb62, 0x206b1752, 0x3ee4f8b5, 0x65b1358c, 3)    # (1.0004999504838454e-07+9.999998999666767e-06j)
	cnear(complex_log(complex(1.00000000000000005e+300, 1.00000000000000005e+300)), 0x408598fa, 0x10585efc, 0x3fe921fb, 0x54442d18, 3)    # (691.1221014884936+0.7853981633974483j)
	cnear(complex_log(complex(1.00000000000000003e-300, -1.00000000000000003e-300)), cast(int, 0xc085936e), 0x7f98a06e, cast(int, 0xbfe921fb), 0x54442d18, 3)    # (-690.4289543079337-0.7853981633974483j)
	cnear(complex_log(complex(-2.00000000000000000e+00, -3.00000000000000000e+00)), 0x3ff48504, 0x2b318c51, cast(int, 0xc0014538), 0x5fa3af71, 3)    # (1.2824746787307684-2.158798930342464j)
	cnear(complex_log(complex(1.79769313486231571e+308, 1.79769313486231571e+308)), 0x40863108, cast(int, 0xc75a1936), 0x3fe921fb, 0x54442d18, 3)    # (710.1292864836639+0.7853981633974483j)
	cnear(complex_log(complex(fldexp64(1.0, -1074), 0.00000000000000000e+00)), cast(int, 0xc0874385), 0x446d71c3, 0x00000000, 0x00000000, 3)    # (-744.4400719213812+0j)
