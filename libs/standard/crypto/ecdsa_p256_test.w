# Tests for libs/standard/crypto/ecdsa_p256.w.
#
# Vectors:
#  - RFC 6979 Appendix A.2.5 (P-256, SHA-256): deterministic signatures for the
#    messages "sample" and "test", and the corresponding public key. These are
#    the canonical published values.
#  - One independent verify vector produced by OpenSSL (via the genvec harness).
# Hashes are recomputed in-test from the message with lib/sha256.w, so the
# signing path is exercised end to end.
import lib.testing
import lib.sha256
import libs.standard.crypto.ecdsa_p256


int te_hexval(int c):
	if ((c >= '0') & (c <= '9')):
		return c - '0'
	if ((c >= 'a') & (c <= 'f')):
		return c - 'a' + 10
	if ((c >= 'A') & (c <= 'F')):
		return c - 'A' + 10
	return 0


# Decode exactly 32 bytes from a 64-char big-endian hex string into out.
void te_hex32(char* h, char* out):
	int i = 0
	while (i < 32):
		out[i] = (te_hexval(h[i * 2]) << 4) | te_hexval(h[i * 2 + 1])
		i = i + 1


int te_bytes_equal(char* a, char* b, int n):
	int i = 0
	while (i < n):
		if ((a[i] & 255) != (b[i] & 255)):
			return 0
		i = i + 1
	return 1


void te_assert_hex32(char* got, char* want_hex):
	char* want = malloc(32)
	te_hex32(want_hex, want)
	if (te_bytes_equal(got, want, 32) == 0):
		println(c"ecdsa: 32-byte value mismatch, wanted:")
		println(want_hex)
		exit(1)
	free(want)


char* TE_D():
	return c"c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721"


char* TE_UX():
	return c"60fed4ba255a9d31c961eb74c6356d68c049b8923b61fa6ce669622e60f29fb6"


char* TE_UY():
	return c"7903fe1008b8bc99a41ae9e95628bc64f2f1b20c2d7e9f5177a3c294d4462299"


void test_public_key_derivation():
	# Q = d*G must match the RFC 6979 A.2.5 public key (validates the
	# constant-time scalar-multiplication ladder).
	char* d = malloc(32)
	te_hex32(TE_D(), d)
	char* qx = malloc(32)
	char* qy = malloc(32)
	assert_equal(1, ecdsa_p256_public_key(d, qx, qy))
	te_assert_hex32(qx, TE_UX())
	te_assert_hex32(qy, TE_UY())
	free(d)
	free(qx)
	free(qy)


# One RFC 6979 case: sign message `msg` and check r,s; then verify.
void te_rfc6979_case(char* msg, int msglen, char* want_r, char* want_s):
	char* d = malloc(32)
	te_hex32(TE_D(), d)
	char* hash = malloc(32)
	sha256(msg, msglen, hash)
	char* r = malloc(32)
	char* s = malloc(32)
	assert_equal(1, ecdsa_p256_sign(d, hash, 32, r, s))
	te_assert_hex32(r, want_r)
	te_assert_hex32(s, want_s)
	# Signature must verify against the public key.
	char* qx = malloc(32)
	char* qy = malloc(32)
	te_hex32(TE_UX(), qx)
	te_hex32(TE_UY(), qy)
	assert_equal(1, ecdsa_p256_verify(qx, qy, hash, 32, r, s))
	free(d)
	free(hash)
	free(r)
	free(s)
	free(qx)
	free(qy)


void test_rfc6979_sample():
	te_rfc6979_case(c"sample", 6, c"efd48b2aacb6a8fd1140dd9cd45e81d69d2c877b56aaf991c34d0ea84eaf3716", c"f7cb1c942d657c41d436c7a1b6e29f65f3e900dbb9aff4064dc4ab2f843acda8")


void test_rfc6979_test():
	te_rfc6979_case(c"test", 4, c"f1abb023518351cd71d881567b1ea663ed3efcf6c5132b354f28d3b0b7d38367", c"019f4113742a2b14bd25926b49c649155f267e60d3814b4c0cc84250e46f0083")


void test_verify_known_good():
	# Independent (OpenSSL-produced) P-256/SHA-256 signature over
	# "W native TLS: ECDSA verify vector".
	char* qx = malloc(32)
	char* qy = malloc(32)
	char* r = malloc(32)
	char* s = malloc(32)
	char* hash = malloc(32)
	te_hex32(c"40d771407fd6b5db1dfdbb553e5d3d44b3ae320ca81c87dfaa93573f8301ff08", qx)
	te_hex32(c"3830b0e8e9892dbc380c937f692eb18bcd0a6f7089fd934cd98ad6a858c4e382", qy)
	te_hex32(c"95906865d4541312663c3ef6b112812897d64db0126a08ee6a9f42d15ac780af", r)
	te_hex32(c"faddc9e8a4c9dcc6dba7200b20e4af7cb1dfc16d01926b829628d70142463708", s)
	te_hex32(c"bbef22ab000c814369cd3c8e27f6223503eb01f7f0ea0f23d179282648f66635", hash)
	assert_equal(1, ecdsa_p256_verify(qx, qy, hash, 32, r, s))

	# Negative: flip one bit of r -> must reject.
	r[31] = r[31] ^ 1
	assert_equal(0, ecdsa_p256_verify(qx, qy, hash, 32, r, s))
	r[31] = r[31] ^ 1
	# Negative: flip one bit of s -> must reject.
	s[0] = s[0] ^ 128
	assert_equal(0, ecdsa_p256_verify(qx, qy, hash, 32, r, s))
	s[0] = s[0] ^ 128
	# Negative: flip one bit of the message hash -> must reject.
	hash[10] = hash[10] ^ 4
	assert_equal(0, ecdsa_p256_verify(qx, qy, hash, 32, r, s))
	hash[10] = hash[10] ^ 4
	# Sanity: original still verifies after undoing the tampering.
	assert_equal(1, ecdsa_p256_verify(qx, qy, hash, 32, r, s))
	free(qx)
	free(qy)
	free(r)
	free(s)
	free(hash)


void test_sign_verify_roundtrip():
	# A different private key; sign an arbitrary digest and verify.
	char* d = malloc(32)
	te_hex32(c"00112233445566778899aabbccddeeff0123456789abcdef1122334455667788", d)
	char* qx = malloc(32)
	char* qy = malloc(32)
	assert_equal(1, ecdsa_p256_public_key(d, qx, qy))
	char* hash = malloc(32)
	sha256(c"the quick brown fox", 19, hash)
	char* r = malloc(32)
	char* s = malloc(32)
	assert_equal(1, ecdsa_p256_sign(d, hash, 32, r, s))
	assert_equal(1, ecdsa_p256_verify(qx, qy, hash, 32, r, s))

	# Determinism: signing again yields the identical (r, s).
	char* r2 = malloc(32)
	char* s2 = malloc(32)
	assert_equal(1, ecdsa_p256_sign(d, hash, 32, r2, s2))
	assert_equal(1, te_bytes_equal(r, r2, 32))
	assert_equal(1, te_bytes_equal(s, s2, 32))

	# Wrong public key must reject.
	char* wx = malloc(32)
	char* wy = malloc(32)
	te_hex32(TE_UX(), wx)
	te_hex32(TE_UY(), wy)
	assert_equal(0, ecdsa_p256_verify(wx, wy, hash, 32, r, s))
	free(d)
	free(qx)
	free(qy)
	free(hash)
	free(r)
	free(s)
	free(r2)
	free(s2)
	free(wx)
	free(wy)
