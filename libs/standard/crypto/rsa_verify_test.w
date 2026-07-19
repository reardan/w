# Tests for libs/standard/crypto/rsa_verify.w.
#
# Vectors are an RSA-2048 key with OpenSSL-produced signatures (via the genvec
# harness) over "W native TLS: RSA verify vector":
#   - PKCS#1 v1.5 with SHA-256 and SHA-384
#   - PSS with SHA-256 (MGF1-SHA256, salt length 32)
#   - PSS with SHA-384 (MGF1-SHA384, salt length 48; a second OpenSSL-minted
#     RSA-2048 key, added with the x509 packet, issue #199)
# Plus negatives: bit-flipped signatures, a tampered digest, and a v1.5
# signature checked against the wrong DigestInfo (SHA-384).
import lib.testing
import lib.sha256
import libs.standard.crypto.rsa_verify


int tr_hexval(int c):
	if ((c >= '0') && (c <= '9')):
		return c - '0'
	if ((c >= 'a') && (c <= 'f')):
		return c - 'a' + 10
	if ((c >= 'A') && (c <= 'F')):
		return c - 'A' + 10
	return 0


# Decode an even-length big-endian hex string; returns the byte length.
int tr_hex(char* h, char* out):
	int l = strlen(h)
	int i = 0
	while (i < l / 2):
		out[i] = (tr_hexval(h[i * 2]) << 4) | tr_hexval(h[i * 2 + 1])
		i = i + 1
	return l / 2


char* TR_N():
	return c"b3230cf9ea2e50361634b44db7213283deac2a6c008a48fef704885726aa7b8be120f9f863c8a7d9f78e2ca2ae31c7297a9b23e9adab7c5c05c298a037fac4876b4bd6e86aeaed63abac9d8303437282c9a87216e7fa78a90176d3cdf4bc2b9ce03266afd0e0357911737f01518d9d4741c4b59d9321f0a12fc4519f8b5283ce7837f88928c4a54ced249d278720c31c3384528e5f632b92246b494785ffed92fb4ab116551747889b7ea099b27af9437048bfe5216ee755ba8b227bb7d185157bdef395a129a7d5fd69fa4066dd063a0e80a65b58c9d27b9f9b83d2974b0f130d84d6e3bb9de4315219be1258e5c79b7c127d241ea90488db17a4196b1858e1"


char* TR_E():
	return c"010001"


char* TR_SHA256():
	return c"d859acb9fad835d884baeee12c4df47fef72a0135b3846748db7de72c93555ad"


char* TR_SHA384():
	return c"6200d7f5cc777d217b8994a507988818f38fa19c85b34b5758087b0d225286675f249f74fbda49fc0df6da2029f2187f"


char* TR_SIG_V15_256():
	return c"9316d7961411e6fb6752b6b9140646e0af835a25fb0050d64b8516e02c0e896e9dd15683f51d1666e5d564c02c0fd34230878b02a3f2ebdd4a93a4d0f1bc8ebe715bd19bbf2454c4e39f4edc88ac0757416059cf99bcbbc397a6d4fdf89fe0c013ee89617080fcde5a33011bcabca25bf972d791ee56e32f50c92f4614d637280764dc822117b3814a66938940553ff5a009f49d9b30db386c7fe963672b4f9261c66c1af6365e85f0342e524cb0c4745a003f073411bf05b0c7599c389f494ca02042711f5bbe80ba41d25efcb21b85b133e9ddc23cbff5c9fbca320f07c59cb113612c590cd39b415047caa1635224bef0a87022504c8c37e4660b7e4ec8d0"


char* TR_SIG_V15_384():
	return c"614ae36f18879274f5e6d97c94945a2403505418897d26eead25c14fecba7176ce8edc4ec1a9cc1f93d835b1c276a558394108d89022cdfb8cbda29d98bd8c25e8aee841a5df5d1cc218bf24e98e9ce387cf995c0b1fdb213885e41ebfab125bea228732c0c35397a2f3ca638060a34f42ae531a5b5eedf13679d7b1f44a1d63261bcf5aef6ddb0e262f3964e538543623645fa325c29f9b85e6691154219e153db66efa78d7f5615d1f71d38dec8486093a97b64f9f8ae9e54beeca76c3149d189583b4d2e11fbbea83b444484e2ff8d9cf7b893b9addcade4a1b4ac90b537d7c0cf7ee1d4d46ed2398bfcfe9859980380a2adb10101819bcbf8d646ba1a12a"


char* TR_SIG_PSS_256():
	return c"866501efdad94a7a1848be8f106580735fa050abe1ed369202428906b797f66d48b663ab0dbfe5fdadac4e209a3bcca2580b72d9d8e8793e12772af5d7c9271f6a91de2aad4c7f8d8b5a0977b3739309127b196a845c9563826bb81e44f09201a98edcb4670a3de4d7cd60e815109f0b6e7f91e444deacf9d0aa9775143ce67e8ba3691b42cfb11f239c49637649bd5f4bec2cc2fdc3015a9f1a79c1c816afc013287c0ad7a319ec4d8af3cd1a900cdbc364ea84f546513fda3c7cc335276216afaffdda748c00638e6e0ab432f06c4a094ae413a6195e0eeba6d48ad3d18c4050a55acfa6ce2e5f83ba4ce2de71490e77b9bc74c549c2344961b6ac3ce2485e"


int tr_n(char* out):
	return tr_hex(TR_N(), out)


int tr_e(char* out):
	return tr_hex(TR_E(), out)


void test_pkcs1v15_sha256_valid():
	char* n = malloc(300)
	char* e = malloc(8)
	char* sig = malloc(300)
	char* dig = malloc(48)
	int nlen = tr_n(n)
	int elen = tr_e(e)
	int slen = tr_hex(TR_SIG_V15_256(), sig)
	tr_hex(TR_SHA256(), dig)
	assert_equal(1, rsa_pkcs1v15_verify_sha256(n, nlen, e, elen, sig, slen, dig))

	# Negative: flip one signature bit.
	sig[100] = sig[100] ^ 8
	assert_equal(0, rsa_pkcs1v15_verify_sha256(n, nlen, e, elen, sig, slen, dig))
	sig[100] = sig[100] ^ 8
	# Negative: tamper the digest.
	dig[0] = dig[0] ^ 1
	assert_equal(0, rsa_pkcs1v15_verify_sha256(n, nlen, e, elen, sig, slen, dig))
	dig[0] = dig[0] ^ 1
	# Negative: valid v1.5/SHA-256 signature must fail under the SHA-384
	# DigestInfo (strict prefix/length match).
	char* dig384 = malloc(48)
	tr_hex(TR_SHA384(), dig384)
	assert_equal(0, rsa_pkcs1v15_verify_sha384(n, nlen, e, elen, sig, slen, dig384))
	free(n)
	free(e)
	free(sig)
	free(dig)
	free(dig384)


void test_pkcs1v15_sha384_valid():
	char* n = malloc(300)
	char* e = malloc(8)
	char* sig = malloc(300)
	char* dig = malloc(48)
	int nlen = tr_n(n)
	int elen = tr_e(e)
	int slen = tr_hex(TR_SIG_V15_384(), sig)
	tr_hex(TR_SHA384(), dig)
	assert_equal(1, rsa_pkcs1v15_verify_sha384(n, nlen, e, elen, sig, slen, dig))
	# Negative: flip a signature bit.
	sig[0] = sig[0] ^ 128
	assert_equal(0, rsa_pkcs1v15_verify_sha384(n, nlen, e, elen, sig, slen, dig))
	free(n)
	free(e)
	free(sig)
	free(dig)


void test_pkcs1v15_sha256_matches_computed_hash():
	# The embedded SHA-256 digest must equal SHA-256 of the message, i.e. the
	# signature verifies against a locally recomputed digest too.
	char* n = malloc(300)
	char* e = malloc(8)
	char* sig = malloc(300)
	int nlen = tr_n(n)
	int elen = tr_e(e)
	int slen = tr_hex(TR_SIG_V15_256(), sig)
	char* dig = malloc(32)
	sha256(c"W native TLS: RSA verify vector", 31, dig)
	assert_equal(1, rsa_pkcs1v15_verify_sha256(n, nlen, e, elen, sig, slen, dig))
	free(n)
	free(e)
	free(sig)
	free(dig)


void test_pss_sha256_valid():
	char* n = malloc(300)
	char* e = malloc(8)
	char* sig = malloc(300)
	char* dig = malloc(48)
	int nlen = tr_n(n)
	int elen = tr_e(e)
	int slen = tr_hex(TR_SIG_PSS_256(), sig)
	tr_hex(TR_SHA256(), dig)
	assert_equal(1, rsa_pss_verify_sha256(n, nlen, e, elen, sig, slen, dig))

	# Negative: flip one signature bit.
	sig[200] = sig[200] ^ 2
	assert_equal(0, rsa_pss_verify_sha256(n, nlen, e, elen, sig, slen, dig))
	sig[200] = sig[200] ^ 2
	# Negative: tamper the message hash.
	dig[31] = dig[31] ^ 64
	assert_equal(0, rsa_pss_verify_sha256(n, nlen, e, elen, sig, slen, dig))
	dig[31] = dig[31] ^ 64
	# Negative: a PKCS#1 v1.5 signature must not verify as PSS.
	int v15len = tr_hex(TR_SIG_V15_256(), sig)
	assert_equal(0, rsa_pss_verify_sha256(n, nlen, e, elen, sig, v15len, dig))
	free(n)
	free(e)
	free(sig)
	free(dig)


# A different RSA-2048 key used only for the PSS/SHA-384 vector.
char* TR_N_384():
	return c"b54d7b12ef124e34ba4221a987c56cf7cd0150878319a5722fca3cc071b3a46ebf57fc1431f3f9d49255af334504d8fe65c0fdafb0156af4994943bda82f617b31819e2b3f65c0cada6c1500750be90e4efac5cc286fa6c09360a32df020efdd899da3f9f8fa4404c389d7f363ac67668b29b0b32d8632d6ae1cb1b36149f3491871d2f45d1f3c693c8fbdd934ffcc81babac34099a7f22cc00e613765ba5d351b2338ce3d660656714a6d8ebb5013c5757a295051945ac596fe79255ea445f04a111d357e4d48587ca168abc84188815d77db36a456a5ac37a00452afe0e8ecfada412d81f4075e1ed403dab1e5942886575989be515e23a97218150649d303"


char* TR_SIG_PSS_384():
	return c"00cfa9ae12961bd072429ed0de7d180d65a857330a4590847d5aafe56e7c5b85f1fbf5fd1a0940a77bf11dc03236fd794704f455f8385ca15b15f72b3a1986b176e4a4bec96733dbdc6cf08cbf2a549d204e0af9f826551c380cfdb417630dbdea0cbee8727f389205b3cbfa3bcea2e317d6d774c4c64ef76c5d4a8c0b025fac316c6aff17e428e206c7cc362648a1a23e6ef4bb24492c1096f55b355bd452d2ef7b5331e512ac9a9433976b56565ac6261b56ee619e654709560cb94f68a8831866936555be31afe5fda4dbb0962302cd65f22bddc3044e0f0d898cb698f0a97a1f32e8ddfd8610f8371733023107a01267b1eff6700d0c790b9cf591d1a94f"


void test_pss_sha384_valid():
	char* n = malloc(300)
	char* e = malloc(8)
	char* sig = malloc(300)
	char* dig = malloc(48)
	int nlen = tr_hex(TR_N_384(), n)
	int elen = tr_e(e)
	int slen = tr_hex(TR_SIG_PSS_384(), sig)
	tr_hex(TR_SHA384(), dig)
	assert_equal(1, rsa_pss_verify_sha384(n, nlen, e, elen, sig, slen, dig))

	# Negative: flip one signature bit.
	sig[128] = sig[128] ^ 16
	assert_equal(0, rsa_pss_verify_sha384(n, nlen, e, elen, sig, slen, dig))
	sig[128] = sig[128] ^ 16
	# Negative: tamper the message hash.
	dig[47] = dig[47] ^ 1
	assert_equal(0, rsa_pss_verify_sha384(n, nlen, e, elen, sig, slen, dig))
	dig[47] = dig[47] ^ 1
	# Negative: the SHA-384 PSS signature must not verify as SHA-256 PSS
	# (hash and salt lengths differ).
	char* dig256 = malloc(32)
	tr_hex(TR_SHA256(), dig256)
	assert_equal(0, rsa_pss_verify_sha256(n, nlen, e, elen, sig, slen, dig256))
	# Sanity: still valid after undoing the tampering.
	assert_equal(1, rsa_pss_verify_sha384(n, nlen, e, elen, sig, slen, dig))
	free(n)
	free(e)
	free(sig)
	free(dig)
	free(dig256)
