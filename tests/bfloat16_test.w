# wbuild: x64 group=arm64_smoke_test@arm64 group=wasm_smoke_test@wasm
# wbuild: step="bin/wv2 check tests/bfloat16_map_add_fixture.w" expect_fail expect_stderr="map add does not support bfloat16 values"
# wbuild: step="bin/wv2 check tests/bfloat16_json_fixture.w" expect_fail expect_stderr="unsupported to_json/from_json field type"
# bfloat16 stores the upper 16 bits of float32, rounding stores to nearest,
# ties to even. These vectors exercise real declarations, calls, loads and
# stores, not a second implementation of the conversion algorithm.
import lib.testing
import lib.fmath


type BrainFloat = bfloat16
type BrainCallback = fn(bfloat16) -> bfloat16


struct BrainPair:
	bfloat16 x
	bfloat16 y


int brain_bits(bfloat16 value):
	return load_int16(cast(char*, &value))


int brain_float_bits(float32 value):
	return load_int32(cast(char*, &value))


bfloat16 brain_identity(bfloat16 value):
	return value


bfloat16 brain_return_literal():
	return 1.5


BrainFloat brain_alias_identity(BrainFloat value):
	return value


T brain_generic_identity[T](T value):
	return value


void test_bfloat16_storage_and_arithmetic():
	assert_equal(2, sizeof(bfloat16))
	bfloat16 one = 1.0
	bfloat16 negative = -2.5
	assert_equal_hex(0x3f80, brain_bits(one))
	assert_equal_hex(0xc020, brain_bits(negative))
	assert_equal_hex(0x3f800000, brain_float_bits(one))
	assert_near(-1.5, one + negative)
	assert_near(-2.5, one * negative)
	assert_near(2.5, -negative)
	assert_equal(1, one > negative)
	assert_equal(1, one == 1.0)
	assert_equal(0, one != 1.0)
	bfloat16 from_int = 3
	int truncated = negative
	assert_equal_hex(0x4040, brain_bits(from_int))
	assert_equal(-2, truncated)
	one += 0.5
	assert_equal_hex(0x3fc0, brain_bits(one))


void test_bfloat16_rounding_boundaries():
	# Values below, on, and above the midpoint at 1.0.
	assert_equal_hex(0x3f80, brain_bits(float_from_bits(0x3f807fff)))
	assert_equal_hex(0x3f80, brain_bits(float_from_bits(0x3f808000)))
	assert_equal_hex(0x3f81, brain_bits(float_from_bits(0x3f808001)))
	assert_equal_hex(0x3f82, brain_bits(float_from_bits(0x3f818000)))
	assert_equal_hex(0xbf80, brain_bits(float_from_bits(cast(int, 0xbf808000))))
	assert_equal_hex(0xbf82, brain_bits(float_from_bits(cast(int, 0xbf818000))))
	# Subnormal underflow ties, subnormal/normal carry, overflow.
	assert_equal_hex(0, brain_bits(float_from_bits(0x00008000)))
	assert_equal_hex(1, brain_bits(float_from_bits(0x00008001)))
	assert_equal_hex(2, brain_bits(float_from_bits(0x00018000)))
	assert_equal_hex(0x80, brain_bits(float_from_bits(0x007f8000)))
	assert_equal_hex(0x7f7f, brain_bits(float_from_bits(0x7f7f7fff)))
	assert_equal_hex(0x7f80, brain_bits(float_from_bits(0x7f7f8000)))
	assert_equal_hex(0xff80, brain_bits(float_from_bits(cast(int, 0xff7f8000))))


void test_bfloat16_special_values():
	assert_equal_hex(0x0000, brain_bits(float_from_bits(0x00000000)))
	assert_equal_hex(0x8000, brain_bits(float_from_bits(cast(int, 0x80000000))))
	assert_equal_hex(0x7f80, brain_bits(float_from_bits(0x7f800000)))
	assert_equal_hex(0xff80, brain_bits(float_from_bits(cast(int, 0xff800000))))
	assert_equal_hex(0x7fc0, brain_bits(float_from_bits(0x7fc00000)))
	# Discarded NaN payloads must not become infinity; maximal payloads
	# must not round into a different sign or zero.
	assert_equal_hex(0x7fc0, brain_bits(float_from_bits(0x7f800001)))
	assert_equal_hex(0xffc0, brain_bits(float_from_bits(cast(int, 0xff800001))))
	assert_equal_hex(0x7fff, brain_bits(float_from_bits(0x7fffffff)))
	assert_equal_hex(0xffff, brain_bits(float_from_bits(cast(int, 0xffffffff))))
	bfloat16 nan = float_from_bits(0x7f800001)
	assert_equal_hex(0x7fc00000, brain_float_bits(nan))


void test_bfloat16_all_encodings():
	# Every finite representation widens exactly, including the full
	# subnormal range. Stores quiet NaNs while retaining the high payload.
	int bits = 0
	while bits < 65536:
		float32 source = float_from_bits(bits << 16)
		bfloat16 stored = source
		int want = bits
		if ((bits & 0x7fff) > 0x7f80): want = bits | 0x40
		assert_equal_hex(want, brain_bits(stored))
		float32 widened = stored
		int widened_bits = brain_float_bits(widened)
		assert_equal_hex(want, (widened_bits >> 16) & 0xffff)
		assert_equal_hex(0, widened_bits & 0xffff)
		bits += 1


void test_bfloat16_return_values_and_aliases():
	bfloat16 value = 1.5
	float32 direct = brain_identity(value)
	assert_near(1.5, direct)
	assert_near(1.5, brain_return_literal())
	assert_near(3.0, brain_identity(value) + brain_identity(value))
	assert_near(1.5, cast(float32, brain_identity(value)))
	assert_equal(1, cast(int, brain_identity(value)))
	assert_equal_hex(0x3fc0, brain_bits(brain_identity(value)))
	BrainFloat alias = value
	const BrainFloat immutable = alias
	assert_near(1.5, immutable)
	assert_near(1.5, brain_alias_identity(alias))
	assert_near(1.5, brain_generic_identity[bfloat16](value))
	BrainCallback* callback = brain_identity
	assert_near(1.5, callback(value))


void test_bfloat16_fields_arrays_and_containers():
	BrainPair pair
	pair.x = 1.0
	pair.y = -2.5
	assert_equal_hex(0x3f80, brain_bits(pair.x))
	assert_near(-2.5, pair.y)
	bfloat16[3] values
	values[0] = pair.x
	values[1] = pair.y
	values[2] = 0.5
	assert_equal_hex(0x3f00, brain_bits(values[2]))
	bfloat16* ptr = &values[0]
	assert_near(-2.5, ptr[1])
	list[bfloat16] items = list[bfloat16]{1.0, 2.5}
	assert_near(2.5, items[1])
	items[0] = -1.0
	assert_near(-1.0, items[0])
	map[int, bfloat16] indexed = new map[int, bfloat16]
	indexed[7] = 1.5
	assert_near(1.5, indexed[7])
	indexed[7] += 0.5
	assert_near(2.0, indexed[7])


float16 brain_to_half(bfloat16 value):
	return value


void test_bfloat16_half_conversions():
	bfloat16 value = 1.5
	float16 half = brain_identity(value)
	assert_near(1.5, half)
	bfloat16 roundtrip = brain_to_half(value)
	assert_near(1.5, roundtrip)
	assert_equal_hex(0x3fc0, brain_bits(brain_to_half(value)))
	# Half's exponent range is narrower; bfloat16's mantissa is shorter.
	float16 fine = 1.0009765625
	bfloat16 rounded = fine
	assert_near(1.0, rounded)
