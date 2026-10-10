# wbuild: name=crypto_ecdh_p256_test x64
# RFC 5903 section 8.1, https://www.rfc-editor.org/rfc/rfc5903#section-8.1
import lib.testing
import lib.hex
import libs.standard.crypto.ecdh_p256


char* ep_hex(char* s):
	int n = 0
	return hex_decode_loose(s, &n)


void test_ecdh_p256_rfc5903():
	char* a = ep_hex(c"C88F01F510D9AC3F70A292DAA2316DE544E9AAB8AFE84049C62A9C57862D1433")
	char* b = ep_hex(c"C6EF9C5D78AE012A011164ACB397CE2088685D8F06BF9BE0B283AB46476BEE53")
	char* ap = ep_hex(c"04DAD0B65394221CF9B051E1FECA5787D098DFE637FC90B9EF945D0C37725811805271A0461CDB8252D61F1C456FA3E59AB1F45B33ACCF5F58389E0577B8990BB3")
	char* bp = ep_hex(c"04D12DFB5289C8D4F81208B70270398C342296970A0BCCB74C736FC7554494BF6356FBF3CA366CC23E8157854C13C58D6AAC23F046ADA30F8353E74F33039872AB")
	char* want = ep_hex(c"D6840F6B42F6EDAFD13116E0E12565202FEF8E9ECE7DCE03812464D04B9442DE")
	char[65] out
	assert_equal(1, ecdh_p256_public_key(a, out))
	assert_bytes_equal(ap, out, 65)
	assert_equal(1, ecdh_p256_public_key(b, out))
	assert_bytes_equal(bp, out, 65)
	assert_equal(1, ecdh_p256_shared_secret(a, bp, 65, out))
	assert_bytes_equal(want, out, 32)
	assert_equal(1, ecdh_p256_shared_secret(b, ap, 65, out))
	assert_bytes_equal(want, out, 32)
	free(a)
	free(b)
	free(ap)
	free(bp)
	free(want)


void test_ecdh_p256_reject_invalid():
	char[32] priv
	char[65] pub
	char[65] out
	char[65] unchanged
	mem_fill(cast(char*, priv), 0, 32)
	mem_fill(cast(char*, out), 0x5a, 65)
	mem_copy(cast(char*, unchanged), cast(char*, out), 65)
	assert_equal(0, ecdh_p256_public_key(priv, out))
	assert_bytes_equal(unchanged, out, 65)
	bignum_to_bytes(P256_N, priv, 32)
	assert_equal(0, ecdh_p256_public_key(priv, out))
	mem_fill(cast(char*, priv), 255, 32)
	assert_equal(0, ecdh_p256_public_key(priv, out))
	mem_fill(cast(char*, priv), 0, 32)
	priv[31] = 1
	assert_equal(1, ecdh_p256_public_key(priv, pub))
	assert_equal(0, ecdh_p256_shared_secret(priv, pub, 64, out))
	assert_equal(0, ecdh_p256_shared_secret(priv, pub, 66, out))
	assert_equal(0, ecdh_p256_shared_secret(priv, 0, 65, out))
	pub[0] = 2
	assert_equal(0, ecdh_p256_shared_secret(priv, pub, 65, out))
	pub[0] = 4
	pub[64] ^= 1
	assert_equal(0, ecdh_p256_shared_secret(priv, pub, 65, out))
	bignum_to_bytes(P256_P, cast(char*, pub) + 1, 32)
	assert_equal(0, ecdh_p256_shared_secret(priv, pub, 65, out))
	mem_fill(cast(char*, pub) + 1, 0, 64)
	assert_equal(0, ecdh_p256_shared_secret(priv, pub, 65, out))
	assert_bytes_equal(unchanged, out, 65)
	assert_equal(1, ecdh_p256_generate(priv))
	assert_equal(1, ecdh_p256_private_valid(priv))
