# wbuild: x64
/*
X25519 tests: RFC 7748 section 5.2 vectors (both), the section 5.2
iterated test (1 iteration always; the 1,000-iteration variant only when
invoked with --iterated-1000, wired as the separate x25519_iterated_test
build target so the fast targets stay fast), the section 6.1 Diffie-
Hellman exchange, and low-order point rejection (all-zero output).
*/
import lib.lib
import lib.assert
import libs.standard.crypto.x25519


int x25519_test_nibble(int ch):
	if ((ch >= '0') & (ch <= '9')):
		return ch - '0'
	return ch - 'a' + 10


# Decode 2*len lowercase hex chars into len bytes at out.
void x25519_test_unhex(char* hex, char* out, int len):
	int i = 0
	while (i < len):
		int hi = x25519_test_nibble(hex[i * 2] & 255)
		int lo = x25519_test_nibble(hex[i * 2 + 1] & 255)
		out[i] = (hi << 4) | lo
		i = i + 1


# Format 32 bytes as a 64-char lowercase hex string (malloc'd).
char* x25519_test_hex32(char* data):
	char* out = malloc(65)
	char* digits = c"0123456789abcdef"
	int i = 0
	while (i < 32):
		int b = data[i] & 255
		out[i * 2] = digits[(b >> 4) & 15]
		out[i * 2 + 1] = digits[b & 15]
		i = i + 1
	out[64] = 0
	return out


void x25519_test_check32(char* want_hex, char* got):
	char* got_hex = x25519_test_hex32(got)
	assert_strings_equal(want_hex, got_hex)
	free(got_hex)


# RFC 7748 section 5.2, first test vector.
void test_rfc7748_vector1():
	char* k = malloc(32)
	char* u = malloc(32)
	char* r = malloc(32)
	x25519_test_unhex(c"a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4", k, 32)
	x25519_test_unhex(c"e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c", u, 32)
	assert_equal(0, x25519_scalarmult(r, k, u))
	x25519_test_check32(c"c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552", r)
	free(k)
	free(u)
	free(r)


# RFC 7748 section 5.2, second test vector.
void test_rfc7748_vector2():
	char* k = malloc(32)
	char* u = malloc(32)
	char* r = malloc(32)
	x25519_test_unhex(c"4b66e9d4d1b4673c5ad22691957d6af5c11b6421e0ea01d42ca4169e7918ba0d", k, 32)
	x25519_test_unhex(c"e5210f12786811d3f4b7959d0538ae2c31dbe7106fc03c3efc4cd549c715a493", u, 32)
	assert_equal(0, x25519_scalarmult(r, k, u))
	x25519_test_check32(c"95cbde9476e8907d7aade45cb4b873f88b595a68799fa152e6f8f7647aac7957", r)
	free(k)
	free(u)
	free(r)


# RFC 7748 section 5.2 iterated test: start with k = u = the base point
# encoding, then repeatedly (k, u) <- (X25519(k, u), k).
void test_iterated(int iterations, char* want_hex):
	char* k = malloc(32)
	char* u = malloc(32)
	char* r = malloc(32)
	x25519_test_unhex(c"0900000000000000000000000000000000000000000000000000000000000000", k, 32)
	x25519_test_unhex(c"0900000000000000000000000000000000000000000000000000000000000000", u, 32)
	int i = 0
	while (i < iterations):
		assert_equal(0, x25519_scalarmult(r, k, u))
		int j = 0
		while (j < 32):
			u[j] = k[j]
			k[j] = r[j]
			j = j + 1
		i = i + 1
	x25519_test_check32(want_hex, k)
	free(k)
	free(u)
	free(r)


# RFC 7748 section 6.1: Alice/Bob public keys from the base point and the
# shared secret from both sides.
void test_dh_rfc7748():
	char* alice_priv = malloc(32)
	char* bob_priv = malloc(32)
	char* alice_pub = malloc(32)
	char* bob_pub = malloc(32)
	char* shared_a = malloc(32)
	char* shared_b = malloc(32)
	x25519_test_unhex(c"77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a", alice_priv, 32)
	x25519_test_unhex(c"5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb", bob_priv, 32)

	assert_equal(0, x25519_scalarmult_base(alice_pub, alice_priv))
	x25519_test_check32(c"8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a", alice_pub)
	assert_equal(0, x25519_scalarmult_base(bob_pub, bob_priv))
	x25519_test_check32(c"de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f", bob_pub)

	assert_equal(0, x25519_scalarmult(shared_a, alice_priv, bob_pub))
	assert_equal(0, x25519_scalarmult(shared_b, bob_priv, alice_pub))
	x25519_test_check32(c"4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742", shared_a)
	x25519_test_check32(c"4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742", shared_b)

	free(alice_priv)
	free(bob_priv)
	free(alice_pub)
	free(bob_pub)
	free(shared_a)
	free(shared_b)


# The all-zero u-coordinate is a low-order point: X25519 with it yields
# the all-zero shared secret, which x25519_scalarmult must reject.
void test_low_order_rejection():
	char* k = malloc(32)
	char* u = malloc(32)
	char* r = malloc(32)
	x25519_test_unhex(c"77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a", k, 32)
	int i = 0
	while (i < 32):
		u[i] = 0
		i = i + 1
	assert_equal(0 - 1, x25519_scalarmult(r, k, u))
	i = 0
	while (i < 32):
		assert_equal(0, r[i] & 255)
		i = i + 1
	free(k)
	free(u)
	free(r)


void test_clamp():
	char* k = malloc(32)
	int i = 0
	while (i < 32):
		k[i] = 255
		i = i + 1
	x25519_clamp(k)
	assert_equal(248, k[0] & 255)
	assert_equal(127, k[31] & 255)
	i = 1
	while (i < 31):
		assert_equal(255, k[i] & 255)
		i = i + 1
	free(k)


int main(int argc, int argv):
	test_rfc7748_vector1()
	test_rfc7748_vector2()
	test_iterated(1, c"422c8e7a6227d7bca1350b3e2bb7279f7897b87bb6854b783c60e80311ae3079")
	test_dh_rfc7748()
	test_low_order_rejection()
	test_clamp()
	if (argc > 1):
		char** arg = argv + __word_size__
		if (strcmp(*arg, c"--iterated-1000") == 0):
			test_iterated(1000, c"684cf59ba83309552800ef566f2f4d3c1c3887c49360e3875f2eb94d99532c51")
			println(c"x25519: 1000-iteration vector passed")
	println(c"x25519: all vectors passed")
	return 0
