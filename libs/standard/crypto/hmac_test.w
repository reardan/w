# wbuild: x64
/*
HMAC-SHA-256 and HMAC-SHA-384 against the full RFC 4231 vector set
(test cases 1-7: short/long keys, short/long data; case 5 is published
truncated to 128 bits), plus streaming/reset behavior and the
constant-time comparison helper. Issue #195, plan 11 phase 4.
*/
import lib.testing
import libs.standard.crypto.sha2
import libs.standard.crypto.hmac


char* hmact_hex(char* mac, int len):
	char* out = malloc(len * 2 + 1)
	char* digits = c"0123456789abcdef"
	int i = 0
	while (i < len):
		int b = mac[i] & 255
		out[i * 2] = digits[(b >> 4) & 15]
		out[i * 2 + 1] = digits[b & 15]
		i = i + 1
	out[len * 2] = 0
	return out


int hmact_nibble(int c):
	if ((c >= '0') & (c <= '9')):
		return c - '0'
	return c - 'a' + 10


# Decode a lowercase hex string into malloc'd bytes (strlen(hex)/2 long).
char* hmact_unhex(char* hex):
	int n = strlen(hex) / 2
	char* out = malloc(n + 1)
	int i = 0
	while (i < n):
		out[i] = (hmact_nibble(hex[i * 2] & 255) << 4) | hmact_nibble(hex[i * 2 + 1] & 255)
		i = i + 1
	out[n] = 0
	return out


# Check one RFC 4231 case for one algorithm, comparing the first
# trunc_len MAC bytes (the full digest size except case 5).
void hmact_check(int alg, char* key, int key_len, char* data, int data_len, int trunc_len, char* want_hex):
	char* mac = malloc(whash_digest_size(alg))
	hmac_compute(alg, key, key_len, data, data_len, mac)
	char* got = hmact_hex(mac, trunc_len)
	assert_strings_equal(want_hex, got)
	free(got)
	free(mac)


void test_rfc4231_case1():
	char* key = hmact_unhex(c"0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b")
	hmact_check(WHASH_SHA256(), key, 20, c"Hi There", 8, 32, c"b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
	hmact_check(WHASH_SHA384(), key, 20, c"Hi There", 8, 48, c"afd03944d84895626b0825f4ab46907f15f9dadbe4101ec682aa034c7cebc59cfaea9ea9076ede7f4af152e8b2fa9cb6")
	free(key)


void test_rfc4231_case2():
	# Key shorter than the digest, data with a question mark.
	char* key = c"Jefe"
	char* data = c"what do ya want for nothing?"
	hmact_check(WHASH_SHA256(), key, 4, data, 28, 32, c"5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
	hmact_check(WHASH_SHA384(), key, 4, data, 28, 48, c"af45d2e376484031617f78d2b58a6b1b9c7ef464f5a01b47e42ec3736322445e8e2240ca5e69e2c78b3239ecfab21649")


void test_rfc4231_case3():
	char* key = hmact_unhex(c"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
	char* data = malloc(50)
	int i = 0
	while (i < 50):
		data[i] = 221 /* 0xdd */
		i = i + 1
	hmact_check(WHASH_SHA256(), key, 20, data, 50, 32, c"773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe")
	hmact_check(WHASH_SHA384(), key, 20, data, 50, 48, c"88062608d3e6ad8a0aa2ace014c8a86f0aa635d947ac9febe83ef4e55966144b2a5ab39dc13814b94e3ab6e101a34f27")
	free(data)
	free(key)


void test_rfc4231_case4():
	char* key = hmact_unhex(c"0102030405060708090a0b0c0d0e0f10111213141516171819")
	char* data = malloc(50)
	int i = 0
	while (i < 50):
		data[i] = 205 /* 0xcd */
		i = i + 1
	hmact_check(WHASH_SHA256(), key, 25, data, 50, 32, c"82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b")
	hmact_check(WHASH_SHA384(), key, 25, data, 50, 48, c"3e8a69b7783c25851933ab6290af6ca77a9981480850009cc5577c6e1f573b4e6801dd23c4a7d679ccf8a386c674cffb")
	free(data)
	free(key)


void test_rfc4231_case5():
	# RFC 4231 publishes this MAC truncated to 128 bits.
	char* key = hmact_unhex(c"0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c")
	char* data = c"Test With Truncation"
	hmact_check(WHASH_SHA256(), key, 20, data, 20, 16, c"a3b6167473100ee06e0c796c2955552b")
	hmact_check(WHASH_SHA384(), key, 20, data, 20, 16, c"3abf34c3503b2a23a46efc619baef897")
	free(key)


void test_rfc4231_case6():
	# 131-byte key: longer than both block sizes, so it is hashed first.
	char* key = malloc(131)
	int i = 0
	while (i < 131):
		key[i] = 170 /* 0xaa */
		i = i + 1
	char* data = c"Test Using Larger Than Block-Size Key - Hash Key First"
	hmact_check(WHASH_SHA256(), key, 131, data, 54, 32, c"60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54")
	hmact_check(WHASH_SHA384(), key, 131, data, 54, 48, c"4ece084485813e9088d2c63a041bc5b44f9ef1012a2b588f3cd11f05033ac4c60c2ef6ab4030fe8296248df163f44952")
	free(key)


void test_rfc4231_case7():
	char* key = malloc(131)
	int i = 0
	while (i < 131):
		key[i] = 170 /* 0xaa */
		i = i + 1
	char* data = c"This is a test using a larger than block-size key and a larger than block-size data. The key needs to be hashed before being used by the HMAC algorithm."
	hmact_check(WHASH_SHA256(), key, 131, data, 152, 32, c"9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2")
	hmact_check(WHASH_SHA384(), key, 131, data, 152, 48, c"6617178e941f020d351e2f254e8fd32c602420feb0b8fb9adccebb82461e99c5a678cc31e799176d3860e6110c46523e")
	free(key)


void test_streaming_and_reset():
	# Byte-at-a-time updates match the one-shot MAC; hmac_final is
	# non-destructive and hmac_reset restarts under the same key.
	char* data = c"what do ya want for nothing?"
	whmac* m = hmac_new(WHASH_SHA256(), c"Jefe", 4)
	int i = 0
	while (i < 28):
		hmac_update(m, data + i, 1)
		i = i + 1
	char* mac = malloc(32)
	hmac_final(m, mac)
	char* got = hmact_hex(mac, 32)
	assert_strings_equal(c"5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843", got)
	free(got)
	# Reset and MAC different data with the same key (case 1's key
	# differs, so just re-check case 2 after a reset round trip).
	hmac_reset(m)
	hmac_update(m, data, 28)
	hmac_final(m, mac)
	got = hmact_hex(mac, 32)
	assert_strings_equal(c"5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843", got)
	free(got)
	free(mac)
	hmac_free(m)


void test_constant_time_equal():
	char* a = hmact_unhex(c"00112233445566778899aabbccddeeff")
	char* b = hmact_unhex(c"00112233445566778899aabbccddeeff")
	char* c = hmact_unhex(c"00112233445566778899aabbccddeefe")
	char* d = hmact_unhex(c"80112233445566778899aabbccddeeff")
	assert_equal(1, hmac_equal(a, b, 16))
	# Difference in the last byte only.
	assert_equal(0, hmac_equal(a, c, 16))
	# Difference in the top bit of the first byte.
	assert_equal(0, hmac_equal(a, d, 16))
	# Prefixes compare equal when the difference lies past len.
	assert_equal(1, hmac_equal(a, c, 15))
	assert_equal(1, hmac_equal(a, b, 0))
	free(d)
	free(c)
	free(b)
	free(a)
