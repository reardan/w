# wbuild: x64
/*
RC4 (libs/x/unsafe/rc4.w) against RFC 6229 keystream vectors: a subset
across key sizes (40/56/128/256 bits) and stream offsets (0, 16, 240,
256), plus chunked-vs-one-shot keystream equivalence, rekey reuse via
rc4_reset, and the xor helper's encrypt/decrypt round trip. Issue #209.
*/
import lib.testing
import lib.memory
import libs.x.unsafe.rc4


# Format len bytes as a lowercase hex string (malloc'd).
char* rc4t_hex(char* data, int len):
	char* out = malloc(len * 2 + 1)
	char* digits = c"0123456789abcdef"
	int i = 0
	while (i < len):
		int b = data[i] & 255
		out[i * 2] = digits[(b >> 4) & 15]
		out[i * 2 + 1] = digits[b & 15]
		i = i + 1
	out[len * 2] = 0
	return out


int rc4t_nibble(int c):
	if ((c >= '0') && (c <= '9')):
		return c - '0'
	return c - 'a' + 10


# Decode a lowercase hex string into malloc'd bytes (strlen(hex)/2 long).
char* rc4t_unhex(char* hex):
	int n = strlen(hex) / 2
	char* out = malloc(n + 1)
	int i = 0
	while (i < n):
		out[i] = (rc4t_nibble(hex[i * 2] & 255) << 4) | rc4t_nibble(hex[i * 2 + 1] & 255)
		i = i + 1
	out[n] = 0
	return out


# Check 16 keystream bytes at stream offset `off` for the hex key.
void rc4t_check_at(char* key_hex, int off, char* want_hex):
	char* key = rc4t_unhex(key_hex)
	rc4* r = rc4_new(key, strlen(key_hex) / 2)
	char* ks = malloc(off + 16)
	rc4_keystream(r, ks, off + 16)
	char* got = rc4t_hex(ks + off, 16)
	assert_strings_equal(want_hex, got)
	free(got)
	free(ks)
	rc4_free(r)
	free(key)


void test_rc4_rfc6229_key40():
	rc4t_check_at(c"0102030405", 0, c"b2396305f03dc027ccc3524a0a1118a8")
	rc4t_check_at(c"0102030405", 16, c"6982944f18fc82d589c403a47a0d0919")
	rc4t_check_at(c"0102030405", 240, c"28cb1132c96ce286421dcaadb8b69eae")
	rc4t_check_at(c"0102030405", 256, c"1cfcf62b03eddb641d77dfcf7f8d8c93")


void test_rc4_rfc6229_key56():
	rc4t_check_at(c"01020304050607", 0, c"293f02d47f37c9b633f2af5285feb46b")
	rc4t_check_at(c"01020304050607", 16, c"e620f1390d19bd84e2e0fd752031afc1")
	rc4t_check_at(c"01020304050607", 240, c"914f02531c9218810df60f67e338154c")
	rc4t_check_at(c"01020304050607", 256, c"d0fdb583073ce85ab83917740ec011d5")


void test_rc4_rfc6229_key128():
	rc4t_check_at(c"0102030405060708090a0b0c0d0e0f10", 0, c"9ac7cc9a609d1ef7b2932899cde41b97")
	rc4t_check_at(c"0102030405060708090a0b0c0d0e0f10", 16, c"5248c4959014126a6e8a84f11d1a9e1c")
	rc4t_check_at(c"0102030405060708090a0b0c0d0e0f10", 240, c"065902e4b620f6cc36c8589f66432f2b")
	rc4t_check_at(c"0102030405060708090a0b0c0d0e0f10", 256, c"d39d566bc6bce3010768151549f3873f")


void test_rc4_rfc6229_key256():
	char* key = c"0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"
	rc4t_check_at(key, 0, c"eaa6bd25880bf93d3f5d1e4ca2611d91")
	rc4t_check_at(key, 16, c"cfa45c9f7e714b54bdfa80027cb14380")
	rc4t_check_at(key, 240, c"114ae344ded71b35f2e60febad727fd8")
	rc4t_check_at(key, 256, c"02e1e7056b0f623900496422943e97b6")


void test_rc4_chunked_matches_oneshot():
	# Drawing the keystream in ragged chunks must equal one big draw.
	char* key = rc4t_unhex(c"0102030405060708090a0b0c0d0e0f10")
	rc4* a = rc4_new(key, 16)
	rc4* b = rc4_new(key, 16)
	char* one = malloc(272)
	rc4_keystream(a, one, 272)
	char* many = malloc(272)
	int pos = 0
	int step = 1
	while (pos < 272):
		int take = step
		if (pos + take > 272):
			take = 272 - pos
		rc4_keystream(b, many + pos, take)
		pos = pos + take
		step = step + 3
	char* want = rc4t_hex(one, 272)
	char* got = rc4t_hex(many, 272)
	assert_strings_equal(want, got)
	free(got)
	free(want)
	free(many)
	free(one)
	rc4_free(b)
	rc4_free(a)
	free(key)


void test_rc4_reset_reuse():
	# Rekeying an existing instance restarts the keystream exactly.
	char* key = rc4t_unhex(c"0102030405")
	rc4* r = rc4_new(key, 5)
	char* ks = malloc(64)
	rc4_keystream(r, ks, 64)
	rc4_reset(r, key, 5)
	rc4_keystream(r, ks, 16)
	char* got = rc4t_hex(ks, 16)
	assert_strings_equal(c"b2396305f03dc027ccc3524a0a1118a8", got)
	free(got)
	# Rekeying with a different key switches streams.
	char* key2 = rc4t_unhex(c"01020304050607")
	rc4_reset(r, key2, 7)
	rc4_keystream(r, ks, 16)
	got = rc4t_hex(ks, 16)
	assert_strings_equal(c"293f02d47f37c9b633f2af5285feb46b", got)
	free(got)
	free(key2)
	free(ks)
	rc4_free(r)
	free(key)


void test_rc4_process_roundtrip():
	# Encryption and decryption are the same xor; a fresh instance with
	# the same key restores the plaintext, in place.
	char* plain = c"Attack at dawn"
	char* buf = malloc(15)
	int i = 0
	while (i < 14):
		buf[i] = plain[i]
		i = i + 1
	buf[14] = 0
	rc4* r = rc4_new(c"Secret", 6)
	rc4_process(r, buf, buf, 14)
	rc4_free(r)
	# Ciphertext cross-checked against an independent implementation.
	char* got = rc4t_hex(buf, 14)
	assert_strings_equal(c"45a01f645fc35b383552544b9bf5", got)
	free(got)
	r = rc4_new(c"Secret", 6)
	rc4_process(r, buf, buf, 14)
	rc4_free(r)
	buf[14] = 0
	assert_strings_equal(plain, buf)
	free(buf)
