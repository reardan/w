# wbuild: x64
/*
PBKDF2-HMAC over the digests this quarantine namespace provides:
RFC 6070 (SHA-1; the 16777216-iteration case is left out for speed) and
MD5 as a little-endian whash extension. libs/standard/crypto/pbkdf2.w may
not import libs/x/unsafe (unsafe_import_test); it reaches SHA-1 and MD5
through the whash registry once this program imports them, the seam
websocket_sha1_test.w and uuid_names_test.w use.
*/
import lib.testing
import lib.hex
import libs.standard.crypto.pbkdf2
import libs.x.unsafe.sha1
import libs.x.unsafe.md5


int pbt_len(char* s):
	int n = 0
	while (s[n] != 0): n = n + 1
	return n


# pbkdf2_hmac_hex over C-string password/salt, checked against want.
void pbt_check(char* name, char* password, char* salt, int iterations, int dklen, char* want):
	char* got = pbkdf2_hmac_hex(name, password, pbt_len(password), salt, pbt_len(salt), iterations, dklen)
	assert1(got != 0)
	assert_strings_equal(want, got)
	free(got)


void test_rfc6070_sha1():
	int alg = WHASH_SHA1()
	pbt_check(c"sha1", c"password", c"salt", 1, 20, c"0c60c80f961f0e71f3a9b524af6012062fe037a6")
	pbt_check(c"sha1", c"password", c"salt", 2, 20, c"ea6c014dc72d6f8ccd1ed92ace1d41f0d8de8957")
	pbt_check(c"sha1", c"password", c"salt", 4096, 20, c"4b007901b765489abead49d926f721d065a429c1")
	pbt_check(c"SHA1", c"passwordPASSWORDpassword", c"saltSALTsaltSALTsaltSALTsaltSALTsalt", 4096, 25, c"3d2eec4fe41c849b80c8d83662c0e44a8b291a964cf2f07038")
	# "pass\0word" / "sa\0lt": embedded NULs through the by-id API.
	char* pw = hex_bytes(c"7061737300776f7264")
	char* salt = hex_bytes(c"7361006c74")
	char* out = cast(char*, malloc(16))
	assert_equal(1, pbkdf2_hmac_into(alg, pw, 9, salt, 5, 4096, out, 16))
	char* got = hex_encode(out, 16)
	assert_strings_equal(c"56fa6aa75548099dcc37d7f03425e0c3", got)
	free(got)
	free(out)
	free(salt)
	free(pw)


# MD5 is a little-endian whash extension: covers the LE padding and
# digest byte order of the pre-padded fast path.
void test_md5_extension_by_id():
	char* out = cast(char*, malloc(40))
	assert_equal(1, pbkdf2_hmac_into(WHASH_MD5(), c"password", 8, c"salt", 4, 1000, out, 40))
	char* got = hex_encode(out, 40)
	assert_strings_equal(c"8d189946a32d883622a16ae18af0632f5791d5e7b1abb0ab1757d28ce34056140335105994495f91", got)
	free(got)
	free(out)
	# Names stay limited to SHA-1/SHA-2: md5 is reachable only by id.
	assert_equal(0, pbkdf2_hash_id(c"md5"))
