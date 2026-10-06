# wbuild: x64
/*
lib/checked.w tests, plus word-size fixtures for the integer behaviors
the checked helpers are built around: high-bit literals, signed versus
unsigned comparison, shifts and narrowing. Every expectation that
legitimately differs between the 32-bit (x86) and 64-bit (x64) int is
branched on sizeof(int), so both twins assert their own target.
*/
import lib.testing
import lib.checked


int is64():
	if (sizeof(int) == 8): return 1
	return 0


# 0xffffffff, built at runtime: -1 on x86, 4294967295 on x64.
int mask32():
	int h = 1 << 16
	return h * h - 1


void test_word_constants():
	assert_equal(sizeof(int) * 8, checked_word_bits())
	int min = checked_int_min()
	int max = checked_int_max()
	assert1(min < 0)
	assert1(max > 0)
	assert_equal(min, max + 1)  # wraps
	assert_equal(0 - 1, min + max)
	if (is64() == 0):
		assert_equal(cast(int, 0x80000000), min)
		assert_equal(0x7fffffff, max)
	else:
		assert_equal(0x7fffffff, unsigned_shr(max, 32))
		assert_equal(mask32(), max & mask32())


# A hex literal with bit 31 set sign-extends on every target
# (grammar/int_literal.w); only runtime-built constants differ by width.
void test_high_bit_literals():
	int x = cast(int, 0x80000000)
	assert1(x < 0)
	assert_equal(0 - 2147483647 - 1, x)
	assert_equal(0 - 1, cast(int, 0xffffffff))
	# Decimal literals wrap to 32 bits the same way.
	assert_equal(0 - 1, 4294967295)
	assert_equal(x, 2147483648)
	# x & 0xffffffff is a no-op (the mask is -1), never a truncation.
	assert_equal(x, x & cast(int, 0xffffffff))
	# So the literal 4294967295 is NOT the runtime mask on x64.
	if (is64()):
		assert1(mask32() != 4294967295)
	else:
		assert_equal(4294967295, mask32())


void test_runtime_mask32():
	int m = mask32()
	int x = cast(int, 0x80000000)
	if (is64()):
		assert1(m > 0)
		assert_equal(1, unsigned_shr(x & m, 31))
		assert1((x & m) > 0)
		assert_equal(0, unsigned_shr(m, 32))
	else:
		assert_equal(0 - 1, m)
		assert_equal(x, x & m)


void test_unsigned_compare():
	assert_equal(1, unsigned_lt(1, 0 - 1))
	assert_equal(0, unsigned_lt(0 - 1, 1))
	assert_equal(1, unsigned_lt(0, checked_int_min()))
	assert_equal(1, unsigned_lt(checked_int_max(), checked_int_min()))
	assert_equal(0, unsigned_lt(5, 5))
	assert_equal(1, unsigned_le(5, 5))
	assert_equal(0 - 1, unsigned_cmp(7, cast(int, 0x80000000)))
	assert_equal(1, unsigned_cmp(0 - 1, 0))
	assert_equal(0, unsigned_cmp(0 - 1, 0 - 1))
	# Signed comparison orders the same patterns the other way.
	assert1((0 - 1) < 1)
	assert1(cast(int, 0x80000000) < 7)


void test_shifts():
	# >> is arithmetic: it smears the sign bit.
	assert_equal(0 - 1, (0 - 1) >> 1)
	assert_equal(0 - 1, (0 - 1) >> 31)
	# shr() is a logical shift of the LOW 32 bits on every target.
	assert_equal(0x7fffffff, shr(0 - 1, 1))
	assert_equal(1, shr(cast(int, 0x80000000), 31))
	# unsigned_shr is a logical shift of the whole word.
	assert_equal(checked_int_max(), unsigned_shr(0 - 1, 1))
	assert_equal(1, unsigned_shr(checked_int_min(), checked_word_bits() - 1))
	assert_equal(0, unsigned_shr(0 - 1, checked_word_bits()))
	assert_equal(0 - 1, unsigned_shr(0 - 1, 0))
	# 1 << 31 is negative only where it reaches the sign bit.
	int b31 = 1 << 31
	if (is64()):
		assert1(b31 > 0)
		assert_equal(b31, mask32() / 2 + 1)
		int b40 = 1 << 40
		assert_equal(256, unsigned_shr(b40, 32))
	else:
		assert1(b31 < 0)
		assert_equal(checked_int_min(), b31)


void test_checked_add_sub():
	int r = 99
	assert_equal(1, checked_add(2, 3, &r))
	assert_equal(5, r)
	assert_equal(0, checked_add(checked_int_max(), 1, &r))
	assert_equal(0, r)
	assert_equal(0, checked_add(checked_int_min(), 0 - 1, &r))
	assert_equal(1, checked_add(checked_int_max(), checked_int_min(), &r))
	assert_equal(0 - 1, r)
	assert_equal(1, checked_add(checked_int_max() - 1, 1, &r))
	assert_equal(checked_int_max(), r)
	assert_equal(1, checked_sub(0, checked_int_max(), &r))
	assert_equal(checked_int_min() + 1, r)
	assert_equal(0, checked_sub(0, checked_int_min(), &r))
	assert_equal(0, checked_sub(checked_int_min(), 1, &r))
	assert_equal(0, checked_sub(checked_int_max(), 0 - 1, &r))
	assert_equal(1, checked_sub(0 - 1, checked_int_max(), &r))
	assert_equal(checked_int_min(), r)
	assert_equal(0, checked_neg(checked_int_min(), &r))
	assert_equal(1, checked_neg(checked_int_max(), &r))
	assert_equal(checked_int_min() + 1, r)


void test_checked_mul():
	int r = 0
	assert_equal(1, checked_mul(6, 7, &r))
	assert_equal(42, r)
	assert_equal(1, checked_mul(0, checked_int_min(), &r))
	assert_equal(0, r)
	assert_equal(0, checked_mul(0 - 1, checked_int_min(), &r))
	assert_equal(0, checked_mul(checked_int_min(), 0 - 1, &r))
	assert_equal(1, checked_mul(0 - 1, checked_int_max(), &r))
	assert_equal(checked_int_min() + 1, r)
	assert_equal(0, checked_mul(checked_int_max(), 2, &r))
	assert_equal(1, checked_mul(checked_int_min() / 2, 2, &r))
	assert_equal(checked_int_min(), r)
	assert_equal(0, checked_mul(checked_int_min() / 2, 0 - 2, &r))
	# Half-word boundary: 2^(bits/2) squared wraps to exactly 0.
	int half = 1 << (checked_word_bits() / 2)
	assert_equal(0, checked_mul(half, half, &r))
	assert_equal(1, checked_mul(half / 2, half - 1, &r))
	assert_equal(0, checked_mul(half, half / 2, &r))
	# 65536 * 65536 overflows the 32-bit int but not the 64-bit one.
	if (is64()):
		assert_equal(1, checked_mul(65536, 65536, &r))
		assert_equal(1, unsigned_shr(r, 32))
	else:
		assert_equal(0, checked_mul(65536, 65536, &r))
		assert_equal(1, checked_mul(46340, 46340, &r))
		assert_equal(0, checked_mul(46341, 46341, &r))


void test_checked_unsigned():
	int r = 0
	assert_equal(1, checked_add_u(0 - 2, 1, &r))
	assert_equal(0 - 1, r)
	assert_equal(0, checked_add_u(0 - 1, 1, &r))
	assert_equal(1, checked_add_u(checked_int_max(), 1, &r))
	assert_equal(checked_int_min(), r)
	assert_equal(0, checked_sub_u(0, 1, &r))
	assert_equal(1, checked_sub_u(0 - 1, 1, &r))
	assert_equal(0 - 2, r)
	assert_equal(1, checked_mul_u(checked_int_min(), 1, &r))
	assert_equal(checked_int_min(), r)
	assert_equal(0, checked_mul_u(checked_int_min(), 2, &r))
	assert_equal(1, checked_mul_u(checked_int_max(), 2, &r))
	assert_equal(0 - 2, r)
	assert_equal(0, checked_mul_u(0 - 1, 2, &r))
	int half = 1 << (checked_word_bits() / 2)
	assert_equal(0, checked_mul_u(half, half, &r))
	# (2^h - 1)^2 = 2^bits - 2^(h+1) + 1 fits.
	assert_equal(1, checked_mul_u(half - 1, half - 1, &r))
	assert_equal(1 - 2 * half, r)
	assert_equal(1, checked_mul_u(3, 5, &r))
	assert_equal(15, r)


void test_checked_narrow():
	int r = 0
	assert_equal(1, checked_narrow_u8(255, &r))
	assert_equal(0, checked_narrow_u8(256, &r))
	assert_equal(0, checked_narrow_u8(0 - 1, &r))
	assert_equal(1, checked_narrow_i8(0 - 128, &r))
	assert_equal(0, checked_narrow_i8(128, &r))
	assert_equal(1, checked_narrow_u16(65535, &r))
	assert_equal(0, checked_narrow_u16(65536, &r))
	assert_equal(0, checked_narrow_u16(70000, &r))
	assert_equal(1, checked_narrow_i16(0 - 32768, &r))
	assert_equal(0, checked_narrow_i16(32768, &r))
	assert_equal(1, checked_narrow_i32(0x7fffffff, &r))
	assert_equal(1, checked_narrow_i32(cast(int, 0x80000000), &r))
	assert_equal(1, checked_narrow_u32(0x7fffffff, &r))
	assert_equal(0, checked_narrow_u32(0 - 1, &r))
	if (is64()):
		assert_equal(0, checked_narrow_i32(1 << 31, &r))
		assert_equal(1, checked_narrow_u32(1 << 31, &r))
		assert_equal(1, checked_narrow_u32(mask32(), &r))
		assert_equal(mask32(), r)
		assert_equal(0, checked_narrow_u32(mask32() + 1, &r))
		assert_equal(0, checked_narrow_i32(mask32(), &r))
	else:
		assert_equal(1, checked_narrow_i32(checked_int_max(), &r))
		assert_equal(1, checked_narrow_i32(checked_int_min(), &r))
		assert_equal(1, checked_narrow_u32(checked_int_max(), &r))


# The silent truncation checked_narrow_* exists to replace. The values
# come through int variables: a literal out of a narrow type's range is
# a compile-time warning since issue #532.
void test_builtin_narrow_types_truncate():
	int wide16 = 70000
	uint16 u16 = wide16
	int w16 = u16
	assert_equal(70000 - 65536, w16)
	int wide8 = 300
	uint8 u8 = wide8
	int w8 = u8
	assert_equal(44, w8)


void test_checked_size():
	int r = 0
	assert_equal(1, checked_size(10, 8, &r))
	assert_equal(80, r)
	assert_equal(0, checked_size(0 - 1, 8, &r))
	assert_equal(0, checked_size(8, 0 - 1, &r))
	assert_equal(1, checked_size(0, checked_int_max(), &r))
	assert_equal(0, checked_size(checked_int_max() / 2 + 1, 2, &r))
	assert_equal(1, checked_size(checked_int_max() / 2, 2, &r))
	assert_equal(1, checked_size_add(checked_int_max() - 1, 1, &r))
	assert_equal(0, checked_size_add(checked_int_max(), 1, &r))
	assert_equal(0, checked_size_add(0 - 1, 1, &r))
	if (is64() == 0):
		assert_equal(0, checked_size(65536, 32768, &r))
		assert_equal(1, checked_size(65536, 32767, &r))
