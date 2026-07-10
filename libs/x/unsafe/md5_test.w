# wbuild: x64
/*
MD5 (libs/x/unsafe/md5.w) against the full RFC 1321 A.5 test suite (all
seven strings), block-boundary lengths straddling the 64-byte block and
8-byte length field (cross-checked against Python's hashlib), streaming
vs one-shot equivalence, reset/clone reuse, and HMAC-MD5 composition
through libs/standard/crypto/hmac.w with RFC 2202 vectors — the
integration proof that the whash extension registry works. Issue #209.
*/
import lib.testing
import lib.memory
import libs.standard.crypto.sha2
import libs.standard.crypto.hmac
import libs.x.unsafe.md5


# Format len digest bytes as a lowercase hex string (malloc'd).
char* md5t_hex(char* digest, int len):
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


int md5t_nibble(int c):
	if ((c >= '0') && (c <= '9')):
		return c - '0'
	return c - 'a' + 10


# Decode a lowercase hex string into malloc'd bytes (strlen(hex)/2 long).
char* md5t_unhex(char* hex):
	int n = strlen(hex) / 2
	char* out = malloc(n + 1)
	int i = 0
	while (i < n):
		out[i] = (md5t_nibble(hex[i * 2] & 255) << 4) | md5t_nibble(hex[i * 2 + 1] & 255)
		i = i + 1
	out[n] = 0
	return out


void md5t_check(char* data, int len, char* want_hex):
	char* digest = malloc(16)
	md5(data, len, digest)
	char* got = md5t_hex(digest, 16)
	assert_strings_equal(want_hex, got)
	free(got)
	free(digest)


void test_md5_rfc1321_suite():
	# RFC 1321 A.5, all seven strings.
	md5t_check(c"", 0, c"d41d8cd98f00b204e9800998ecf8427e")
	md5t_check(c"a", 1, c"0cc175b9c0f1b6a831c399e269772661")
	md5t_check(c"abc", 3, c"900150983cd24fb0d6963f7d28e17f72")
	md5t_check(c"message digest", 14, c"f96b697d7cb7938d525a2f31aaf161d0")
	md5t_check(c"abcdefghijklmnopqrstuvwxyz", 26, c"c3fcd3d76192e4007dfb496cca67e13b")
	md5t_check(c"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789", 62, c"d174ab98d277d9f5a5611c2c9f419d9f")
	md5t_check(c"12345678901234567890123456789012345678901234567890123456789012345678901234567890", 80, c"57edf4a22be3c955ac49da2e2107b67a")


void test_md5_block_boundaries():
	# 55/56/63/64/65 'a's straddle the 0x80 terminator, the 8-byte length
	# field, and the 64-byte block edge (checked against hashlib).
	char* a65 = malloc(65)
	int i = 0
	while (i < 65):
		a65[i] = 'a'
		i = i + 1
	md5t_check(a65, 55, c"ef1772b6dff9a122358552954ad0df65")
	md5t_check(a65, 56, c"3b0c8ac703f828b04c6c197006d17218")
	md5t_check(a65, 63, c"b06521f39153d618550606be297466d5")
	md5t_check(a65, 64, c"014842d480b571495a4a0363793f7367")
	md5t_check(a65, 65, c"c743a45e0d2e6a95cb859adae0248435")
	free(a65)


void test_md5_whash_geometry():
	assert_equal(16, whash_digest_size(WHASH_MD5()))
	assert_equal(64, whash_block_size(WHASH_MD5()))
	assert_equal(4, whash_state_words(WHASH_MD5()))


# Feeding input in ragged slices must match the one-shot digest.
void md5t_check_streaming(char* data, int len, int step):
	whash* h = whash_new(WHASH_MD5())
	int pos = 0
	while (pos < len):
		int take = step
		if (pos + take > len):
			take = len - pos
		whash_update(h, data + pos, take)
		pos = pos + take
	char* digest = malloc(16)
	whash_final(h, digest)
	char* got = md5t_hex(digest, 16)
	char* oneshot = malloc(16)
	md5(data, len, oneshot)
	char* want = md5t_hex(oneshot, 16)
	assert_strings_equal(want, got)
	free(want)
	free(oneshot)
	free(got)
	free(digest)
	whash_free(h)


void test_md5_streaming_matches_oneshot():
	char* msg = c"12345678901234567890123456789012345678901234567890123456789012345678901234567890"
	md5t_check_streaming(msg, 80, 1)
	md5t_check_streaming(msg, 80, 7)
	md5t_check_streaming(msg, 80, 64)


void test_md5_reset_and_clone():
	# Reset rewinds to the empty message; a clone diverges independently.
	whash* h = whash_new(WHASH_MD5())
	whash_update(h, c"abc", 3)
	whash* c = whash_clone(h)
	whash_update(c, c"defghijklmnopqrstuvwxyz", 23)
	char* digest = malloc(16)
	whash_final(c, digest)
	char* got = md5t_hex(digest, 16)
	assert_strings_equal(c"c3fcd3d76192e4007dfb496cca67e13b", got)
	free(got)
	whash_free(c)
	# The original still holds only "abc"; final is non-destructive.
	whash_final(h, digest)
	got = md5t_hex(digest, 16)
	assert_strings_equal(c"900150983cd24fb0d6963f7d28e17f72", got)
	free(got)
	whash_reset(h)
	whash_update(h, c"a", 1)
	whash_final(h, digest)
	got = md5t_hex(digest, 16)
	assert_strings_equal(c"0cc175b9c0f1b6a831c399e269772661", got)
	free(got)
	free(digest)
	whash_free(h)


void md5t_check_hmac(char* key, int key_len, char* data, int data_len, char* want_hex):
	char* mac = malloc(16)
	hmac_compute(WHASH_MD5(), key, key_len, data, data_len, mac)
	char* got = md5t_hex(mac, 16)
	assert_strings_equal(want_hex, got)
	free(got)
	free(mac)


void test_hmac_md5_rfc2202():
	# RFC 2202 section 2 cases 1-3 and 6; case 6's 80-byte key exercises
	# the hash-the-key path through whash_oneshot.
	char* key1 = md5t_unhex(c"0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b")
	md5t_check_hmac(key1, 16, c"Hi There", 8, c"9294727a3638bb1c13f48ef8158bfc9d")
	free(key1)
	md5t_check_hmac(c"Jefe", 4, c"what do ya want for nothing?", 28, c"750c783e6ab0b503eaa86e310a5db738")
	char* key3 = md5t_unhex(c"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
	char* data3 = malloc(50)
	int i = 0
	while (i < 50):
		data3[i] = 221 /* 0xdd */
		i = i + 1
	md5t_check_hmac(key3, 16, data3, 50, c"56be34521d144c88dbb8c733f0e8b3f6")
	free(data3)
	free(key3)
	char* key6 = malloc(80)
	i = 0
	while (i < 80):
		key6[i] = 170 /* 0xaa */
		i = i + 1
	md5t_check_hmac(key6, 80, c"Test Using Larger Than Block-Size Key - Hash Key First", 54, c"6b1ab7fe4bd7bf8f0b62e6ce61b9d0cd")
	free(key6)
