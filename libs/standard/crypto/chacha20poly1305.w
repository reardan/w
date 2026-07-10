/*
ChaCha20-Poly1305 AEAD (RFC 8439 section 2.8), pure W.

Part of the native HTTPS stack (issue #155, plan
libs/standard/plans/11_native_http_tls.md phase 4). This is the single
mandatory TLS 1.3 cipher suite of that plan
(TLS_CHACHA20_POLY1305_SHA256).

Construction: the one-time Poly1305 key is the first 32 bytes of the
ChaCha20 block with counter 0 (section 2.6); the plaintext is encrypted
with counter 1; the tag authenticates
aad || pad16 || ciphertext || pad16 || le64(aad_len) || le64(ct_len).

chacha20poly1305_open verifies the tag with a constant-time comparison
BEFORE any decryption: on mismatch it fails closed and writes nothing to
the plaintext buffer.
*/
import lib.memory
import libs.standard.crypto.chacha20
import libs.standard.crypto.poly1305


# Derive the one-time Poly1305 key for (key, nonce): the first 32 bytes of
# the ChaCha20 block with counter 0 (RFC 8439 section 2.6).
void poly1305_key_gen(char* key, char* nonce, char* out):
	char* block = malloc(64)
	chacha20_block(key, 0, nonce, block)
	int i = 0
	while (i < 32):
		out[i] = block[i] & 255
		i = i + 1
	i = 0
	while (i < 64):
		block[i] = 0
		i = i + 1
	free(block)


# Constant-time 16-byte tag comparison: accumulate the OR of byte
# differences, test once at the end. Returns 1 when equal.
int chacha20poly1305_tag_equal(char* a, char* b):
	int diff = 0
	int i = 0
	while (i < 16):
		diff = diff | ((a[i] ^ b[i]) & 255)
		i = i + 1
	return diff == 0


# Tag over the AEAD MAC input (RFC 8439 section 2.8): aad and ciphertext
# each zero-padded to a 16-byte boundary, then both lengths as 64-bit
# little-endian values. Lengths are non-negative ints (< 2^31), so the
# upper four bytes of each length field are zero.
void chacha20poly1305_mac(char* polykey, char* aad, int aad_len, char* ct, int ct_len, char* out):
	poly1305* st = poly1305_new(polykey)
	char* zeros = malloc(16)
	int i = 0
	while (i < 16):
		zeros[i] = 0
		i = i + 1

	poly1305_update(st, aad, aad_len)
	int rem = aad_len % 16
	if (rem != 0):
		poly1305_update(st, zeros, 16 - rem)
	poly1305_update(st, ct, ct_len)
	rem = ct_len % 16
	if (rem != 0):
		poly1305_update(st, zeros, 16 - rem)

	char* lens = malloc(16)
	i = 0
	while (i < 16):
		lens[i] = 0
		i = i + 1
	lens[0] = aad_len & 255
	lens[1] = (aad_len >> 8) & 255
	lens[2] = (aad_len >> 16) & 255
	lens[3] = (aad_len >> 24) & 255
	lens[8] = ct_len & 255
	lens[9] = (ct_len >> 8) & 255
	lens[10] = (ct_len >> 16) & 255
	lens[11] = (ct_len >> 24) & 255
	poly1305_update(st, lens, 16)
	poly1305_finish(st, out)
	poly1305_free(st)
	free(lens)
	free(zeros)


# Seal: encrypt `len` plaintext bytes into `ct_out` and write the 16-byte
# tag to `tag_out`. key is 32 bytes, nonce 12 bytes; the nonce MUST be
# unique per invocation with the same key.
void chacha20poly1305_seal(char* key, char* nonce, char* aad, int aad_len, char* plain, int len, char* ct_out, char* tag_out):
	char* polykey = malloc(32)
	poly1305_key_gen(key, nonce, polykey)
	chacha20_xor(key, 1, nonce, plain, len, ct_out)
	chacha20poly1305_mac(polykey, aad, aad_len, ct_out, len, tag_out)
	int i = 0
	while (i < 32):
		polykey[i] = 0
		i = i + 1
	free(polykey)


# Open: verify the 16-byte tag over (aad, ct), then decrypt `len` bytes
# into `plain_out`. Returns 1 on success. On tag mismatch it returns 0
# WITHOUT touching `plain_out` -- no plaintext is ever released for a
# forged message. The comparison is constant time.
int chacha20poly1305_open(char* key, char* nonce, char* aad, int aad_len, char* ct, int len, char* tag, char* plain_out):
	char* polykey = malloc(32)
	char* expected = malloc(16)
	poly1305_key_gen(key, nonce, polykey)
	chacha20poly1305_mac(polykey, aad, aad_len, ct, len, expected)
	int ok = chacha20poly1305_tag_equal(expected, tag)
	int i = 0
	while (i < 16):
		expected[i] = 0
		i = i + 1
	free(expected)
	if (ok == 0):
		i = 0
		while (i < 32):
			polykey[i] = 0
			i = i + 1
		free(polykey)
		return 0
	chacha20_xor(key, 1, nonce, ct, len, plain_out)
	i = 0
	while (i < 32):
		polykey[i] = 0
		i = i + 1
	free(polykey)
	return 1
