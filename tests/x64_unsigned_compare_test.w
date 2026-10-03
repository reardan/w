# wbuild: arch_only=x64
/*
uint64 is the unsigned word on 8-byte-word targets: compares, division,
modulo and right shifts on it are unsigned at the full 64-bit width
(docs/projects/type_system_p0.md, "Unsigned operations"). uint64 only
exists on those targets, so this half of tests/unsigned_compare_test.w
is x64-only; that file's arm64 twin covers the same 64-bit boundaries
through word-sized uint.
*/
import lib.testing


struct wide_unsigned_box:
	uint64 value


uint64 u64_max():
	uint64 zero = 0
	return ~zero


# 2^63, the 64-bit sign bit
uint64 u64_high():
	uint64 one = 1
	return one << 63


void test_uint64_ordering_around_the_sign_bit():
	uint64 max = u64_max()
	uint64 hi = u64_high()
	uint64 lo = hi - 1
	asserts(c"uint64 max > 1", max > 1)
	asserts(c"2^63 > 2^63-1", hi > lo)
	asserts(c"2^63-1 < 2^63", lo < hi)
	asserts(c"2^63 >= 2^63-1", hi >= lo)
	asserts(c"2^63-1 <= 2^63", lo <= hi)
	asserts(c"2^63 < max", hi < max)
	int taken = 0
	if (hi > lo): taken = 1
	assert_equal(1, taken)
	int v = lo < hi
	assert_equal(1, v)


# The 32-bit boundary is just an ordinary value at 64 bits.
void test_uint64_above_the_32_bit_boundary():
	uint64 one = 1
	uint64 b32 = one << 32
	uint64 b31 = one << 31
	asserts(c"2^32 > 2^31", b32 > b31)
	asserts(c"2^31 > 2^31-1", b31 > b31 - 1)
	asserts(c"2^32 > 0x7fffffff", b32 > 0x7fffffff)


void test_uint64_mixed_with_int():
	uint64 max = u64_max()
	uint64 one = 1
	int neg = 0 - 1
	asserts(c"uint64 1 > int -1 is false", (one > neg) == 0)
	asserts(c"uint64 max >= int -1", max >= neg)
	int64 sneg = 0 - 1
	asserts(c"int64 -1 > uint64 1 (unsigned)", sneg > one)
	int64 s = 0 - 5
	asserts(c"int64 stays signed", s < 0)


void test_uint64_division_shift():
	uint64 max = u64_max()
	uint64 hi = u64_high()
	int max_signed = ~(1 << 63)
	assert_equal(max_signed, max / 2)
	assert_equal(5, max % 10)
	assert_equal(1, hi >> 63)
	assert_equal(max_signed, max >> 1)
	uint64 u = max
	u /= 4
	assert_equal(max_signed >> 1, u)
	u = max
	u >>= 62
	assert_equal(3, u)


void test_uint64_field():
	wide_unsigned_box box
	box.value = u64_max()
	asserts(c"uint64 field compares unsigned", box.value > 1)
	assert_equal(1, box.value >> 63)
