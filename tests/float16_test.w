# wbuild: x64
# Coverage for the float16 storage/conversion path (issue #17): a 2-byte
# IEEE-754 half is a declarable type on the x86 family (target_isa == 0,
# both the default 32-bit target and x64 via the twin above); all math
# happens in float32, so loading a float16 widens it (F16C vcvtph2ps) and
# storing narrows it (vcvtps2ph, round-to-nearest-even). See
# docs/projects/float.md and code_generator/sse.w.
#
# float16 is a compile error on arm64 and wasm ("<target>: float16 is not
# implemented", code_generator/sse.w) - not exercised here since this file
# only builds for the x86 family; see the doc for the arm64/wasm gap.
import lib.testing
import lib.fmath


struct Vec2h:
	float16 x
	float16 y


void assert_float16_bits(int want, float16 got):
	char* p = &got
	assert_equal_hex(want, load_int16(p))


void assert_float32_bits(int want, float32 got):
	char* p = &got
	assert_equal_hex(want, load_int32(p))


# Values with an exact float16 representation must round-trip through
# float32 -> float16 -> float32 with no bit loss, and the stored half
# itself must match the IEEE-754 golden bit pattern.
void test_float16_exact_round_trips():
	float16 one = 1.0
	assert_float16_bits(0x3c00, one)
	assert_float32_bits(0x3f800000, one)

	float16 neg_two_five = -2.5
	assert_float16_bits(0xc100, neg_two_five)
	assert_float32_bits(cast(int, 0xc0200000), neg_two_five)

	float16 half = 0.5
	assert_float16_bits(0x3800, half)
	assert_float32_bits(0x3f000000, half)

	# largest finite half (max normal)
	float16 max_normal = 65504.0
	assert_float16_bits(0x7bff, max_normal)
	assert_float32_bits(0x477fe000, max_normal)

	# smallest positive normal half, 2^-14
	float16 smallest_normal = 0.00006103515625
	assert_float16_bits(0x0400, smallest_normal)
	assert_float32_bits(0x38800000, smallest_normal)


# vcvtps2ph narrows with round-to-nearest-even; check both a plain
# below/above-halfway pair and the exact-tie cases where the rounding
# rule (round to the representable half with an even mantissa) is the
# only thing that decides the result.
void test_float16_rounding():
	float16 rounds_down = 1.0004
	assert_float16_bits(0x3c00, rounds_down)

	float16 rounds_up = 1.0006
	assert_float16_bits(0x3c01, rounds_up)

	# exactly halfway between 0x3c00 and 0x3c01: 0x3c00 has the even
	# mantissa, so the tie rounds down to it.
	float16 tie_to_even_down = 1.00048828125
	assert_float16_bits(0x3c00, tie_to_even_down)

	# exactly halfway between 0x3c01 and 0x3c02: 0x3c02 has the even
	# mantissa, so the tie rounds up to it.
	float16 tie_to_even_up = 1.00146484375
	assert_float16_bits(0x3c02, tie_to_even_up)

	# overflows the half exponent range (max normal is 65504.0): rounds
	# up into +inf rather than erroring or wrapping.
	float16 overflowed = 70000.0
	assert_float16_bits(0x7c00, overflowed)
	assert_float32_bits(0x7f800000, overflowed)


void test_float16_subnormals():
	# smallest positive subnormal, 2^-24
	float16 smallest_subnormal = float_from_bits(0x33800000)
	assert_float16_bits(0x0001, smallest_subnormal)
	assert_float32_bits(0x33800000, smallest_subnormal)

	# largest subnormal, (1023/1024) * 2^-14
	float16 largest_subnormal = float_from_bits(0x387fc000)
	assert_float16_bits(0x03ff, largest_subnormal)
	assert_float32_bits(0x387fc000, largest_subnormal)


void test_float16_zero_inf_nan():
	float16 pos_zero = 0.0
	assert_float16_bits(0x0000, pos_zero)

	float16 neg_zero = float_from_bits(cast(int, 0x80000000))
	assert_float16_bits(0x8000, neg_zero)

	float16 pos_inf = float_from_bits(0x7f800000)
	assert_float16_bits(0x7c00, pos_inf)
	assert_float32_bits(0x7f800000, pos_inf)

	float16 neg_inf = float_from_bits(cast(int, 0xff800000))
	assert_float16_bits(0xfc00, neg_inf)
	assert_float32_bits(cast(int, 0xff800000), neg_inf)

	# quiet NaN bit pattern survives the narrow/widen round trip.
	float16 quiet_nan = float_from_bits(0x7fc00000)
	assert_float16_bits(0x7e00, quiet_nan)
	assert_float32_bits(0x7fc00000, quiet_nan)


void test_float16_struct_fields():
	Vec2h v
	v.x = 1.0
	v.y = -2.5
	assert_float16_bits(0x3c00, v.x)
	assert_float16_bits(0xc100, v.y)
	assert_float32_bits(0x3f800000, v.x)
	assert_float32_bits(cast(int, 0xc0200000), v.y)


void test_float16_array_storage():
	float16[4] arr
	arr[0] = 1.0
	arr[1] = 0.5
	arr[2] = 65504.0
	arr[3] = float_from_bits(cast(int, 0x80000000))

	assert_float16_bits(0x3c00, arr[0])
	assert_float16_bits(0x3800, arr[1])
	assert_float16_bits(0x7bff, arr[2])
	assert_float16_bits(0x8000, arr[3])
	assert_float32_bits(0x477fe000, arr[2])


# int<->float16 conversions and arithmetic through the widened float32
# value (float16 has no arithmetic opcodes of its own: loading one always
# produces a float32 value, per docs/projects/float.md).
void test_float16_conversions_and_arithmetic():
	float16 from_int = 3
	assert_float16_bits(0x4200, from_int)

	float16 a = 1.0
	int truncated = a
	assert_equal(1, truncated)

	float16 b = 2.5
	float32 sum = a + b
	assert_float32_bits(0x40600000, sum)


void test_float16_comparisons_and_unary_minus():
	float16 a = 1.0
	float16 b = 1.0
	float16 c = 2.0
	assert_equal(1, a == b)
	assert_equal(0, a == c)
	assert_equal(1, a < c)

	float16 negated = -a
	assert_float16_bits(0xbc00, negated)
