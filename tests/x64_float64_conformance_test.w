# TestFloat-derived conformance vectors for float64 (issue #17,
# docs/projects/float_testing.md), the float64-scale companion to
# tests/float_conformance_test.w's float32 coverage: NaN propagation,
# signed zeros, subnormal arithmetic, invalid operations, exact-
# comparison semantics, and int<->float64 conversion edges, all at
# float64 scale (2^53 mantissa boundary, 2^63 int64 conversion range).
# float64 requires the x64 target (docs/projects/float.md: one-word
# stack slots cannot hold 8 bytes on the default 32-bit target), so
# unlike float_conformance_test.w this file is x64-only: its target is
# hand-written in build.base.json (like x64_map_float64_test), compiled
# with the `x64` selector, and there is no 32-bit twin -- the same
# convention x64_map_float64_test.w and x64_float_test.w use. Every
# value here is a hand-picked vector, not vendored TestFloat data (see
# docs/projects/float_testing.md for the license rationale). See
# docs/projects/float.md's "Known MVP semantic differences" section for
# every divergence this file (and its float32 companion) uncovered.
import lib.testing
import lib.fmath64


void assert_float64_bits(int want_lo, int want_hi, float64 got):
	char* p = &got
	assert_equal_hex(want_lo, load_int32(p))
	assert_equal_hex(want_hi, load_int32(p + 4))


void assert_is_nan64(float64 got):
	assert_equal(1, f64is_nan(got))


# -- NaN propagation through + - * / -- see float_conformance_test.w's
# -- test_float32_nan_propagation_arithmetic for the full rationale;
# -- both-NaN payload selection is left as is-NaN only (implementation-
# -- defined per the SDM), single-NaN-operand and quieting behavior is
# -- pinned bit-exactly since it is hardware-guaranteed. Bit patterns
# -- are built from runtime shifts, not hex literals: any of these
# -- patterns (exponent all ones etc.) needs more than 32 significant
# -- bits, which is a compile error (see lib/fmath64.w's header comment
# -- and the top-level CLAUDE.md) -------------------------------------
void test_float64_nan_propagation_arithmetic():
	int exp_all_ones = 0x7ff << 52
	int quiet_bit = 1 << 51
	float64 qnan = float64_from_bits(exp_all_ones | quiet_bit)
	assert_is_nan64(qnan + 1.0)
	assert_is_nan64(qnan - 1.0)
	assert_is_nan64(qnan * 1.0)
	assert_is_nan64(qnan / 1.0)
	assert_is_nan64(1.0 / qnan)
	assert_is_nan64(0.0 * qnan)

	# Signaling-shaped input (exponent all ones, mantissa MSB clear, low
	# bit set): the hardware quiets it and the low payload bit survives.
	float64 snan_like = float64_from_bits(exp_all_ones | 1)
	assert_float64_bits(0x00000001, 0x7ff80000, snan_like + 1.0)

	float64 nan_a = float64_from_bits(exp_all_ones | quiet_bit | 1)
	float64 nan_b = float64_from_bits(exp_all_ones | quiet_bit | 2)
	assert_is_nan64(nan_a + nan_b)
	assert_is_nan64(nan_b + nan_a)


# -- Invalid operations: the x86 QNaN "floating-point indefinite" ---
#
# 0/0, inf-inf and inf*0 are IEEE-754 invalid operations; the x86/x86-64
# architecture defines one fixed result for all of them (the QNaN
# floating-point indefinite -- sign 1, exponent all ones, mantissa top
# bit set: 0xfff8000000000000 for float64), independent of vendor, so
# this is pinned bit-exactly rather than just is-NaN.
void test_float64_invalid_operations():
	int exp_all_ones = 0x7ff << 52
	float64 pinf = float64_from_bits(exp_all_ones)
	float64 ninf = float64_from_bits((1 << 63) | exp_all_ones)
	assert_float64_bits(0x00000000, cast(int, 0xfff80000), 0.0 / 0.0)
	assert_float64_bits(0x00000000, cast(int, 0xfff80000), pinf - pinf)
	assert_float64_bits(0x00000000, cast(int, 0xfff80000), pinf * 0.0)
	assert_float64_bits(0x00000000, cast(int, 0xfff80000), 0.0 * pinf)
	assert_float64_bits(0x00000000, cast(int, 0xfff80000), ninf * 0.0)
	assert_float64_bits(0x00000000, cast(int, 0xfff80000), pinf / pinf)


# -- Signed zeros: arithmetic ----------------------------------------
void test_float64_signed_zero_arithmetic():
	float64 pzero = 0.0
	float64 nzero = float64_from_bits(1 << 63)

	assert_float64_bits(0x00000000, 0x00000000, pzero + nzero)             # +0 + -0 = +0
	assert_float64_bits(0x00000000, cast(int, 0x80000000), nzero + nzero)  # -0 + -0 = -0
	assert_float64_bits(0x00000000, 0x00000000, pzero - pzero)
	assert_float64_bits(0x00000000, 0x00000000, pzero - nzero)              # +0 - -0 = +0
	assert_float64_bits(0x00000000, cast(int, 0x80000000), nzero - pzero)   # -0 - +0 = -0
	assert_float64_bits(0x00000000, cast(int, 0x80000000), pzero * nzero)   # sign of product
	assert_float64_bits(0x00000000, cast(int, 0x80000000), -pzero)          # unary minus flips
	assert_float64_bits(0x00000000, 0x00000000, -nzero)


# -- Signed zeros: division by zero produces signed infinities -------
void test_float64_divide_by_signed_zero():
	float64 pzero = 0.0
	float64 nzero = float64_from_bits(1 << 63)
	assert_float64_bits(0x00000000, 0x7ff00000, 1.0 / pzero)
	assert_float64_bits(0x00000000, cast(int, 0xfff00000), 1.0 / nzero)
	assert_float64_bits(0x00000000, cast(int, 0xfff00000), -1.0 / pzero)
	assert_float64_bits(0x00000000, 0x7ff00000, -1.0 / nzero)


# -- Signed zeros: comparisons and the documented truthiness quirk ---
void test_float64_signed_zero_comparisons_and_truthiness():
	float64 pzero = 0.0
	float64 nzero = float64_from_bits(1 << 63)
	assert_equal(1, pzero == nzero)
	assert_equal(0, nzero < pzero)
	assert_equal(1, pzero <= nzero)
	assert_equal(1, nzero >= pzero)

	# Documented MVP quirk (docs/projects/float.md): truthiness tests the
	# raw bit pattern, so -0.0 (nonzero bits) is truthy even though it
	# compares equal to 0.0.
	int nzero_truthy = 0
	if (nzero):
		nzero_truthy = 1
	assert_equal(1, nzero_truthy)


# -- Subnormal arithmetic: smallest/largest subnormal, gradual
# -- underflow into the normal range and gradual underflow to zero ---
void test_float64_subnormal_arithmetic():
	float64 smallest = float64_from_bits(1)              # 2^-1074
	float64 smallest2 = float64_from_bits(2)
	float64 largest_sub = float64_from_bits((1 << 52) - 1)  # largest subnormal

	assert_float64_bits(0x00000002, 0x00000000, smallest + smallest)
	assert_float64_bits(0x00000003, 0x00000000, smallest + smallest2)
	# Gradual underflow into the smallest normal (DBL_MIN): no
	# discontinuity at the subnormal/normal boundary.
	assert_float64_bits(0x00000000, 0x00100000, largest_sub + smallest)
	# Gradual underflow to zero: halving the smallest subnormal lands
	# exactly halfway between it and 0; ties-to-even rounds to 0.
	assert_float64_bits(0x00000000, 0x00000000, smallest / 2.0)
	assert_float64_bits(0x00000000, 0x00000000, smallest * 0.5)
	assert_float64_bits(0x00000000, 0x00000000, smallest - smallest)
	assert_float64_bits(0x00000001, cast(int, 0x80000000), -smallest)


# -- Rounding at the 2^53 precision boundary: float64's 53-bit mantissa
# -- can no longer represent every integer above 2^53 ----------------
void test_float64_rounding_at_precision_boundary():
	float64 two_53 = 9007199254740992.0    # 2^53: last integer with every neighbor exact
	assert_float64_bits(0x00000000, 0x43400000, two_53)
	# 2^53 + 1 is exactly halfway between 2^53 (mantissa 0, even) and
	# 2^53 + 2 (mantissa 1, odd); ties-to-even rounds down to 2^53. No
	# declared-temp workaround is needed here (unlike the float32 test):
	# a bare decimal literal on x64 IS float64 by default
	# (docs/projects/float.md Milestone 4), so there is no narrower
	# width for the literal to silently stay at.
	assert_float64_bits(0x00000000, 0x43400000, two_53 + 1.0)
	assert_equal(1, (two_53 + 1.0) == two_53)
	# 2^53 + 2 IS exactly representable (mantissa 1), so it must not
	# round away.
	assert_float64_bits(0x00000001, 0x43400000, two_53 + 2.0)
	assert_equal(0, (two_53 + 2.0) == two_53)


# -- Exact-comparison semantics: -0.0 == 0.0 is correct IEEE behavior
# -- (see the signed-zero family above); NaN comparisons are this
# -- compiler's one documented divergence from IEEE-754, same as
# -- float32's (docs/projects/float.md "Known MVP semantic
# -- differences"): ucomisd reports "unordered" with ZF=1, the same
# -- flag combination as "equal", and the compiler's equality/
# -- inequality lowering only checks ZF (not the parity flag hardware
# -- also sets to distinguish the two cases). That makes BOTH
# -- directions wrong: nan == nan is true (IEEE says false) and
# -- nan != nan is false (IEEE says true). <, <=, >, >= are unaffected
# -- because IEEE also defines those as false for unordered operands,
# -- which is what a ZF/CF-only check happens to produce anyway -----
void test_float64_nan_comparison_semantics():
	float64 qnan = float64_from_bits((0x7ff << 52) | (1 << 51))
	assert_equal(1, qnan == qnan)   # KNOWN MVP DIVERGENCE from IEEE-754 (spec: 0)
	assert_equal(0, qnan != qnan)   # KNOWN MVP DIVERGENCE from IEEE-754 (spec: 1)
	assert_equal(0, qnan < 1.0)     # matches IEEE-754 (unordered -> false)
	assert_equal(0, qnan > 1.0)
	assert_equal(0, qnan <= qnan)
	assert_equal(0, qnan >= qnan)


# -- int<->float64 conversion edges (int64 <-> float64 on x64) --------
#
# cvttsd2si truncates toward zero and, on overflow (source magnitude too
# large, or NaN, for a 64-bit destination), substitutes the "integer
# indefinite" sentinel 0x8000000000000000 instead of trapping (Intel
# SDM) -- the compiler adds no software range check, mirroring
# float32's cvttss2si behavior at the 2^31 boundary
# (test_float32_int_conversion_edges in float_conformance_test.w) but
# at the 2^63 boundary here. Same bit-identical wrinkle: the indefinite
# sentinel is indistinguishable from a legitimately converted exact
# -2^63 value, since both are 0x8000000000000000.
void test_float64_int_conversion_edges():
	float64 neg_2_63 = -9223372036854775808.0    # exactly representable AND in range
	int exact_min = neg_2_63
	assert_equal_hex(1 << 63, exact_min)

	float64 above_2_63 = 9223372036854775808.0    # 2^63: not representable as int64
	int overflowed = above_2_63
	assert_equal_hex(1 << 63, overflowed)          # same bits as the exact -2^63 case above

	float64 in_range = 9223372036854774784.0    # 2^63 - 1024: exact float64, in range
	int back = in_range
	assert_equal_hex((1 << 63) - 1024, back)
