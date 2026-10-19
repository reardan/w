# wbuild: x64 group=arm64_smoke_test@arm64 group=wasm_smoke_test@wasm
# Coverage for the float16 storage/conversion path (issue #17): a 2-byte
# IEEE-754 half is a storage type; all math happens in float32, so loading
# a float16 widens it and storing narrows it with round-to-nearest-even. See
# docs/projects/float.md and code_generator/sse.w.
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


float16 half_identity(float16 value):
	return value


float16 half_sum(float16 left, float16 right):
	return left + right


void test_float16_returned_values():
	float16 value = 1.5
	float32 widened = half_identity(value)
	assert_float32_bits(0x3fc00000, widened)
	assert_float32_bits(0x3fc00000, half_identity(half_identity(value)))
	assert_float16_bits(0x3e00, half_identity(value))
	assert_float32_bits(0x40400000, half_sum(half_identity(value), value))
	assert_float32_bits(0x40600000, half_identity(value) + 2.0)
	assert_float32_bits(0x40600000, 2.0 + half_identity(value))
	assert_float32_bits(cast(int, 0xbfc00000), -half_identity(value))
	assert_equal(1, half_identity(value) > 1.0)
	int truncated = half_identity(value)
	assert_equal(1, truncated)
	float16 stored = half_identity(value)
	assert_float16_bits(0x3e00, stored)
	stored = 2.5
	float32 assigned = (stored = half_identity(value))
	assert_float32_bits(0x3fc00000, assigned)
	float32 selected = 1 ? half_identity(value) : half_identity(stored)
	assert_float32_bits(0x3fc00000, selected)


void test_float16_rounding_boundaries():
	# Underflow ties, subnormal-to-normal carry, and finite-to-infinity carry.
	float16 underflow_tie = float_from_bits(0x33000000)
	assert_float16_bits(0, underflow_tie)
	float16 above_underflow_tie = float_from_bits(0x33000001)
	assert_float16_bits(1, above_underflow_tie)
	float16 subnormal_tie = float_from_bits(0x33c00000)
	assert_float16_bits(2, subnormal_tie)
	float16 normal_tie = float_from_bits(0x387fe000)
	assert_float16_bits(0x400, normal_tie)
	float16 below_overflow_tie = float_from_bits(0x477fefff)
	assert_float16_bits(0x7bff, below_overflow_tie)
	float16 overflow_tie = float_from_bits(0x477ff000)
	assert_float16_bits(0x7c00, overflow_tie)
	float16 negative_tie = float_from_bits(cast(int, 0xb3000000))
	assert_float16_bits(0x8000, negative_tie)
	# A NaN payload entirely in discarded bits must not become infinity.
	float16 tiny_nan_payload = float_from_bits(0x7f800001)
	assert_float16_bits(0x7e00, tiny_nan_payload)


void test_float16_all_finite_encodings():
	# Every finite storage bit pattern is an exactly representable float32.
	# This reaches every subnormal normalization and both signs without
	# reproducing the conversion algorithm in the test.
	float16 value
	int bits = 0
	while (bits < 65536):
		if ((bits & 0x7c00) != 0x7c00):
			uint16* raw = cast(uint16*, &value)
			*raw = bits
			float32 widened = value
			float16 back = widened
			assert_equal_hex(bits, load_int16(&back))
		bits = bits + 1


# wbuild: target=narrow_float_cross_compile_test tag=tests dep=wv2
# wbuild: step="bin/wv2 arm64 tests/float16_test.w -o bin/narrow_float16_arm64"
# wbuild: step="bin/wv2 wasm tests/float16_test.w -o bin/narrow_float16.wasm"
# wbuild: step="bin/wv2 arm64 tests/bfloat16_test.w -o bin/narrow_bfloat16_arm64"
# wbuild: step="bin/wv2 wasm tests/bfloat16_test.w -o bin/narrow_bfloat16.wasm"
