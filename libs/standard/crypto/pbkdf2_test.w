# wbuild: x64
/*
PBKDF2-HMAC against RFC 7914 §11 (PBKDF2-HMAC-SHA256, c = 1) and further SHA-256/384/512 vectors computed
with Python's hashlib.pbkdf2_hmac: long keys hashed first, empty password
and salt, multi-block and truncated outputs, a 100000-iteration run, and
the error/default-dklen behaviour of the name-based API. The SHA-1 (RFC
6070) and MD5 cases need libs/x/unsafe, which libs/standard tests may not
import (unsafe_import_test); they live in libs/x/unsafe/pbkdf2_sha1_test.w.

No W_TEST_LEAKS step: under W_TEST_LEAKS=1 the only blocks reported are
the first-use global caches of lib/sha256.w and sha2.w (round
constants, IVs, the whash_register entry) in whichever test touches them
first (docs/testing.md "Limits"); every other test passes the check.
*/
import lib.testing
import lib.hex
import lib.mem
import libs.standard.crypto.sha2
import libs.standard.crypto.pbkdf2


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
