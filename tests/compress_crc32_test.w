# wbuild: x64
/*
libs/extras/compress/crc32.w tests: the standard "123456789" check value
(0xCBF43926 -- the same vector used by every common CRC-32/ISO-HDLC
implementation, e.g. zlib's crc32(), so it is directly cross-checkable),
the empty-input identity, incremental updates matching the one-shot
digest, and a negative-length clamp.

Expected constants are assembled the same runtime-shift way crc32.w
builds its own polynomial/mask (docs/projects/compress.md §6.1): both
0xcbf4 and 0x3926 sit well under 2^31 individually, so writing them as
two hex literals shifted together avoids ever spelling the full
(bit-31-set) 0xCBF43926 as a literal token.
*/
import lib.testing
import libs.extras.compress.crc32


int crc32t_known_answer():
	return (0xcbf4 << 16) | 0x3926


void test_crc32_known_vector():
	assert_equal(crc32t_known_answer(), crc32_of(c"123456789", 9))


void test_crc32_empty_is_zero():
	assert_equal(0, crc32_of(c"", 0))
	assert_equal(0, crc32_of(c"anything", 0))


void test_crc32_incremental_matches_oneshot():
	int incremental = crc32_update(crc32_update(0, c"123", 3), c"456789", 6)
	assert_equal(crc32t_known_answer(), incremental)

	# Splitting at every possible boundary should agree with the one-shot
	# digest of the whole string.
	char* s = c"123456789"
	int i = 0
	while (i <= 9):
		int a = crc32_update(0, s, i)
		int b = crc32_update(a, s + i, 9 - i)
		assert_equal(crc32t_known_answer(), b)
		i = i + 1


void test_crc32_negative_length_clamps_to_zero():
	assert_equal(0, crc32_of(c"123456789", -1))
	assert_equal(crc32_of(c"", 0), crc32_of(c"123456789", -5))


void test_crc32_single_bit_change_differs():
	# Sanity: CRC-32 is sensitive to single-byte changes (not a proof of
	# any error-detection property, just guards against a degenerate
	# always-same-value implementation bug).
	int a = crc32_of(c"the quick brown fox", 19)
	int b = crc32_of(c"the quick brown fon", 19)
	assert1(a != b)
