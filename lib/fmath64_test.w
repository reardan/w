# wbuild: arch_only=x64
# wbuild: target=fmath64_leak_test tag=tests_x64 dep=fmath64_test
# wbuild: step="bin/fmath64_test" env="W_TEST_LEAKS=1" expect_stdout="0 failed, 0 skipped [leak check]"
# Tests for lib/fmath64.w's Python math extras (the older transcendental
# section keeps its coverage in tests/x64_fmath64_test.w). float64 is
# x64-only, so this test has no 32-bit twin.
#
# Reference values are mpmath results at 80 digits, correctly rounded to
# float64 and embedded as bit patterns (hi word, lo word: integer literals
# are limited to 32 bits, see lib/fmath64.w's header). Tolerances are the
# measured worst case from mpmath sweeps of tens of thousands of points
# per function, rounded up to whole ulps: 1 ulp for the dd-evaluated
# functions (measured <= ~0.8), 2 for erfc and negative-argument
# gamma/lgamma.
import lib.testing
import lib.fmath64


float64 f64(int hi, int lo):
	int mask32 = (1 << 32) - 1
	return float64_from_bits((hi << 32) | (lo & mask32))


# float64 bits mapped to an integer line where adjacent floats differ by
# one, negative values below positive ones (+0 and -0 coincide).
int ulp_key(float64 f):
	int b = float64_bits(f)
	if (b < 0): return 0 - (b & ((1 << 63) - 1))
	return b


void fail_bits(char* what, float64 want, float64 got):
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


# got within max_ulp ulps of the float64 with bits (want_hi, want_lo).
void near(float64 got, int want_hi, int want_lo, int max_ulp):
	float64 want = f64(want_hi, want_lo)
	int d = ulp_key(got) - ulp_key(want)
	if (d < 0): d = 0 - d
	if (f64is_nan(got) || d > max_ulp): fail_bits(c"ulp distance too large", want, got)


# Bit-exact equality (distinguishes -0.0 from 0.0; NaN payloads aside,
# use is_nan for NaN).
void same(float64 want, float64 got):
	if (float64_bits(want) != float64_bits(got)): fail_bits(c"bits differ", want, got)


void is_nan(float64 got):
	if (f64is_nan(got) == 0): fail_bits(c"expected NaN", float64_from_bits(0x7ff8 << 48), got)


float64 inf():
	return float64_from_bits(0x7ff << 52)


float64 nan():
	return float64_from_bits(0x7ff8 << 48)


float64 negzero():
	return float64_from_bits(1 << 63)


void test_predicates():
	assert1(f64is_inf(inf()))
	assert1(f64is_inf(-inf()))
	assert1(f64is_inf(1.0e308) == 0)
	assert1(f64is_inf(nan()) == 0)
	assert1(f64is_finite(0.0))
	assert1(f64is_finite(-1.0e308))
	assert1(f64is_finite(float64_from_bits(1)))
	assert1(f64is_finite(inf()) == 0)
	assert1(f64is_finite(nan()) == 0)


void test_copysign():
	same(-2.5, fcopysign64(2.5, -0.0 - 1.0))
	same(2.5, fcopysign64(-2.5, 3.0))
	same(negzero(), fcopysign64(0.0, negzero()))
	same(0.0, fcopysign64(negzero(), 1.0))
	same(-inf(), fcopysign64(inf(), -1.0))
	is_nan(fcopysign64(nan(), -1.0))
	assert1(float64_bits(fcopysign64(nan(), -1.0)) < 0)


void test_ldexp():
	same(8.0, fldexp64(1.0, 3))
	same(0.375, fldexp64(3.0, -3))
	same(-0.75, fldexp64(-3.0, -2))
	same(inf(), fldexp64(1.0, 1024))
	same(-inf(), fldexp64(-1.5, 1023 + 1))
	same(f64(0x7fe00000, 0), fldexp64(1.0, 1023))
	# into and out of the subnormal range, rounding once
	same(float64_from_bits(1), fldexp64(1.0, -1074))
	same(0.0, fldexp64(1.0, -1076))
	same(float64_from_bits(1), fldexp64(1.5, -1075))    # 0.75 * 2^-1074 rounds up
	same(float64_from_bits(2), fldexp64(1.5, -1074))    # tie rounds to even
	same(float64_from_bits(1 << 51), fldexp64(1.0, -1023))
	same(1.0, fldexp64(float64_from_bits(1), 1074))
	same(f64(0x00100000, 0), fldexp64(float64_from_bits(1 << 51), 1))
	same(negzero(), fldexp64(-1.0, -2000))
	same(1.5, fldexp64(1.5, 0))
	same(0.0, fldexp64(0.0, 100))
	same(negzero(), fldexp64(negzero(), -5))
	same(inf(), fldexp64(inf(), -5000))
	is_nan(fldexp64(nan(), 3))
	same(inf(), fldexp64(1.0e-300, 5000))


void test_hypot_edges():
	same(inf(), fhypot64(inf(), nan()))
	same(inf(), fhypot64(nan(), -inf()))
	is_nan(fhypot64(nan(), 1.0))
	is_nan(fhypot64(1.0, nan()))
	same(3.0, fhypot64(-3.0, 0.0))
	same(0.0, fhypot64(negzero(), negzero()))
	same(1.0e300, fhypot64(1.0e300, 1.0e-300))
	same(inf(), fhypot64(1.5e308, 1.5e308))


void test_isclose():
	assert1(fisclose64(1.0, 1.0))
	assert1(fisclose64(1.0, 1.0 + 1.0e-10))
	assert1(fisclose64(1.0, 1.0 + 1.0e-8) == 0)
	assert1(fisclose64(0.0, 1.0e-300) == 0)
	assert1(fisclose_tol64(0.0, 1.0e-300, 1.0e-9, 1.0e-299))
	assert1(fisclose64(inf(), inf()))
	assert1(fisclose64(-inf(), inf()) == 0)
	assert1(fisclose64(inf(), 1.0e308) == 0)
	assert1(fisclose64(nan(), nan()) == 0)
	assert1(fisclose64(nan(), 1.0) == 0)
	assert1(fisclose_tol64(100.0, 105.0, 0.05, 0.0))
	assert1(fisclose_tol64(100.0, 106.0, 0.05, 0.0) == 0)
	assert1(fisclose_tol64(105.0, 100.0, 0.05, 0.0))
	assert1(fisclose_tol64(1.0, 2.0, -1.0, 5.0) == 0)
	assert1(fisclose_tol64(1.0, 2.0, 0.0, -1.0) == 0)
	assert1(fisclose_tol64(1.0, 2.0, nan(), 5.0) == 0)
	assert1(fisclose_tol64(1.0e308, -1.0e308, 0.0, inf()))
	assert1(fisclose64(negzero(), 0.0))


void test_exp_family_edges():
	is_nan(fexpm164(nan()))
	same(inf(), fexpm164(inf()))
	same(-1.0, fexpm164(-inf()))
	same(-1.0, fexpm164(-40.0))
	same(inf(), fexpm164(709.8))
	same(negzero(), fexpm164(negzero()))
	same(0.0, fexpm164(0.0))
	is_nan(flog1p64(nan()))
	is_nan(flog1p64(-1.5))
	is_nan(flog1p64(-inf()))
	same(-inf(), flog1p64(-1.0))
	same(inf(), flog1p64(inf()))
	same(negzero(), flog1p64(negzero()))
	same(1.0e-300, flog1p64(1.0e-300))


void test_hyperbolic_edges():
	is_nan(fsinh64(nan()))
	same(inf(), fsinh64(inf()))
	same(-inf(), fsinh64(-inf()))
	same(-inf(), fsinh64(-711.0))
	same(negzero(), fsinh64(negzero()))
	is_nan(fcosh64(nan()))
	same(inf(), fcosh64(-inf()))
	same(inf(), fcosh64(711.0))
	same(1.0, fcosh64(negzero()))
	is_nan(ftanh64(nan()))
	same(1.0, ftanh64(inf()))
	same(-1.0, ftanh64(-inf()))
	same(-1.0, ftanh64(-30.0))
	same(negzero(), ftanh64(negzero()))
	is_nan(fasinh64(nan()))
	same(-inf(), fasinh64(-inf()))
	same(negzero(), fasinh64(negzero()))
	is_nan(facosh64(nan()))
	is_nan(facosh64(0.5))
	is_nan(facosh64(-inf()))
	same(0.0, facosh64(1.0))
	same(inf(), facosh64(inf()))
	is_nan(fatanh64(nan()))
	is_nan(fatanh64(1.5))
	same(inf(), fatanh64(1.0))
	same(-inf(), fatanh64(-1.0))
	same(negzero(), fatanh64(negzero()))


void test_erf_edges():
	is_nan(ferf64(nan()))
	same(1.0, ferf64(inf()))
	same(-1.0, ferf64(-inf()))
	same(1.0, ferf64(6.0))
	same(-1.0, ferf64(-30.0))
	same(negzero(), ferf64(negzero()))
	is_nan(ferfc64(nan()))
	same(0.0, ferfc64(inf()))
	same(2.0, ferfc64(-inf()))
	same(2.0, ferfc64(-6.5))
	same(1.0, ferfc64(0.0))
	same(0.0, ferfc64(28.0))
	# erf(x) + erfc(x) == 1 to rounding across the kernel boundaries
	assert1(fisclose_tol64(ferf64(0.84375) + ferfc64(0.84375), 1.0, 1.0e-15, 0.0))
	assert1(fisclose_tol64(ferf64(1.25) + ferfc64(1.25), 1.0, 1.0e-15, 0.0))


void test_gamma_edges():
	is_nan(fgamma64(nan()))
	same(inf(), fgamma64(inf()))
	is_nan(fgamma64(-inf()))
	same(inf(), fgamma64(0.0))
	same(-inf(), fgamma64(negzero()))
	is_nan(fgamma64(-1.0))
	is_nan(fgamma64(-2.0e20))
	same(inf(), fgamma64(171.7))
	same(inf(), fgamma64(1.0e10))
	# small integers are exact: (n - 1)!
	same(1.0, fgamma64(1.0))
	same(1.0, fgamma64(2.0))
	same(6.0, fgamma64(4.0))
	same(3628800.0, fgamma64(11.0))
	same(f64(0x444e7752, 0x6159f06c), fgamma64(23.0))    # 22!
	near(fgamma64(24.0), 0x4495e5c3, 0x35f8a4ce, 1)    # 23!, no longer exact
	# beyond -184 the result underflows to a zero with Gamma's sign
	same(negzero(), fgamma64(-184.5))
	same(0.0, fgamma64(-185.5))
	is_nan(flgamma64(nan()))
	same(inf(), flgamma64(inf()))
	same(inf(), flgamma64(-inf()))
	same(inf(), flgamma64(0.0))
	same(inf(), flgamma64(-3.0))
	same(inf(), flgamma64(-1.0e20))
	same(0.0, flgamma64(1.0))
	same(0.0, flgamma64(2.0))
	same(inf(), flgamma64(1.0e308))


void test_fexpm164_reference():
	near(fexpm164(1.00000000000000003e-300), 0x01a56e1f, cast(int, 0xc2f8f359), 1)    # 1e-300
	near(fexpm164(-9.99999999999999945e-21), cast(int, 0xbbc79ca1), 0x0c924223, 1)    # -1e-20
	near(fexpm164(1.00000000000000004e-10), 0x3ddb7cdf, cast(int, 0xd9dda4e3), 1)    # 1.00000000005e-10
	near(fexpm164(1.00000000000000008e-05), 0x3ee4f8bc, 0x681cdfb6, 1)    # 1.0000050000166668e-05
	near(fexpm164(-1.00000000000000002e-03), cast(int, 0xbf506035), 0x21cac48c, 1)    # -0.0009995001666250085
	near(fexpm164(1.00000000000000006e-01), 0x3fbaec7b, 0x35a00d3a, 1)    # 0.10517091807564763
	near(fexpm164(-2.50000000000000000e-01), cast(int, 0xbfcc5041), cast(int, 0x854df7d4), 1)    # -0.22119921692859512
	near(fexpm164(3.46573590279972643e-01), 0x3fda8279, cast(int, 0x99fcef32), 1)    # 0.41421356237309503
	near(fexpm164(5.00000000000000000e-01), 0x3fe4c253, 0x1c3c0d38, 1)    # 0.6487212707001282
	near(fexpm164(-6.89999999999999947e-01), cast(int, 0xbfdfe62d), 0x7cb9ec68, 1)    # -0.49842393093394444
	near(fexpm164(1.00000000000000000e+00), 0x3ffb7e15, 0x1628aed3, 1)    # 1.7182818284590453
	near(fexpm164(-1.00000000000000000e+00), cast(int, 0xbfe43a54), cast(int, 0xe4e98864), 1)    # -0.6321205588285577
	near(fexpm164(2.50000000000000000e+00), 0x40265d6f, cast(int, 0xd931e0bb), 1)    # 11.182493960703473
	near(fexpm164(1.00000000000000000e+01), 0x40d5825d, cast(int, 0xcf950560), 1)    # 22025.465794806718
	near(fexpm164(-2.00000000000000000e+01), cast(int, 0xbfefffff), cast(int, 0xfee4b79b), 1)    # -0.9999999979388464
	near(fexpm164(-3.75000000000000000e+01), cast(int, 0xbff00000), 0x00000000, 1)    # -1.0
	near(fexpm164(1.00000000000000000e+02), 0x48f3494a, cast(int, 0x9b171bf5), 1)    # 2.6881171418161356e+43
	near(fexpm164(7.00000000000000000e+02), 0x7f0d945d, cast(int, 0xf4f8ec8e), 1)    # 1.0142320547350045e+304
	near(fexpm164(7.09779999999999973e+02), 0x7fefe9ce, 0x5c4c52b4, 1)    # 1.7928227943945155e+308


void test_flog1p64_reference():
	near(flog1p64(1.00000000000000003e-300), 0x01a56e1f, cast(int, 0xc2f8f359), 1)    # 1e-300
	near(flog1p64(-9.99999999999999945e-21), cast(int, 0xbbc79ca1), 0x0c924223, 1)    # -1e-20
	near(flog1p64(1.00000000000000004e-10), 0x3ddb7cdf, cast(int, 0xd9d1d693), 1)    # 9.999999999500001e-11
	near(flog1p64(-9.99999999999999955e-08), cast(int, 0xbe7ad7f2), cast(int, 0xb1414ae8), 1)    # -1.0000000500000033e-07
	near(flog1p64(1.99999999999999991e-06), 0x3ec0c6f6, cast(int, 0x873c6e13), 1)    # 1.9999980000026667e-06
	near(flog1p64(-1.00000000000000002e-03), cast(int, 0xbf506467), 0x0d979b6f, 1)    # -0.0010005003335835335
	near(flog1p64(1.00000000000000006e-01), 0x3fb8663f, 0x793c46c7, 1)    # 0.09531017980432487
	near(flog1p64(-5.00000000000000000e-01), cast(int, 0xbfe62e42), cast(int, 0xfefa39ef), 1)    # -0.6931471805599453
	near(flog1p64(-9.00000000000000022e-01), cast(int, 0xc0026bb1), cast(int, 0xbbb55516), 1)    # -2.302585092994046
	near(flog1p64(-9.99998999999999971e-01), cast(int, 0xc02ba18a), cast(int, 0x998fc064), 1)    # -13.815510557935518
	near(flog1p64(7.50000000000000000e-01), 0x3fe1e85f, 0x5e7040d0, 1)    # 0.5596157879354227
	near(flog1p64(1.00000000000000000e+00), 0x3fe62e42, cast(int, 0xfefa39ef), 1)    # 0.6931471805599453
	near(flog1p64(3.50000000000000000e+00), 0x3ff810b3, 0x75dce91e, 1)    # 1.5040773967762742
	near(flog1p64(1.00000000000000000e+10), 0x4037069e, 0x2aa3184e, 1)    # 23.025850930040455
	near(flog1p64(1.00000000000000005e+300), 0x40859634, 0x47f87fb5, 1)    # 690.7755278982137


void test_fsinh64_reference():
	near(fsinh64(1.00000000000000004e-10), 0x3ddb7cdf, cast(int, 0xd9d7bdbb), 1)    # 1e-10
	near(fsinh64(-1.00000000000000008e-05), cast(int, 0xbee4f8b5), cast(int, 0x88e4e940), 1)    # -1.0000000000166668e-05
	near(fsinh64(1.00000000000000006e-01), 0x3fb9a487, 0x337b59b3, 1)    # 0.10016675001984403
	near(fsinh64(-5.00000000000000000e-01), cast(int, 0xbfe0acd0), 0x0fe63b97, 1)    # -0.5210953054937474
	near(fsinh64(1.00000000000000000e+00), 0x3ff2cd9f, cast(int, 0xc44eb982), 1)    # 1.1752011936438014
	near(fsinh64(3.00000000000000000e+00), 0x40240926, cast(int, 0xe70949ae), 1)    # 10.017874927409903
	near(fsinh64(-1.00000000000000000e+01), cast(int, 0xc0c5829d), cast(int, 0xced69992), 1)    # -11013.232874703393
	near(fsinh64(2.18999999999999986e+01), 0x41d82afc, cast(int, 0xca727c17), 1)    # 1621881641.7888238
	near(fsinh64(2.25000000000000000e+01), 0x41e604b6, cast(int, 0x8cf05f66), 1)    # 2955261031.5116453
	near(fsinh64(-1.00000000000000000e+02), cast(int, 0xc8e3494a), cast(int, 0x9b171bf5), 1)    # -1.3440585709080678e+43
	near(fsinh64(7.09000000000000000e+02), 0x7fcd422d, 0x2be5dc9b, 1)    # 4.109203730777486e+307
	near(fsinh64(7.10399999999999977e+02), 0x7feda98a, 0x7371610b, 1)    # 1.6663642832806496e+308


void test_fcosh64_reference():
	near(fcosh64(1.00000000000000008e-05), 0x3ff00000, 0x00036f9c, 1)    # 1.00000000005
	near(fcosh64(1.00000000000000006e-01), 0x3ff0147f, 0x40224b38, 1)    # 1.0050041680558035
	near(fcosh64(-5.00000000000000000e-01), 0x3ff20ac1, cast(int, 0x862ae8d0), 1)    # 1.1276259652063807
	near(fcosh64(1.00000000000000000e+00), 0x3ff8b075, 0x51d9f550, 1)    # 1.5430806348152437
	near(fcosh64(3.00000000000000000e+00), 0x402422a4, cast(int, 0x97d6185e), 1)    # 10.067661995777765
	near(fcosh64(-1.00000000000000000e+01), 0x40c5829d, cast(int, 0xd053712d), 1)    # 11013.232920103323
	near(fcosh64(2.18999999999999986e+01), 0x41d82afc, cast(int, 0xca727c17), 1)    # 1621881641.7888238
	near(fcosh64(2.25000000000000000e+01), 0x41e604b6, cast(int, 0x8cf05f66), 1)    # 2955261031.5116453
	near(fcosh64(1.00000000000000000e+02), 0x48e3494a, cast(int, 0x9b171bf5), 1)    # 1.3440585709080678e+43
	near(fcosh64(-7.10399999999999977e+02), 0x7feda98a, 0x7371610b, 1)    # 1.6663642832806496e+308


void test_ftanh64_reference():
	near(ftanh64(1.00000000000000004e-10), 0x3ddb7cdf, cast(int, 0xd9d7bdbb), 1)    # 1e-10
	near(ftanh64(-1.00000000000000008e-05), cast(int, 0xbee4f8b5), cast(int, 0x88e06854), 1)    # -9.999999999666668e-06
	near(ftanh64(1.00000000000000006e-01), 0x3fb983d7, 0x795f413a, 1)    # 0.09966799462495582
	near(ftanh64(-5.00000000000000000e-01), cast(int, 0xbfdd9353), cast(int, 0xd7568af3), 1)    # -0.46211715726000974
	near(ftanh64(9.00000000000000022e-01), 0x3fe6ebe9, cast(int, 0x82d6605d), 1)    # 0.7162978701990245
	near(ftanh64(1.00000000000000000e+00), 0x3fe85efa, cast(int, 0xb514f394), 1)    # 0.7615941559557649
	near(ftanh64(-3.00000000000000000e+00), cast(int, 0xbfefd77d), 0x111a0b00, 1)    # -0.9950547536867305
	near(ftanh64(1.00000000000000000e+01), 0x3fefffff, cast(int, 0xfdc96f35), 1)    # 0.9999999958776927
	near(ftanh64(1.80000000000000000e+01), 0x3fefffff, cast(int, 0xfffffffc), 1)    # 0.9999999999999996
	near(ftanh64(2.19899999999999984e+01), 0x3ff00000, 0x00000000, 1)    # 1.0


void test_fasinh64_reference():
	near(fasinh64(1.00000000000000004e-10), 0x3ddb7cdf, cast(int, 0xd9d7bdbb), 1)    # 1e-10
	near(fasinh64(-1.00000000000000008e-05), cast(int, 0xbee4f8b5), cast(int, 0x88e1e8a2), 1)    # -9.999999999833334e-06
	near(fasinh64(1.00000000000000006e-01), 0x3fb98eb9, cast(int, 0xe7e5fc3e), 1)    # 0.09983407889920756
	near(fasinh64(-5.00000000000000000e-01), cast(int, 0xbfdecc2c), cast(int, 0xaec5160a), 1)    # -0.48121182505960347
	near(fasinh64(1.00000000000000000e+00), 0x3fec3436, 0x6179d427, 1)    # 0.881373587019543
	near(fasinh64(2.00000000000000000e+00), 0x3ff71921, cast(int, 0x8313d087), 1)    # 1.4436354751788103
	near(fasinh64(-1.00000000000000000e+01), cast(int, 0xc007fc5c), 0x506d2bdb, 1)    # -2.99822295029797
	near(fasinh64(1.00000000000000000e+05), 0x40286982, 0x5a9284f4, 1)    # 12.206072645555174
	near(fasinh64(3.00000000000000000e+08), 0x40343662, 0x7b57f716, 1)    # 20.21244021318042
	near(fasinh64(-1.00000000000000005e+300), cast(int, 0xc0859bbf), cast(int, 0xd8b83e44), 1)    # -691.4686750787737


void test_facosh64_reference():
	near(facosh64(1.00000000010000001e+00), 0x3eeda880, 0x667f3b17, 1)    # 1.4142136208675862e-05
	near(facosh64(1.00099999999999989e+00), 0x3fa6e53a, cast(int, 0xcbcdeba3), 1)    # 0.04471763360830685
	near(facosh64(1.50000000000000000e+00), 0x3feecc2c, cast(int, 0xaec5160a), 1)    # 0.9624236501192069
	near(facosh64(2.00000000000000000e+00), 0x3ff51242, 0x71980435, 1)    # 1.3169578969248168
	near(facosh64(1.00000000000000000e+01), 0x4007f21e, cast(int, 0xd1ce05d4), 1)    # 2.993222846126381
	near(facosh64(1.00000000000000000e+05), 0x40286982, 0x5a921700, 1)    # 12.206072645505174
	near(facosh64(3.00000000000000000e+08), 0x40343662, 0x7b57f716, 1)    # 20.21244021318042
	near(facosh64(1.00000000000000005e+300), 0x40859bbf, cast(int, 0xd8b83e44), 1)    # 691.4686750787737


void test_fatanh64_reference():
	near(fatanh64(1.00000000000000004e-10), 0x3ddb7cdf, cast(int, 0xd9d7bdbb), 1)    # 1e-10
	near(fatanh64(-1.00000000000000008e-05), cast(int, 0xbee4f8b5), cast(int, 0x88e6698e), 1)    # -1.0000000000333334e-05
	near(fatanh64(1.00000000000000006e-01), 0x3fb9af93, cast(int, 0xcd234412), 1)    # 0.10033534773107558
	near(fatanh64(-5.00000000000000000e-01), cast(int, 0xbfe193ea), 0x7aad030b, 1)    # -0.5493061443340549
	near(fatanh64(7.50000000000000000e-01), 0x3fef2272, cast(int, 0xae325a57), 1)    # 0.9729550745276566
	near(fatanh64(9.89999999999999991e-01), 0x40052c58, 0x1997cd85, 1)    # 2.6466524123622457
	near(fatanh64(-9.99998999999999971e-01), cast(int, 0xc01d046e), cast(int, 0xb8b86c1c), 1)    # -7.254328619247669
	near(fatanh64(9.99999999999999889e-01), 0x4032b708, cast(int, 0x872320e2), 1)    # 18.714973875118524


void test_ferf64_reference():
	near(ferf64(1.00000000000000003e-300), 0x01a82e6d, cast(int, 0x98711d3a), 1)    # 1.1283791670955126e-300
	near(ferf64(1.00000000000000004e-10), 0x3ddf0443, 0x32d68161, 1)    # 1.1283791670955126e-10
	near(ferf64(-1.00000000000000008e-05), cast(int, 0xbee7a9f0), cast(int, 0x84b5e44c), 1)    # -1.1283791670579e-05
	near(ferf64(1.00000000000000006e-01), 0x3fbcca5e, cast(int, 0xa24fb334), 1)    # 0.1124629160182849
	near(ferf64(5.00000000000000000e-01), 0x3fe0a7ef, 0x5c18edd2, 1)    # 0.5204998778130465
	near(ferf64(-8.39999999999999969e-01), cast(int, 0xbfe87c0c), cast(int, 0x914f1a58), 1)    # -0.7651427114549945
	near(ferf64(8.49999999999999978e-01), 0x3fe8a950, 0x0eeffdb1, 1)    # 0.7706680576083526
	near(ferf64(1.00000000000000000e+00), 0x3feaf767, cast(int, 0xa741088b), 1)    # 0.8427007929497149
	near(ferf64(-1.19999999999999996e+00), cast(int, 0xbfed214a), cast(int, 0xc7b2d067), 1)    # -0.9103139782296353
	near(ferf64(1.30000000000000004e+00), 0x3fede364, cast(int, 0xa1372d3a), 1)    # 0.9340079449406524
	near(ferf64(2.00000000000000000e+00), 0x3fefd9ae, 0x142795e3, 1)    # 0.9953222650189527
	near(ferf64(-3.00000000000000000e+00), cast(int, 0xbfefffd1), cast(int, 0xac4135f9), 1)    # -0.9999779095030014
	near(ferf64(4.00000000000000000e+00), 0x3fefffff, cast(int, 0xf7b91176), 1)    # 0.9999999845827421
	near(ferf64(5.90000000000000036e+00), 0x3fefffff, cast(int, 0xffffffff), 1)    # 0.9999999999999999


void test_ferfc64_reference():
	near(ferfc64(1.00000000000000004e-10), 0x3fefffff, cast(int, 0xfff07dde), 2)    # 0.999999999887162
	near(ferfc64(-1.00000000000000008e-05), 0x3ff0000b, cast(int, 0xd4f8425b), 2)    # 1.0000112837916706
	near(ferfc64(1.00000000000000006e-01), 0x3fec66b4, 0x2bb60999, 2)    # 0.887537083981715
	near(ferfc64(5.00000000000000000e-01), 0x3fdeb021, 0x47ce245c, 2)    # 0.4795001221869535
	near(ferfc64(-8.39999999999999969e-01), 0x3ffc3e06, 0x48a78d2c, 2)    # 1.7651427114549945
	near(ferfc64(8.49999999999999978e-01), 0x3fcd5abf, cast(int, 0xc440093d), 2)    # 0.22933194239164748
	near(ferfc64(1.00000000000000000e+00), 0x3fc42261, 0x62fbddd5, 2)    # 0.15729920705028513
	near(ferfc64(-1.19999999999999996e+00), 0x3ffe90a5, 0x63d96834, 2)    # 1.9103139782296354
	near(ferfc64(1.30000000000000004e+00), 0x3fb0e4da, cast(int, 0xf646962e), 2)    # 0.06599205505934755
	near(ferfc64(2.00000000000000000e+00), 0x3f7328f5, cast(int, 0xec350e67), 2)    # 0.004677734981047266
	near(ferfc64(-3.00000000000000000e+00), 0x3fffffe8, cast(int, 0xd6209afd), 2)    # 1.9999779095030015
	near(ferfc64(4.00000000000000000e+00), 0x3e508ddd, 0x13bd35e7, 2)    # 1.541725790028002e-08
	near(ferfc64(5.90000000000000036e+00), 0x3c94b996, 0x01a343be, 2)    # 7.190409783550478e-17
	near(ferfc64(6.50000000000000000e+00), 0x3be6ae17, 0x2414ceba, 2)    # 3.8421483271206475e-20
	near(ferfc64(1.00000000000000000e+01), 0x36a7d8a7, cast(int, 0xf2a8a2d0), 2)    # 2.088487583762545e-45
	near(ferfc64(2.00000000000000000e+01), 0x1b8b54f2, 0x44df93df, 2)    # 5.395865611607901e-176
	near(ferfc64(2.65000000000000000e+01), 0x0043df67, 0x25a60cf5, 2)    # 2.2109076642637343e-307
	near(ferfc64(2.71999999999999993e+01), 0x00000000, 0x00000002, 2)    # 1e-323


void test_fgamma64_reference():
	near(fgamma64(1.00000000000000004e-10), 0x4202a05f, 0x1ffb61dd, 1)    # 9999999999.422785
	near(fgamma64(1.00000000000000002e-03), 0x408f3b63, cast(int, 0xe2d41242), 1)    # 999.4237724845955
	near(fgamma64(1.00000000000000006e-01), 0x402306ea, 0x7b280d87, 1)    # 9.51350769866873
	near(fgamma64(5.00000000000000000e-01), 0x3ffc5bf8, cast(int, 0x91b4ef6b), 1)    # 1.772453850905516
	near(fgamma64(1.50000000000000000e+00), 0x3fec5bf8, cast(int, 0x91b4ef6b), 1)    # 0.886226925452758
	near(fgamma64(2.50000000000000000e+00), 0x3ff544fa, 0x6d47b390, 1)    # 1.329340388179137
	near(fgamma64(3.70000000000000018e+00), 0x4010aebf, 0x5759a454, 1)    # 4.170651783796604
	near(fgamma64(5.25000000000000000e+00), 0x40419b16, 0x18e19c3d, 1)    # 35.211611852799685
	near(fgamma64(1.00999999999999996e+01), 0x411bc1a3, 0x0179e72c, 1)    # 454760.7514415856
	near(fgamma64(2.45000000000000000e+01), 0x44baadf7, 0x49e77e83, 1)    # 1.2599063430729375e+23
	near(fgamma64(5.02999999999999972e+01), 0x4d1315e3, 0x53408efc, 1)    # 1.9628298224091644e+63
	near(fgamma64(1.00700000000000003e+02), 0x609b4a58, cast(int, 0xdf808dfe), 1)    # 2.3417900214543305e+157
	near(fgamma64(1.50250000000000000e+02), 0x7625a912, 0x1ac859ed, 1)    # 1.3321507761951635e+261
	near(fgamma64(1.71500000000000000e+02), 0x7fe0e186, 0x3dcad789, 1)    # 9.4833675668248e+307
	near(fgamma64(-1.00000000000000004e-10), cast(int, 0xc202a05f), 0x20049e23, 2)    # -10000000000.577215
	near(fgamma64(-5.00000000000000000e-01), cast(int, 0xc00c5bf8), cast(int, 0x91b4ef6b), 2)    # -3.544907701811032
	near(fgamma64(-1.50000000000000000e+00), 0x4002e7fb, 0x0bcdf4f2, 2)    # 2.363271801207355
	near(fgamma64(-2.50000000000000000e+00), cast(int, 0xbfee3ff8), 0x12e32183, 2)    # -0.9453087204829419
	near(fgamma64(-3.29999999999999982e+00), 0x3fdc10ab, 0x408e231c, 2)    # 0.43851739219876307
	near(fgamma64(-1.00999999999999996e+01), cast(int, 0xbec29146), cast(int, 0xa296668a), 2)    # -2.2134165830856185e-06
	near(fgamma64(-3.37000000000000028e+01), 0x3829dcef, 0x06a5d532, 2)    # 3.8002295682917067e-38
	near(fgamma64(-1.00500000000000000e+02), cast(int, 0x9f07932f), cast(int, 0xb5136292), 2)    # -3.3536908198076787e-159
	near(fgamma64(-1.70250000000000000e+02), cast(int, 0x803e7334), cast(int, 0xb3b3c801), 2)    # -1.6938387496514192e-307
	near(fgamma64(-1.83900000000000006e+02), 0x00000000, 0x00000000, 2)    # 0.0


void test_flgamma64_reference():
	near(flgamma64(1.00000000000000003e-300), 0x40859634, 0x47f87fb5, 1)    # 690.7755278982137
	near(flgamma64(1.00000000000000004e-10), 0x4037069e, 0x2aa26ae4, 1)    # 23.025850929882736
	near(flgamma64(1.00000000000000006e-01), 0x4002058e, 0x35f3deee, 1)    # 2.252712651734206
	near(flgamma64(5.00000000000000000e-01), 0x3fe250d0, 0x48e7a1bd, 1)    # 0.5723649429247001
	near(flgamma64(9.98999999999999999e-01), 0x3f42f0f0, 0x4c1bbb44, 1)    # 0.0005780385328913802
	near(flgamma64(1.00000010000000006e+00), cast(int, 0xbe6efd30), cast(int, 0xc8e518b9), 1)    # -5.772155829918507e-08
	near(flgamma64(1.30000000000000004e+00), cast(int, 0xbfbbb158), 0x251658ad, 1)    # -0.10817480950786047
	near(flgamma64(1.50000000000000000e+00), cast(int, 0xbfbeeb95), cast(int, 0xb094c191), 1)    # -0.12078223763524522
	near(flgamma64(1.99900000000000011e+00), cast(int, 0xbf3bafbb), cast(int, 0x9e26f3e4), 1)    # -0.0004224618006921073
	near(flgamma64(2.00010000000000021e+00), 0x3f062af2, cast(int, 0xb5e4f9fb), 1)    # 4.2281658112919945e-05
	near(flgamma64(2.50000000000000000e+00), 0x3fd2383e, cast(int, 0x809a67e8), 1)    # 0.2846828704729192
	near(flgamma64(3.00010000000000021e+00), 0x3fe62f04, cast(int, 0x85a4f2f5), 1)    # 0.6932394609681
	near(flgamma64(7.50000000000000000e+00), 0x401e2330, 0x60e41f7f, 1)    # 7.534364236758733
	near(flgamma64(1.00500000000000000e+02), 0x407696f7, cast(int, 0xf9481308), 1)    # 361.4355404677776
	near(flgamma64(1.00000000000000000e+10), 0x4249a437, 0x10f467c1, 1)    # 220258509288.81058
	near(flgamma64(1.00000000000000000e+17), 0x43ca77b9, cast(int, 0xddb24c20), 1)    # 3.8143946580898775e+18
	near(flgamma64(1.00000000000000005e+300), 0x7ed017f3, cast(int, 0x8e7a1ab5), 1)    # 6.897755278982137e+302
	near(flgamma64(-1.00000000000000004e-10), 0x4037069e, 0x2aa2e9d2, 2)    # 23.025850929998178
	near(flgamma64(-5.00000000000000000e-01), 0x3ff43f89, cast(int, 0xa3f0edd6), 2)    # 1.2655121234846454
	near(flgamma64(-1.50000000000000000e+00), 0x3feb8581, 0x51820f86, 2)    # 0.860047015376481
	near(flgamma64(-3.50000000000000000e+00), cast(int, 0xbff4f1b0), cast(int, 0xfe64a5d8), 2)    # -1.309006684993042
	near(flgamma64(-1.00999999999999996e+01), cast(int, 0xc02a0abd), 0x02322b48, 2)    # -13.0209732710115
	near(flgamma64(-1.00250000000000000e+02), cast(int, 0xc076b66a), 0x2e797b34, 2)    # -363.4009232278215
	near(flgamma64(-1.00000000005000000e+10), cast(int, 0xc249a437), 0x11051a31, 2)    # -220258509322.20462


void test_fhypot64_reference():
	near(fhypot64(3.00000000000000000e+00, 4.00000000000000000e+00), 0x40140000, 0x00000000, 1)    # 5.0
	near(fhypot64(1.00000000000000003e-300, 1.00000000000000003e-300), 0x01ae4e8d, 0x12762225, 1)    # 1.414213562373095e-300
	near(fhypot64(1.00000000000000005e+300, 1.00000000000000005e+300), 0x7e40e4d5, 0x0f99b211, 1)    # 1.4142135623730952e+300
	near(fhypot64(float64_from_bits(1), float64_from_bits(1)), 0x00000000, 0x00000001, 1)    # 5e-324
	near(fhypot64(1.00000000000000000e+00, 1.00000000000000004e-10), 0x3ff00000, 0x00000000, 1)    # 1.0
	near(fhypot64(-2.50000000000000000e+00, 7.25000000000000000e+00), 0x401eacfc, 0x33c42c86, 1)    # 7.668930825088983
	near(fhypot64(9.99999999999999970e+199, 9.99999999999999982e-201), 0x6974e718, cast(int, 0xd7d7625a), 1)    # 1e+200
	near(fhypot64(1.00000000000000006e-01, 2.00000000000000011e-01), 0x3fcc9f25, cast(int, 0xc5bfedda), 1)    # 0.223606797749979
	near(fhypot64(1.79769313486231571e+308, 1.00000000000000001e+308), 0x7ff00000, 0x00000000, 1)    # inf
