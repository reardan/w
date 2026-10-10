# wbuild: name=crypto_ecdsa_p384_test x64
# Independent known-answer vectors: RFC 6979 Appendix A.2.6, "sample".
# https://www.rfc-editor.org/rfc/rfc6979#appendix-A.2.6
import lib.testing
import lib.hex
import lib.mem
import libs.standard.crypto.sha2
import libs.standard.crypto.ecdsa_p384


void tp384_vector(int alg, int hashlen, char* rh, char* sh):
	char[48] qx
	char[48] qy
	char[48] r
	char[48] s
	char[64] hash
	hex_decode_into(c"ec3a4e415b4e19a4568618029f427fa5da9a8bc4ae92e02e06aae5286b300c64def8f0ea9055866064a254515480bc13", qx, 48)
	hex_decode_into(c"8015d9b72d7d57244ea8ef9ac0c621896708a59367f9dfb9f54ca84b3f1c9db1288b231c3ae0d4fe7344fd2533264720", qy, 48)
	hex_decode_into(rh, r, 48)
	hex_decode_into(sh, s, 48)
	whash_oneshot(alg, c"sample", 6, hash)
	assert_equal(1, ecdsa_p384_verify(qx, qy, hash, hashlen, r, s))
	hash[0] ^= 1
	assert_equal(0, ecdsa_p384_verify(qx, qy, hash, hashlen, r, s))
	hash[0] ^= 1
	r[20] ^= 1
	assert_equal(0, ecdsa_p384_verify(qx, qy, hash, hashlen, r, s))
	r[20] ^= 1
	qy[0] ^= 1
	assert_equal(0, ecdsa_p384_verify(qx, qy, hash, hashlen, r, s))
	qy[0] ^= 1
	# Noncanonical coordinates and out-of-range signature integers reject.
	mem_fill(cast(char*, qx), 255, 48)
	assert_equal(0, ecdsa_p384_verify(qx, qy, hash, hashlen, r, s))
	mem_fill(cast(char*, qx), 0, 48)
	mem_fill(cast(char*, qy), 0, 48)
	assert_equal(0, ecdsa_p384_verify(qx, qy, hash, hashlen, r, s))
	hex_decode_into(c"ec3a4e415b4e19a4568618029f427fa5da9a8bc4ae92e02e06aae5286b300c64def8f0ea9055866064a254515480bc13", qx, 48)
	hex_decode_into(c"8015d9b72d7d57244ea8ef9ac0c621896708a59367f9dfb9f54ca84b3f1c9db1288b231c3ae0d4fe7344fd2533264720", qy, 48)
	mem_fill(cast(char*, r), 0, 48)
	assert_equal(0, ecdsa_p384_verify(qx, qy, hash, hashlen, r, s))
	hex_decode_into(c"ffffffffffffffffffffffffffffffffffffffffffffffffc7634d81f4372ddf581a0db248b0a77aecec196accc52973", r, 48)
	assert_equal(0, ecdsa_p384_verify(qx, qy, hash, hashlen, r, s))
	hex_decode_into(rh, r, 48)
	mem_fill(cast(char*, s), 0, 48)
	assert_equal(0, ecdsa_p384_verify(qx, qy, hash, hashlen, r, s))
	hex_decode_into(c"ffffffffffffffffffffffffffffffffffffffffffffffffc7634d81f4372ddf581a0db248b0a77aecec196accc52973", s, 48)
	assert_equal(0, ecdsa_p384_verify(qx, qy, hash, hashlen, r, s))


void test_p384_rfc6979_vectors():
	tp384_vector(WHASH_SHA256, 32, c"21b13d1e013c7fa1392d03c5f99af8b30c570c6f98d4ea8e354b63a21d3daa33bde1e888e63355d92fa2b3c36d8fb2cd", c"f3aa443fb107745bf4bd77cb3891674632068a10ca67e3d45db2266fa7d1feebefdc63eccd1ac42ec0cb8668a4fa0ab0")
	tp384_vector(WHASH_SHA384, 48, c"94edbb92a5ecb8aad4736e56c691916b3f88140666ce9fa73d64c4ea95ad133c81a648152e44acf96e36dd1e80fabe46", c"99ef4aeb15f178cea1fe40db2603138f130e740a19624526203b6351d0a3a94fa329c145786e679e7b82c71a38628ac8")
	tp384_vector(WHASH_SHA512, 64, c"ed0959d5880ab2d869ae7f6c2915c6d60f96507f9cb3e047c0046861da4a799cfe30f35cc900056d7c99cd7882433709", c"512c8cceee3890a84058ce1e22dbc2198f42323ce8aca9135329f03c068e5112dc7cc3ef3446defceb01a45c2667fdd5")


void test_p384_infinity_rejected():
	# With Q = G, r = s = 1, z = n-1, z*G + Q is infinity.
	p384_context* ctx = p384_context_new()
	char[48] qx
	char[48] qy
	char[48] hash
	char[48] one
	bignum_to_bytes(ctx.GX, qx, 48)
	bignum_to_bytes(ctx.GY, qy, 48)
	bignum_sub_small(ctx.N, 1)
	bignum_to_bytes(ctx.N, hash, 48)
	mem_fill(cast(char*, one), 0, 48)
	one[47] = 1
	assert_equal(0, ecdsa_p384_verify(qx, qy, hash, 48, one, one))
	p384_context_free(ctx)
