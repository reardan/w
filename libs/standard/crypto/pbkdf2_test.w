# wbuild: x64
/*
PBKDF2-HMAC against RFC 6070 (SHA-1, via libs/x/unsafe/sha1.w; the
16777216-iteration case is left out for speed), RFC 7914 §11
(PBKDF2-HMAC-SHA256, c = 1), and further SHA-256/384/512 vectors computed
with Python's hashlib.pbkdf2_hmac: long keys hashed first, empty password
and salt, multi-block and truncated outputs, a 100000-iteration run, and
the error/default-dklen behaviour of the name-based API.

No W_TEST_LEAKS step: under W_TEST_LEAKS=1 the only blocks reported are
the first-use global caches of lib/sha256.w, sha2.w and sha1.w (round
constants, IVs, the whash_register entry) in whichever test touches them
first (docs/testing.md "Limits"); every other test passes the check.
*/
import lib.testing
import lib.hex
import lib.mem
import libs.standard.crypto.sha2
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


char* pbt_repeat(int c, int n):
	char* s = cast(char*, malloc(n + 1))
	mem_fill(s, cast(char, c), n)
	s[n] = 0
	return s


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


void test_rfc7914_sha256():
	pbt_check(c"sha256", c"passwd", c"salt", 1, 64, c"55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783")


void test_sha256_vectors():
	pbt_check(c"sha256", c"password", c"salt", 1, 32, c"120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
	pbt_check(c"sha256", c"password", c"salt", 4096, 32, c"c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a")
	pbt_check(c"sha256", c"passwordPASSWORDpassword", c"saltSALTsaltSALTsaltSALTsaltSALTsalt", 4096, 40, c"348c89dbcbd32b2f32d814b8116e84cf2b17347ebc1800181c4e2a1fb8dd53e1c635518c7dac47e9")
	pbt_check(c"sha256", c"", c"salt", 10, 7, c"4c9d748ae0f904")
	pbt_check(c"SHA256", c"pw", c"s", 5, 0, c"64f396d803186a5ff2d9f30ed5cdacf0316c5d02b3e43b652bfd3c95113d4bb0")


void test_sha256_long_key_empty_salt():
	# 100-byte password exceeds the 64-byte block: HMAC hashes it first.
	char* pw = pbt_repeat(107, 100)
	pbt_check(c"sha256", pw, c"", 2, 32, c"c6240d6034800799638db95e360a5c988b1c16459b6ba73e6e7bcae79870d44d")
	free(pw)


void test_sha256_100k_iterations():
	pbt_check(c"sha256", c"password", c"salt", 100000, 32, c"0394a2ede332c9a13eb82e9b24631604c31df978b4e2f0fbd2c549944f9d79a5")


void test_sha512_and_sha384():
	pbt_check(c"sha512", c"password", c"salt", 1, 64, c"867f70cf1ade02cff3752599a3a53dc4af34c7a669815ae5d513554e1c8cf252c02d470a285a0501bad999bfe943c08f050235d7d68b1da55e63f73b60a57fce")
	pbt_check(c"sha512", c"password", c"salt", 1000, 0, c"afe6c5530785b6cc6b1c6453384731bd5ee432ee549fd42fb6695779ad8a1c5bf59de69c48f774efc4007d5298f9033c0241d5ab69305e7b64eceeb8d834cfec")
	pbt_check(c"sha384", c"password", c"salt", 1000, 0, c"3bd37e2236941d4a77b1b5b714c6f913fabb6b0841a6d7d8656b99d611e900fe06edb93b5b809efaa9678b635ce513e0")


void test_sha512_long_key_multiblock():
	# 200-byte key (> 128-byte block), 130-byte output = 3 blocks, last truncated.
	char* pw = pbt_repeat(107, 200)
	pbt_check(c"sha512", pw, c"NaCl", 3, 130, c"459d67075b280a0e3ea741869225c39f8c4ddab81df42747c773d450329d54b259e1d6cc5eb86a3f343597f414a30856ec0df0205093d25249acb78cce096f159729677e6d6b78acf6bf7729c911c05abdb1624a6a004596f4a411ae20b6cfc9654655c3ca03449f673b65f11489a7acba0fd7aaf4302e760fa3ebe31d1585745b02")
	free(pw)


void test_raw_bytes_api():
	char* dk = pbkdf2_hmac(c"sha256", c"password", 8, c"salt", 4, 1, 0)
	assert1(dk != 0)
	char* got = hex_encode(dk, 32)
	assert_strings_equal(c"120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b", got)
	free(got)
	free(dk)


void test_errors():
	assert_equal(0, pbkdf2_hash_id(c"md5"))
	assert_equal(0, pbkdf2_hash_id(c"sha2560"))
	assert_equal(0, pbkdf2_hash_id(c"sha"))
	assert_equal(0, pbkdf2_hash_id(cast(char*, 0)))
	assert_equal(WHASH_SHA512, pbkdf2_hash_id(c"Sha512"))
	assert1(pbkdf2_hmac(c"md5", c"pw", 2, c"s", 1, 1, 16) == 0)
	assert1(pbkdf2_hmac(c"sha256", c"pw", 2, c"s", 1, 0, 16) == 0)
	assert1(pbkdf2_hmac(c"sha256", c"pw", 2, c"s", 1, 1, -1) == 0)
	assert1(pbkdf2_hmac_hex(c"nope", c"pw", 2, c"s", 1, 1, 0) == 0)
	assert1(pbkdf2_hmac_hex(c"sha256", c"pw", 2, c"s", 1, -5, 0) == 0)
	char* out = cast(char*, malloc(4))
	assert_equal(0, pbkdf2_hmac_into(WHASH_SHA256, c"pw", 2, c"s", 1, 1, out, 0))
	assert_equal(0, pbkdf2_hmac_into(WHASH_SHA256, c"pw", -1, c"s", 1, 1, out, 4))
	free(out)
