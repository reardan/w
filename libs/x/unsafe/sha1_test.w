# wbuild: x64
/*
SHA-1 (libs/x/unsafe/sha1.w) against the classic FIPS 180-4 / RFC 3174
vectors (empty, "abc", the 448-bit message, the million-'a' long
message), block-boundary lengths straddling the 64-byte block and
8-byte length field (cross-checked against Python's hashlib), streaming
vs one-shot equivalence, reset/clone reuse, and HMAC-SHA1 composition
through libs/standard/crypto/hmac.w with RFC 2202 vectors — the
integration proof that the whash extension registry works. Issue #209.
*/
import lib.testing
import lib.memory
import libs.standard.crypto.sha2
import libs.standard.crypto.hmac
import libs.x.unsafe.sha1


# Format len digest bytes as a lowercase hex string (malloc'd).
char* sha1t_hex(char* digest, int len):
	char* out = malloc(len * 2 + 1)
	char* digits = c"0123456789abcdef"
	int i = 0
	while (i < len):
		int b = digest[i] & 255
		out[i * 2] = digits[(b >> 4) & 15]
		out[i * 2 + 1] = digits[b & 15]
		i = i + 1
	out[len * 2] = 0
	return out


int sha1t_nibble(int c):
	if ((c >= '0') && (c <= '9')):
		return c - '0'
	return c - 'a' + 10


# Decode a lowercase hex string into malloc'd bytes (strlen(hex)/2 long).
char* sha1t_unhex(char* hex):
	int n = strlen(hex) / 2
	char* out = malloc(n + 1)
	int i = 0
	while (i < n):
		out[i] = (sha1t_nibble(hex[i * 2] & 255) << 4) | sha1t_nibble(hex[i * 2 + 1] & 255)
		i = i + 1
	out[n] = 0
	return out


void sha1t_check(char* data, int len, char* want_hex):
	char* digest = malloc(20)
	sha1(data, len, digest)
	char* got = sha1t_hex(digest, 20)
	assert_strings_equal(want_hex, got)
	free(got)
	free(digest)


void test_sha1_fips_vectors():
	sha1t_check(c"", 0, c"da39a3ee5e6b4b0d3255bfef95601890afd80709")
	sha1t_check(c"abc", 3, c"a9993e364706816aba3e25717850c26c9cd0d89d")
	# The 448-bit message.
	sha1t_check(c"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", 56, c"84983e441c3bd26ebaae4aa1f95129e5e54670f1")


void test_sha1_block_boundaries():
	# 55/56/63/64/65 'a's straddle the 0x80 terminator, the 8-byte length
	# field, and the 64-byte block edge (checked against hashlib).
	char* a65 = malloc(65)
	int i = 0
	while (i < 65):
		a65[i] = 'a'
		i = i + 1
	sha1t_check(a65, 55, c"c1c8bbdc22796e28c0e15163d20899b65621d65a")
	sha1t_check(a65, 56, c"c2db330f6083854c99d4b5bfb6e8f29f201be699")
	sha1t_check(a65, 63, c"03f09f5b158a7a8cdad920bddc29b81c18a551f5")
	sha1t_check(a65, 64, c"0098ba824b5c16427bd7a1122a5a442a25ec644d")
	sha1t_check(a65, 65, c"11655326c708d70319be2610e8a57d9a5b959d3b")
	free(a65)


void test_sha1_million_a():
	# The classic long-message vector: 1,000,000 x 'a', fed through the
	# streaming interface in 100k slices.
	int n = 1000000
	int chunk = 100000
	char* big = malloc(chunk)
	int i = 0
	while (i < chunk):
		big[i] = 'a'
		i = i + 1
	whash* h = whash_new(WHASH_SHA1())
	int fed = 0
	while (fed < n):
		whash_update(h, big, chunk)
		fed = fed + chunk
	char* digest = malloc(20)
	whash_final(h, digest)
	char* got = sha1t_hex(digest, 20)
	assert_strings_equal(c"34aa973cd4c4daa4f61eeb2bdbad27316534016f", got)
	free(got)
	free(digest)
	whash_free(h)
	free(big)


void test_sha1_whash_geometry():
	assert_equal(20, whash_digest_size(WHASH_SHA1()))
	assert_equal(64, whash_block_size(WHASH_SHA1()))
	assert_equal(5, whash_state_words(WHASH_SHA1()))


# Feeding input in ragged slices must match the one-shot digest.
void sha1t_check_streaming(char* data, int len, int step):
	whash* h = whash_new(WHASH_SHA1())
	int pos = 0
	while (pos < len):
		int take = step
		if (pos + take > len):
			take = len - pos
		whash_update(h, data + pos, take)
		pos = pos + take
	char* digest = malloc(20)
	whash_final(h, digest)
	char* got = sha1t_hex(digest, 20)
	char* oneshot = malloc(20)
	sha1(data, len, oneshot)
	char* want = sha1t_hex(oneshot, 20)
	assert_strings_equal(want, got)
	free(want)
	free(oneshot)
	free(got)
	free(digest)
	whash_free(h)


void test_sha1_streaming_matches_oneshot():
	char* msg = c"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
	sha1t_check_streaming(msg, 56, 1)
	sha1t_check_streaming(msg, 56, 7)
	sha1t_check_streaming(msg, 56, 64)


void test_sha1_reset_and_clone():
	# Reset rewinds to the empty message; a clone diverges independently.
	whash* h = whash_new(WHASH_SHA1())
	whash_update(h, c"ab", 2)
	whash* c = whash_clone(h)
	whash_update(c, c"c", 1)
	char* digest = malloc(20)
	whash_final(c, digest)
	char* got = sha1t_hex(digest, 20)
	assert_strings_equal(c"a9993e364706816aba3e25717850c26c9cd0d89d", got)
	free(got)
	whash_free(c)
	# The original still holds only "ab"; keep absorbing after a final.
	whash_update(h, c"c", 1)
	whash_final(h, digest)
	got = sha1t_hex(digest, 20)
	assert_strings_equal(c"a9993e364706816aba3e25717850c26c9cd0d89d", got)
	free(got)
	whash_reset(h)
	whash_final(h, digest)
	got = sha1t_hex(digest, 20)
	assert_strings_equal(c"da39a3ee5e6b4b0d3255bfef95601890afd80709", got)
	free(got)
	free(digest)
	whash_free(h)


void sha1t_check_hmac(char* key, int key_len, char* data, int data_len, char* want_hex):
	char* mac = malloc(20)
	hmac_compute(WHASH_SHA1(), key, key_len, data, data_len, mac)
	char* got = sha1t_hex(mac, 20)
	assert_strings_equal(want_hex, got)
	free(got)
	free(mac)


void test_hmac_sha1_rfc2202():
	# RFC 2202 section 3 cases 1-3 and 6; case 6's 80-byte key exercises
	# the hash-the-key path through whash_oneshot.
	char* key1 = sha1t_unhex(c"0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b")
	sha1t_check_hmac(key1, 20, c"Hi There", 8, c"b617318655057264e28bc0b6fb378c8ef146be00")
	free(key1)
	sha1t_check_hmac(c"Jefe", 4, c"what do ya want for nothing?", 28, c"effcdf6ae5eb2fa2d27416d5f184df9c259a7c79")
	char* key3 = sha1t_unhex(c"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
	char* data3 = malloc(50)
	int i = 0
	while (i < 50):
		data3[i] = 221 /* 0xdd */
		i = i + 1
	sha1t_check_hmac(key3, 20, data3, 50, c"125d7342b9ac11cd91a39af48aa17b4f63f175d3")
	free(data3)
	free(key3)
	char* key6 = malloc(80)
	i = 0
	while (i < 80):
		key6[i] = 170 /* 0xaa */
		i = i + 1
	sha1t_check_hmac(key6, 80, c"Test Using Larger Than Block-Size Key - Hash Key First", 54, c"aa4ae5e15272d00e95705637ce8a3b55ed402112")
	free(key6)
