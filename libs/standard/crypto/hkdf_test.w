/*
HKDF against RFC 5869 test cases 1-3 (SHA-256: basic, maximal-length
inputs, zero-length salt/info), an HKDF-SHA-384 cross-check (RFC 5869 has
no SHA-384 cases; expected values computed with Python's hmac/hashlib),
and the TLS 1.3 key schedule against the RFC 8448 §3 simple 1-RTT trace:
early secret, Derive-Secret(., "derived", ""), handshake secret, the
client/server handshake traffic secrets over the real ClientHello +
ServerHello bytes, the master secret, and the server handshake write
key/iv via HKDF-Expand-Label. Issue #195, plan 11 phase 4.
*/
import lib.testing
import libs.standard.crypto.sha2
import libs.standard.crypto.hmac
import libs.standard.crypto.hkdf


char* hkdft_hex(char* data, int len):
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


int hkdft_nibble(int c):
	if ((c >= '0') & (c <= '9')):
		return c - '0'
	return c - 'a' + 10


char* hkdft_unhex(char* hex):
	int n = strlen(hex) / 2
	char* out = malloc(n + 1)
	int i = 0
	while (i < n):
		out[i] = (hkdft_nibble(hex[i * 2] & 255) << 4) | hkdft_nibble(hex[i * 2 + 1] & 255)
		i = i + 1
	out[n] = 0
	return out


void hkdft_assert_bytes(char* want_hex, char* got, int len):
	char* got_hex = hkdft_hex(got, len)
	assert_strings_equal(want_hex, got_hex)
	free(got_hex)


void test_rfc5869_case1():
	char* ikm = hkdft_unhex(c"0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b")
	char* salt = hkdft_unhex(c"000102030405060708090a0b0c")
	char* info = hkdft_unhex(c"f0f1f2f3f4f5f6f7f8f9")
	char* prk = malloc(32)
	hkdf_extract(WHASH_SHA256(), salt, 13, ikm, 22, prk)
	hkdft_assert_bytes(c"077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5", prk, 32)
	char* okm = malloc(42)
	assert_equal(1, hkdf_expand(WHASH_SHA256(), prk, 32, info, 10, okm, 42))
	hkdft_assert_bytes(c"3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865", okm, 42)
	free(okm)
	free(prk)
	free(info)
	free(salt)
	free(ikm)


void test_rfc5869_case2():
	# Longer inputs/outputs: ikm 0x00..0x4f, salt 0x60..0xaf, info
	# 0xb0..0xff, 82 bytes of output (crosses three expand rounds).
	char* ikm = malloc(80)
	char* salt = malloc(80)
	char* info = malloc(80)
	int i = 0
	while (i < 80):
		ikm[i] = i
		salt[i] = 96 + i
		info[i] = (176 + i) & 255
		i = i + 1
	char* prk = malloc(32)
	hkdf_extract(WHASH_SHA256(), salt, 80, ikm, 80, prk)
	hkdft_assert_bytes(c"06a6b88c5853361a06104c9ceb35b45cef760014904671014a193f40c15fc244", prk, 32)
	char* okm = malloc(82)
	assert_equal(1, hkdf_expand(WHASH_SHA256(), prk, 32, info, 80, okm, 82))
	hkdft_assert_bytes(c"b11e398dc80327a1c8e7f78c596a49344f012eda2d4efad8a050cc4c19afa97c59045a99cac7827271cb41c65e590e09da3275600c2f09b8367793a9aca3db71cc30c58179ec3e87c14c01d5c1f3434f1d87", okm, 82)
	free(okm)
	free(prk)
	free(info)
	free(salt)
	free(ikm)


void test_rfc5869_case3():
	# Zero-length salt and info.
	char* ikm = hkdft_unhex(c"0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b")
	char* prk = malloc(32)
	hkdf_extract(WHASH_SHA256(), c"", 0, ikm, 22, prk)
	hkdft_assert_bytes(c"19ef24a32c717b167f33a91d6f648bdf96596776afdb6377ac434c1c293ccb04", prk, 32)
	char* okm = malloc(42)
	assert_equal(1, hkdf_expand(WHASH_SHA256(), prk, 32, c"", 0, okm, 42))
	hkdft_assert_bytes(c"8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8", okm, 42)
	free(okm)
	free(prk)
	free(ikm)


void test_hkdf_sha384():
	# Case-1-shaped inputs under SHA-384; expected values computed with
	# a reference implementation (Python hmac/hashlib).
	char* ikm = hkdft_unhex(c"0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b")
	char* salt = hkdft_unhex(c"000102030405060708090a0b0c")
	char* info = hkdft_unhex(c"f0f1f2f3f4f5f6f7f8f9")
	char* prk = malloc(48)
	hkdf_extract(WHASH_SHA384(), salt, 13, ikm, 22, prk)
	hkdft_assert_bytes(c"704b39990779ce1dc548052c7dc39f303570dd13fb39f7acc564680bef80e8dec70ee9a7e1f3e293ef68eceb072a5ade", prk, 48)
	char* okm = malloc(48)
	assert_equal(1, hkdf_expand(WHASH_SHA384(), prk, 48, info, 10, okm, 48))
	hkdft_assert_bytes(c"9b5097a86038b805309076a44b3a9f38063e25b516dcbf369f394cfab43685f748b6457763e4f0204fc5d95d1da3e625", okm, 48)
	free(okm)
	free(prk)
	free(info)
	free(salt)
	free(ikm)


void test_hkdf_expand_bounds():
	char* prk = malloc(32)
	int i = 0
	while (i < 32):
		prk[i] = i
		i = i + 1
	char* okm = malloc(32)
	# 255 * 32 = 8160 is the SHA-256 ceiling; one past it must fail.
	assert_equal(0, hkdf_expand(WHASH_SHA256(), prk, 32, c"", 0, okm, 8161))
	assert_equal(0, hkdf_expand(WHASH_SHA256(), prk, 32, c"", 0, okm, -1))
	assert_equal(1, hkdf_expand(WHASH_SHA256(), prk, 32, c"", 0, okm, 0))
	free(okm)
	free(prk)


# The RFC 8448 §3 ClientHello and ServerHello handshake messages (the
# transcript for the handshake traffic secrets).
char* hkdft_rfc8448_client_hello():
	return c"010000c00303cb34ecb1e78163ba1c38c6dacb196a6dffa21a8d9912ec18a2ef6283024dece7000006130113031302010000910000000b0009000006736572766572ff01000100000a00140012001d0017001800190100010101020103010400230000003300260024001d002099381de560e4bd43d23d8e435a7dbafeb3c06e51c13cae4d5413691e529aaf2c002b0003020304000d0020001e040305030603020308040805080604010501060102010402050206020202002d00020101001c00024001"


char* hkdft_rfc8448_server_hello():
	return c"020000560303a6af06a4121860dc5e6e60249cd34c95930c8ac5cb1434dac155772ed3e2692800130100002e00330024001d0020c9828876112095fe66762bdbf7c672e156d6cc253b833df1dd69b1b04e751f0f002b00020304"


void test_rfc8448_key_schedule():
	int alg = WHASH_SHA256()
	# transcript = ClientHello || ServerHello (196 + 90 bytes).
	char* ch = hkdft_unhex(hkdft_rfc8448_client_hello())
	char* sh = hkdft_unhex(hkdft_rfc8448_server_hello())
	char* transcript = malloc(286)
	int i = 0
	while (i < 196):
		transcript[i] = ch[i]
		i = i + 1
	i = 0
	while (i < 90):
		transcript[196 + i] = sh[i]
		i = i + 1
	free(sh)
	free(ch)
	char* th = malloc(32)
	whash_oneshot(alg, transcript, 286, th)
	hkdft_assert_bytes(c"860c06edc07858ee8e78f0e7428c58edd6b43f2ca3e6e95f02ed063cf0e1cad8", th, 32)

	# early_secret = HKDF-Extract(salt="", IKM=32 zero bytes)
	char* zeros = malloc(32)
	i = 0
	while (i < 32):
		zeros[i] = 0
		i = i + 1
	char* early = malloc(32)
	hkdf_extract(alg, c"", 0, zeros, 32, early)
	hkdft_assert_bytes(c"33ad0a1c607ec03b09e6cd9893680ce210adf300aa1f2660e1b22e10f170f92a", early, 32)

	# Derive-Secret(early, "derived", "") — empty transcript.
	char* derived = malloc(32)
	assert_equal(1, tls13_derive_secret(alg, early, c"derived", 7, c"", 0, derived))
	hkdft_assert_bytes(c"6f2615a108c702c5678f54fc9dbab69716c076189c48250cebeac3576c3611ba", derived, 32)

	# handshake_secret = HKDF-Extract(derived, X25519 shared secret).
	char* ecdhe = hkdft_unhex(c"8bd4054fb55b9d63fdfbacf9f04b9f0d35e6d63f537563efd46272900f89492d")
	char* hs = malloc(32)
	hkdf_extract(alg, derived, 32, ecdhe, 32, hs)
	hkdft_assert_bytes(c"1dc826e93606aa6fdc0aadc12f741b01046aa6b99f691ed221a9f0ca043fbeac", hs, 32)

	# Handshake traffic secrets over the CH..SH transcript.
	char* chts = malloc(32)
	char* shts = malloc(32)
	assert_equal(1, tls13_derive_secret(alg, hs, c"c hs traffic", 12, transcript, 286, chts))
	assert_equal(1, tls13_derive_secret(alg, hs, c"s hs traffic", 12, transcript, 286, shts))
	hkdft_assert_bytes(c"b3eddb126e067f35a780b3abf45e2d8f3b1a950738f52e9600746a0e27a55a21", chts, 32)
	hkdft_assert_bytes(c"b67b7d690cc16c4e75e54213cb2d37b4e9c912bcded9105d42befd59d391ad38", shts, 32)

	# master_secret = HKDF-Extract(Derive-Secret(hs, "derived", ""), zeros)
	char* derived2 = malloc(32)
	assert_equal(1, tls13_derive_secret(alg, hs, c"derived", 7, c"", 0, derived2))
	char* master = malloc(32)
	hkdf_extract(alg, derived2, 32, zeros, 32, master)
	hkdft_assert_bytes(c"18df06843d13a08bf2a449844c5f8a478001bc4d4c627984d5a41da8d0402919", master, 32)

	# Record-protection keys come from HKDF-Expand-Label with an empty
	# context and non-digest output lengths.
	char* key = malloc(16)
	char* iv = malloc(12)
	assert_equal(1, tls13_hkdf_expand_label(alg, shts, c"key", 3, c"", 0, key, 16))
	assert_equal(1, tls13_hkdf_expand_label(alg, shts, c"iv", 2, c"", 0, iv, 12))
	hkdft_assert_bytes(c"3fce516009c21727d0f2e4e86ee403bc", key, 16)
	hkdft_assert_bytes(c"5d313eb2671276ee13000b30", iv, 12)

	# Expand-Label with a transcript-hash context (the streaming-whash
	# caller path) must agree with Derive-Secret over the raw messages.
	char* chts2 = malloc(32)
	assert_equal(1, tls13_hkdf_expand_label(alg, hs, c"c hs traffic", 12, th, 32, chts2, 32))
	assert_equal(1, hmac_equal(chts, chts2, 32))

	# Label bounds: prefixed label must fit one length byte.
	char* big_label = malloc(251)
	i = 0
	while (i < 250):
		big_label[i] = 'x'
		i = i + 1
	big_label[250] = 0
	assert_equal(0, tls13_hkdf_expand_label(alg, hs, big_label, 250, c"", 0, chts2, 32))
	assert_equal(1, tls13_hkdf_expand_label(alg, hs, big_label, 249, c"", 0, chts2, 32))

	free(big_label)
	free(chts2)
	free(iv)
	free(key)
	free(master)
	free(derived2)
	free(shts)
	free(chts)
	free(hs)
	free(ecdhe)
	free(derived)
	free(early)
	free(zeros)
	free(th)
	free(transcript)
