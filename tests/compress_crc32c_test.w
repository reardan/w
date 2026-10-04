# wbuild: x64
/*
libs/extras/compress/crc32c.w tests: the "123456789" check values for
CRC-32C (0xE3069283) and, side by side, CRC-32/IEEE (0xCBF43926) to pin
that the two polynomials are distinct; RFC 3720 appendix B.4's iSCSI
vectors; empty input; incremental-equals-one-shot at every split; and a
NUL-bearing input.

Expected values are built from two sub-2^31 16-bit halves (crc32's test
discipline) and both sides are compared as masked 32-bit words, so the
same assertions hold on x86 (bit 31 reads back negative) and x64
(positive).
*/
import lib.testing
import libs.extras.compress.crc32
import libs.extras.compress.crc32c


int word32(int high, int low):
	return ((high << 16) | low) & crc32c_mask32()


void test_crc32c_known_vector():
	crc32c_init_tables()
	assert_equal(word32(0xe306, 0x9283), crc32c_of(c"123456789", 9))


void test_crc32_and_crc32c_are_distinct():
	assert_equal(word32(0xcbf4, 0x3926), crc32_of(c"123456789", 9) & crc32c_mask32())
	assert1(crc32_poly() != crc32c_poly())
	assert_equal(word32(0x82f6, 0x3b78), crc32c_poly())
	assert_equal(word32(0xedb8, 0x8320), crc32_poly())
	assert1(crc32_of(c"123456789", 9) != crc32c_of(c"123456789", 9))
	assert_strings_equal(c"crc32c-castagnoli", crc32c_name())


void test_crc32c_iscsi_vectors():
	char* buf = malloc(32)
	for i in range(32): buf[i] = 0
	assert_equal(word32(0x8a91, 0x36aa), crc32c_of(buf, 32))
	for i in range(32): buf[i] = 255
	assert_equal(word32(0x62a8, 0xab43), crc32c_of(buf, 32))
	for i in range(32): buf[i] = i
	assert_equal(word32(0x46dd, 0x794e), crc32c_of(buf, 32))
	for i in range(32): buf[i] = 31 - i
	assert_equal(word32(0x113f, 0xdb5c), crc32c_of(buf, 32))
	free(buf)


void test_crc32c_empty():
	assert_equal(0, crc32c_of(c"", 0))
	assert_equal(0, crc32c_of(c"ignored", 0))
	assert_equal(0, crc32c_of(c"ignored", 0 - 3))
	# Updating with nothing leaves a checksum unchanged.
	int c = crc32c_of(c"123456789", 9)
	assert_equal(c, crc32c_update(c, c"", 0))


void test_crc32c_incremental_matches_oneshot():
	char* s = c"123456789"
	int want = word32(0xe306, 0x9283)
	for i in range(9 + 1):
		int a = crc32c_update(0, s, i)
		assert_equal(want, crc32c_update(a, s + i, 9 - i))
	# Byte at a time.
	int c = 0
	for i in range(9): c = crc32c_update(c, s + i, 1)
	assert_equal(want, c)


void test_crc32c_sign_extended_continuation():
	# A running value spelled as a sign-extended literal on x64 still
	# continues correctly (the input is masked to 32 bits).
	int partial = crc32c_of(c"1234", 4)
	int spelled = partial
	if ((partial >> 31) & 1): spelled = partial | (0 - 1 - crc32c_mask32())
	assert_equal(crc32c_of(c"123456789", 9), crc32c_update(spelled, c"56789", 5))


void test_crc32c_embedded_nul():
	assert_equal(word32(0x63f9, 0xa95c), crc32c_of(c"a\x00b", 3))
	assert1(crc32c_of(c"a\x00b", 3) != crc32c_of(c"a\x00c", 3))
