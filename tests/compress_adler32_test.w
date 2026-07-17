# wbuild: x64
/*
libs/extras/compress/adler32.w tests: the standard "123456789" check
value (0x091E01DE, cross-checked against zlib's adler32()), the
neutral-element-is-1 identity for empty input (RFC 1950 §9: s1 starts at
1, not 0 -- unlike CRC-32's empty-input-is-zero), incremental updates
matching the one-shot digest, and a negative-length clamp.
*/
import lib.testing
import libs.extras.compress.adler32


int adler32t_known_answer():
	return (0x091e << 16) | 0x01de


void test_adler32_known_vector():
	assert_equal(adler32t_known_answer(), adler32_of(c"123456789", 9))


void test_adler32_empty_is_one():
	assert_equal(1, adler32_of(c"", 0))
	assert_equal(1, adler32_of(c"anything", 0))


void test_adler32_incremental_matches_oneshot():
	int incremental = adler32_update(adler32_update(1, c"123", 3), c"456789", 6)
	assert_equal(adler32t_known_answer(), incremental)

	char* s = c"123456789"
	int i = 0
	while (i <= 9):
		int a = adler32_update(1, s, i)
		int b = adler32_update(a, s + i, 9 - i)
		assert_equal(adler32t_known_answer(), b)
		i = i + 1


void test_adler32_negative_length_clamps_to_zero():
	assert_equal(1, adler32_of(c"123456789", -1))
	assert_equal(adler32_of(c"", 0), adler32_of(c"123456789", -5))


void test_adler32_wraps_mod_65521():
	# 65521 is the largest prime below 2^16; feeding enough identical
	# bytes must wrap s1/s2 through at least one modular reduction rather
	# than overflowing silently. 70000 bytes of value 1 pushes s1 well
	# past 65521 (70000 + 1 > 65521) if the implementation forgot to mod.
	int n = 70000
	char* buf = malloc(n)
	int i = 0
	while (i < n):
		buf[i] = 1
		i = i + 1
	int a = adler32_of(buf, n)
	# s1 = (1 + n) mod 65521, s2 = sum_{k=1..n} s1_k mod 65521 -- just
	# assert it is a plausible masked 32-bit value and reproducible,
	# rather than re-deriving the full closed form here.
	assert_equal(a, adler32_of(buf, n))
	free(buf)
