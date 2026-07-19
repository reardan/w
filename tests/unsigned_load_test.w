# wbuild: x64
import lib.testing


# Loads of the fixed-width unsigned types must zero-extend into the
# word-sized register (grammar/promote.w -> promote_uint8/16/32_eax).
# Before the fix they sign-extended like their signed twins, so a stored
# high-bit value read back negative and every later compare, divide,
# modulo, right shift and widening misevaluated, while store-side
# arithmetic (which truncates to the declared width) already wrapped
# correctly. uint32 is only narrower than the word on 64-bit targets;
# on 32-bit targets it is word-sized and shares word-sized uint's
# signed-compare behavior, so its high-bit read assertions are gated on
# __word_size__.

struct unsigned_fields:
	uint8 u8
	uint16 u16
	uint32 u32


void test_uint8_high_bit_reads_unsigned():
	uint8 u = 0 - 1
	assert_equal(255, u)
	asserts(c"uint8 255 must compare above 100", u > 100)
	uint8 h = 200
	int widened = h
	assert_equal(200, widened)
	assert_equal(100, h / 2)
	assert_equal(4, h % 7)
	assert_equal(50, h >> 2)


void test_uint16_high_bit_reads_unsigned():
	uint16 u = 0 - 1
	assert_equal(65535, u)
	asserts(c"uint16 65535 must compare above 100", u > 100)
	assert_equal(255, u >> 8)
	uint16 h = 40000
	int widened = h
	assert_equal(40000, widened)
	assert_equal(20000, h / 2)
	assert_equal(4, h % 9)


void test_uint32_high_bit_reads_unsigned():
	if (__word_size__ != 8):
		# Word-sized on 32-bit targets: high-bit values read back at
		# word width, like uint. Only the store-wrap tests apply there.
		return;
	uint32 u = 0 - 1
	# 4294967295, spelled at runtime: a decimal literal this large
	# overflows the 32-bit literal parser on the x86 host.
	int all_ones = 65536 * 65536 - 1
	assert_equal(all_ones, u)
	asserts(c"uint32 max must not compare below 100", (u < 100) == 0)
	uint32 d = 0 - 2
	assert_equal(1431655764, d / 3)
	assert_equal(4, d % 10)
	assert_equal(65535, u >> 16)
	int widened = u
	assert_equal(all_ones, widened)


void test_store_side_wrap_unchanged():
	uint8 u8 = 255 + 1
	assert_equal(0, u8)
	uint16 u16 = 65535 + 1
	assert_equal(0, u16)
	int16 i16 = 32767 + 1
	assert_equal(-32768, i16)
	# 65537 * 65539 = 0x100040003: wraps to 262147 at 32 bits
	uint32 u32 = 65537 * 65539
	assert_equal(262147, u32)


void test_signed_subword_loads_still_sign_extend():
	int8 i8 = 0 - 5
	assert_equal(-5, i8)
	int16 i16 = 0 - 300
	assert_equal(-300, i16)
	int32 i32 = 0 - 70000
	assert_equal(-70000, i32)
	char c = 0 - 1
	assert_equal(-1, c)


void test_unsigned_struct_fields():
	unsigned_fields* f = new unsigned_fields
	f.u8 = 0 - 1
	f.u16 = 0 - 1
	f.u32 = 0 - 1
	assert_equal(255, f.u8)
	assert_equal(65535, f.u16)
	if (__word_size__ == 8):
		assert_equal(65536 * 65536 - 1, f.u32)
	asserts(c"uint16 field must compare above 100", f.u16 > 100)


void test_unsigned_pointer_elements():
	uint8[] bytes = new uint8[4]
	bytes[0] = 0 - 1
	bytes[1] = 128
	assert_equal(255, bytes[0])
	assert_equal(128, bytes[1])
	uint16[] shorts = new uint16[2]
	shorts[0] = 0 - 1
	assert_equal(65535, shorts[0])
	asserts(c"uint8 element must compare above 100", bytes[0] > 100)
