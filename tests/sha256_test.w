import lib.lib
import lib.assert
import lib.sha256


# Format a 32-byte digest as a 64-char lowercase hex string (malloc'd).
char* sha256_hex(char* digest):
	char* out = malloc(65)
	char* digits = c"0123456789abcdef"
	int i = 0
	while (i < 32):
		int b = digest[i] & 255
		out[i * 2] = digits[(b >> 4) & 15]
		out[i * 2 + 1] = digits[b & 15]
		i = i + 1
	out[64] = 0
	return out


char* hash_hex(char* data, int len):
	char* digest = malloc(32)
	sha256(data, len, digest)
	return sha256_hex(digest)


int main(int argc, int argv):
	# Empty string.
	assert_strings_equal(c"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", hash_hex(c"", 0))

	# "abc" — the canonical single-block vector.
	assert_strings_equal(c"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", hash_hex(c"abc", 3))

	# 56 bytes: forces a second padding block (no room for the length after
	# the 0x80 terminator in the first).
	assert_strings_equal(c"248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1", hash_hex(c"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", 56))

	# A full 64-byte block of 'a', then one more to cross a block boundary.
	assert_strings_equal(c"f506898cc7c2e092f9eb9fadae7ba50383f5b46a2a4fe5597dbb553a78981268", hash_hex(c"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 62))

	# 1,000,000 'a' repeated — the classic long-message NIST vector.
	int n = 1000000
	char* big = malloc(n)
	int i = 0
	while (i < n):
		big[i] = 'a'
		i = i + 1
	assert_strings_equal(c"cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0", hash_hex(big, n))

	println(c"sha256: all vectors passed")
	return 0
