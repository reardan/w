# wbuild: x64
# lib/bytes.w: fixed-width loads/stores (including the 64-bit forms on
# both word sizes) and unsigned lexicographic comparison.
import lib.testing
import lib.bytes


int is64():
	if (sizeof(int) == 8): return 1
	return 0


void test_fixed_width_round_trips():
	char* p = malloc(8)
	store_be16(p, 0xbeef)
	assert_equal(0xbe, p[0] & 255)
	assert_equal(0xbeef, load_be16(p))
	store_le16(p, 0xbeef)
	assert_equal(0xef, p[0] & 255)
	assert_equal(0xbeef, load_le16(p))
	store_be32(p, 0x12345678)
	assert_equal(0x12, p[0] & 255)
	assert_equal(0x12345678, load_be32(p))
	store_le32(p, 0x12345678)
	assert_equal(0x78, p[0] & 255)
	assert_equal(0x12345678, load_le32(p))
	free(p)


# A 32-bit load with bit 31 set follows the masked-word convention.
void test_load32_high_bit():
	char* p = malloc(4)
	store_be32(p, cast(int, 0xfedcba98))
	int v = load_be32(p)
	assert_equal(bytes_mask32() & cast(int, 0xfedcba98), v)
	if (is64()): assert1(v > 0)
	else: assert1(v < 0)
	free(p)


void test_64_parts_round_trip():
	char* p = malloc(8)
	int hi = 0
	int lo = 0
	store_be64_parts(p, 0x01020304, cast(int, 0xf5f6f7f8))
	assert_equal(0x01, p[0] & 255)
	assert_equal(0xf8, p[7] & 255)
	load_be64_parts(p, &hi, &lo)
	assert_equal(0x01020304, hi)
	assert_equal(bytes_mask32() & cast(int, 0xf5f6f7f8), lo)
	store_le64_parts(p, 0x01020304, cast(int, 0xf5f6f7f8))
	assert_equal(0xf8, p[0] & 255)
	assert_equal(0x01, p[7] & 255)
	load_le64_parts(p, &hi, &lo)
	assert_equal(0x01020304, hi)
	assert_equal(bytes_mask32() & cast(int, 0xf5f6f7f8), lo)
	free(p)


int word_hi32(int v):
	int hi = 0
	int lo = 0
	bytes_split64(v, &hi, &lo)
	return hi


void test_64_word_checked():
	char* p = malloc(8)
	int v = 7
	store_be64_parts(p, 0, 0x7fffffff)
	assert_equal(1, load_be64_word(p, &v))
	assert_equal(0x7fffffff, v)
	store_be64_parts(p, 1, 0)
	if (is64()):
		assert_equal(1, load_be64_word(p, &v))
		assert_equal(1, word_hi32(v))
		assert_equal(v, load_be64(p))
	else:
		# Never truncated to the low word.
		assert_equal(0, load_be64_word(p, &v))
		assert_equal(0, v)
	store_le64_parts(p, 0, 5)
	assert_equal(1, load_le64_word(p, &v))
	assert_equal(5, v)
	free(p)


void test_64_native_round_trip():
	char* p = malloc(8)
	store_be64(p, 0x12345678)
	assert_equal(0, p[0])
	assert_equal(0x78, p[7] & 255)
	assert_equal(0x12345678, load_be64(p))
	store_le64(p, 0x12345678)
	assert_equal(0x78, p[0] & 255)
	assert_equal(0x12345678, load_le64(p))
	# -1 is the all-ones word: 8 bytes of ff on 64-bit, a zero-extended
	# 32-bit pattern on 32-bit; both read back as -1.
	store_be64(p, 0 - 1)
	assert_equal(255, p[7] & 255)
	if (is64()): assert_equal(255, p[0] & 255)
	else: assert_equal(0, p[0] & 255)
	assert_equal(0 - 1, load_be64(p))
	if (is64()):
		int big = (0x0a0b0c0d << 32) | 0x01020304
		store_be64(p, big)
		assert_equal(0x0a, p[0] & 255)
		assert_equal(0x04, p[7] & 255)
		assert_equal(big, load_be64(p))
		store_le64(p, big)
		assert_equal(0x04, p[0] & 255)
		assert_equal(big, load_le64(p))
		int top = 1 << 63
		store_le64(p, top)
		assert_equal(128, p[7] & 255)
		assert_equal(top, load_le64(p))
	free(p)


void test_bytes_compare_unsigned():
	assert_equal(0, bytes_compare(c"abc", 3, c"abc", 3))
	assert_equal(0 - 1, bytes_compare(c"ab", 2, c"abc", 3))
	assert_equal(1, bytes_compare(c"abc", 3, c"ab", 2))
	assert_equal(0 - 1, bytes_compare(c"abc", 3, c"abd", 3))
	assert_equal(0, bytes_compare(c"", 0, c"", 0))
	# 0x80 sorts after 0x7f (unsigned bytes, not signed chars).
	assert_equal(1, bytes_compare(c"\x80", 1, c"\x7f", 1))
	assert_equal(1, bytes_compare(c"\xff", 1, c"\x00", 1))
	# Embedded NUL bytes are ordinary bytes.
	assert_equal(0 - 1, bytes_compare(c"a\x00b", 3, c"a\x00c", 3))
	assert_equal(1, bytes_compare(c"a\x00", 2, c"a", 1))
	assert_equal(1, bytes_equal(c"a\x00b", 3, c"a\x00b", 3))
	assert_equal(0, bytes_equal(c"a\x00b", 3, c"a\x00c", 3))
	assert_equal(0, bytes_equal(c"a\x00", 2, c"a", 1))


void test_string_append_be64():
	string_builder* b = string_new()
	string_append_be64(b, 0x01020304)
	assert_equal(8, b.length)
	assert_equal(0, b.data[0])
	assert_equal(4, b.data[7])
	string_free(b)
