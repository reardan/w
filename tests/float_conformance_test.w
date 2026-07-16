# wbuild: x64
# TestFloat-derived conformance vectors for float32 (issue #17,
# docs/projects/float_testing.md): NaN propagation, signed zeros,
# subnormal arithmetic, infinities, rounding at precision boundaries,
# exact-comparison semantics, and int<->float32 conversion edges.
# float32 works identically on the default 32-bit target and x64
# (docs/projects/float.md), so this file carries the `# wbuild: x64`
# directive for an x64 twin instead of a separate x64_* file; only the
# int<->float conversion-edge family branches on __word_size__, since
# int is 4 bytes on the default target and 8 bytes on x64, which moves
# the cvttss2si overflow threshold from ~2^31 to ~2^63. Every value here
# is a hand-picked vector, not vendored TestFloat data (the license
# terms in docs/projects/float_testing.md call for keeping the upstream
# suite unvendored). See docs/projects/float.md's "Known MVP semantic
# differences" section for every divergence this file pins.
import lib.testing
import lib.fmath


void assert_float_bits(int want, float got):
	assert_equal_hex(want, float_bits(got))


void assert_is_nan(float got):
	assert_equal(1, fis_nan(got))


# -- NaN propagation through + - * / -------------------------------
#
# A NaN operand combined with a non-NaN one always yields a NaN (SSE
# addss/subss/mulss/divss quiet the NaN and pass its payload through --
# Intel SDM guaranteed, verified on this host). Both-NaN arithmetic
# (nan_a op nan_b) is asserted as is-NaN only: which operand's payload
# survives when both are already NaN is implementation-defined per the
# SDM. This compiler observably keeps the left/dest operand's payload
# today (code_generator/sse.w loads the left operand into xmm0, the
# instruction's implicit destination), but that is not an IEEE guarantee
# across vendors, so the payload itself is not pinned.
void test_float32_nan_propagation_arithmetic():
	float qnan = float_from_bits(0x7fc00000)
	assert_is_nan(qnan + 1.0)
	assert_is_nan(qnan - 1.0)
	assert_is_nan(qnan * 1.0)
	assert_is_nan(qnan / 1.0)
	assert_is_nan(1.0 / qnan)
	assert_is_nan(0.0 * qnan)

	# A signaling-shaped input (exponent all ones, mantissa MSB clear,
	# low bit set) is quieted by the hardware and its low payload bit
	# survives -- a case where the exact result IS pinnable.
	float snan_like = float_from_bits(0x7f800001)
	assert_float_bits(0x7fc00001, snan_like + 1.0)

	float nan_a = float_from_bits(0x7fc00001)
	float nan_b = float_from_bits(0x7fc00002)
	assert_is_nan(nan_a + nan_b)
	assert_is_nan(nan_b + nan_a)


# -- Invalid operations: the x86 QNaN "floating-point indefinite" ---
#
# 0/0, inf-inf and inf*0 are IEEE-754 invalid operations. The x86/x86-64
# architecture defines one fixed result for all of them: the QNaN
# floating-point indefinite (sign 1, exponent all ones, mantissa top bit
# set -- 0xffc00000 for float32), independent of vendor, so this is
# pinned bit-exactly rather than just is-NaN.
void test_float32_invalid_operations():
	float pinf = float_from_bits(0x7f800000)
	float ninf = float_from_bits(cast(int, 0xff800000))
	assert_float_bits(cast(int, 0xffc00000), 0.0 / 0.0)
	assert_float_bits(cast(int, 0xffc00000), pinf - pinf)
	assert_float_bits(cast(int, 0xffc00000), pinf * 0.0)
	assert_float_bits(cast(int, 0xffc00000), 0.0 * pinf)
	assert_float_bits(cast(int, 0xffc00000), ninf * 0.0)
	assert_float_bits(cast(int, 0xffc00000), pinf / pinf)


# -- Signed zeros: arithmetic ----------------------------------------
void test_float32_signed_zero_arithmetic():
	float pzero = 0.0
	float nzero = float_from_bits(cast(int, 0x80000000))

	assert_float_bits(0x00000000, pzero + nzero)              # +0 + -0 = +0
	assert_float_bits(cast(int, 0x80000000), nzero + nzero)   # -0 + -0 = -0
	assert_float_bits(0x00000000, pzero - pzero)
	assert_float_bits(0x00000000, pzero - nzero)               # +0 - -0 = +0
	assert_float_bits(cast(int, 0x80000000), nzero - pzero)    # -0 - +0 = -0
	assert_float_bits(cast(int, 0x80000000), pzero * nzero)    # sign of product
	assert_float_bits(cast(int, 0x80000000), -pzero)           # unary minus flips
	assert_float_bits(0x00000000, -nzero)


# -- Signed zeros: division by zero produces signed infinities -------
void test_float32_divide_by_signed_zero():
	float pzero = 0.0
	float nzero = float_from_bits(cast(int, 0x80000000))
	assert_float_bits(0x7f800000, 1.0 / pzero)
	assert_float_bits(cast(int, 0xff800000), 1.0 / nzero)
	assert_float_bits(cast(int, 0xff800000), -1.0 / pzero)
	assert_float_bits(0x7f800000, -1.0 / nzero)


# -- Signed zeros: comparisons and the documented truthiness quirk ---
void test_float32_signed_zero_comparisons_and_truthiness():
	float pzero = 0.0
	float nzero = float_from_bits(cast(int, 0x80000000))
	assert_equal(1, pzero == nzero)
	assert_equal(0, nzero < pzero)
	assert_equal(1, pzero <= nzero)
	assert_equal(1, nzero >= pzero)

	# Documented MVP quirk (docs/projects/float.md): truthiness tests the
	# raw bit pattern (`test eax, eax`), so -0.0 (nonzero bits) is truthy
	# even though it compares equal to 0.0.
	int nzero_truthy = 0
	if (nzero):
		nzero_truthy = 1
	assert_equal(1, nzero_truthy)


# -- Subnormal arithmetic: smallest/largest subnormal, gradual
# -- underflow into the normal range and gradual underflow to zero ---
void test_float32_subnormal_arithmetic():
	float smallest = float_from_bits(0x00000001)       # 2^-149
	float smallest2 = float_from_bits(0x00000002)
	float largest_sub = float_from_bits(0x007fffff)    # largest subnormal

	assert_float_bits(0x00000002, smallest + smallest)
	assert_float_bits(0x00000003, smallest + smallest2)
	# Gradual underflow into the smallest normal: no discontinuity at
	# the subnormal/normal boundary.
	assert_float_bits(0x00800000, largest_sub + smallest)
	# Gradual underflow to zero: halving the smallest subnormal lands
	# exactly halfway between it and 0; ties-to-even rounds to 0.
	assert_float_bits(0x00000000, smallest / 2.0)
	assert_float_bits(0x00000000, smallest * 0.5)
	assert_float_bits(0x00000000, smallest - smallest)
	assert_float_bits(cast(int, 0x80000001), -smallest)


# -- Rounding at precision boundaries: ties-to-even above 2^24, where
# -- the ULP steps to 2.0 and float32's 24-bit mantissa can no longer
# -- represent every integer ------------------------------------------
#
# The `== two_24` checks below use declared `float` temporaries
# (one/two/three) rather than bare literals as the addend. That is not
# stylistic: a bare decimal literal is float64 by default on x64 but
# float32 on the default 32-bit target (docs/projects/float.md
# Milestone 4, "literal type follows the target"), and coerce() only
# narrows a float64 result back to float32 at an assignment/param/return
# call site (Milestone 6) -- never for a bare inline comparison operand.
# So `(two_24 + 1.0) == two_24` -- with the literal spelled directly --
# would silently run the addition and comparison in float64 on x64 (one
# operand widens, both do not get compared apples-to-apples until
# coerced), giving a DIFFERENT boolean answer there than on the 32-bit
# target for byte-identical source. See "Known MVP semantic differences"
# in docs/projects/float.md for the full writeup and a worked example;
# routing the addend through a declared float32 variable keeps this test
# meaningful (and passing) on both targets.
void test_float32_rounding_at_precision_boundary():
	float two_24 = 16777216.0      # 2^24: last integer with every neighbor exact
	float one = 1.0
	float two = 2.0
	float three = 3.0
	assert_float_bits(0x4b800000, two_24)
	# 2^24 + 1 is exactly halfway between 2^24 (mantissa 0, even) and
	# 2^24 + 2 (mantissa 1, odd); ties-to-even rounds down to 2^24.
	assert_float_bits(0x4b800000, two_24 + one)
	assert_equal(1, (two_24 + one) == two_24)
	# 2^24 + 2 IS exactly representable (mantissa 1), so it must not
	# round away.
	assert_float_bits(0x4b800001, two_24 + two)
	assert_equal(0, (two_24 + two) == two_24)
	# 2^24 + 3 is exactly halfway between 2^24 + 2 (mantissa 1, odd) and
	# 2^24 + 4 (mantissa 2, even); ties-to-even rounds up this time.
	assert_float_bits(0x4b800002, two_24 + three)


# -- Exact-comparison semantics: -0.0 == 0.0 is correct IEEE behavior
# -- (see the signed-zero family above); NaN comparisons are this
# -- compiler's one documented divergence from IEEE-754 -------------
#
# docs/projects/float.md "Known MVP semantic differences": ucomiss
# reports "unordered" with ZF=1, the same flag combination as "equal",
# and the compiler's equality/inequality lowering only checks ZF (not
# the parity flag hardware also sets to distinguish the two cases). That
# makes BOTH directions wrong: nan == nan is true (IEEE says false) and
# nan != nan is false (IEEE says true). <, <=, >, >= are unaffected
# because IEEE also defines those as false for unordered operands, which
# is what a ZF/CF-only check happens to produce anyway.
void test_float32_nan_comparison_semantics():
	float qnan = float_from_bits(0x7fc00000)
	assert_equal(1, qnan == qnan)   # KNOWN MVP DIVERGENCE from IEEE-754 (spec: 0)
	assert_equal(0, qnan != qnan)   # KNOWN MVP DIVERGENCE from IEEE-754 (spec: 1)
	assert_equal(0, qnan < 1.0)     # matches IEEE-754 (unordered -> false)
	assert_equal(0, qnan > 1.0)
	assert_equal(0, qnan <= qnan)
	assert_equal(0, qnan >= qnan)


# -- int<->float32 conversion edges -----------------------------------
#
# cvttss2si truncates toward zero and, on overflow (source magnitude too
# large, or NaN, for the destination width), substitutes the "integer
# indefinite" sentinel instead of trapping (Intel SDM) -- the compiler
# adds no software range check. int is 4 bytes on the default 32-bit
# target and 8 bytes on x64 (REX.W cvttss2si -> rax), so the overflow
# threshold itself moves with the target: ~2^31 on the default target,
# ~2^63 on x64. Bit-identical wrinkle at either width: the indefinite
# sentinel (INT_MIN's bit pattern, all-zero but the sign bit) is
# indistinguishable from a legitimately converted exact
# -2^(width-1) value, since both are the same bits -- there is no
# after-the-fact way to tell overflow from an exact boundary result.
# Expected magnitudes at/above 2^31 are built from runtime shifts, not
# literals: a decimal or hex literal whose value has bit 31 set is
# represented as a negative 32-bit pattern inside the (always 32-bit)
# compiler and sign-extends into a 64-bit target int, per the top-level
# CLAUDE.md hex-literal gotcha -- confirmed here to apply to decimal
# literals too, not just hex ones.
void test_float32_int_conversion_edges():
	if (__word_size__ == 4):
		float above_2_31 = 2147483648.0    # 2^31: not representable as int32
		int overflowed = above_2_31
		assert_equal_hex(cast(int, 0x80000000), overflowed)

		float neg_2_31 = -2147483648.0     # exactly representable AND in range
		int exact_min = neg_2_31
		assert_equal_hex(cast(int, 0x80000000), exact_min)  # same bits as above

		float in_range = 2147483520.0      # 2^31 - 128: exact float32, in range
		int back = in_range
		assert_equal(2147483520, back)
	else:
		float above_2_31 = 2147483648.0    # fits easily in a 64-bit int
		int fits = above_2_31
		assert_equal_hex(1 << 31, fits)

		float huge = 1.0e19                # well past 2^63: overflows int64
		int overflowed = huge
		assert_equal_hex(1 << 63, overflowed)
