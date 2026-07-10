# Unit tests for libs/standard/crypto/bignum.w. Reference values were produced
# by Python's arbitrary-precision ints (see the module's genvec harness) and
# are checked in as literal hex; the test parses hex locally (test-only
# helpers, no hex module dependency per the phase-6 scope rules).
import lib.testing
import libs.standard.crypto.bignum


int t_hexval(int c):
	if ((c >= '0') & (c <= '9')):
		return c - '0'
	if ((c >= 'a') & (c <= 'f')):
		return c - 'a' + 10
	if ((c >= 'A') & (c <= 'F')):
		return c - 'A' + 10
	return 0


# Parse a big-endian hex string into out; returns the byte length. Handles an
# odd number of nibbles by treating the leading nibble as a half byte.
int t_hex_to_bytes(char* h, char* out):
	int l = strlen(h)
	int nbytes = (l + 1) / 2
	int hi = 0
	int oi = 0
	if ((l & 1) == 1):
		out[0] = t_hexval(h[0])
		hi = 1
		oi = 1
	while (hi < l):
		out[oi] = (t_hexval(h[hi]) << 4) | t_hexval(h[hi + 1])
		hi = hi + 2
		oi = oi + 1
	return nbytes


bignum* t_from_hex(char* h):
	char* buf = malloc(strlen(h) / 2 + 2)
	int n = t_hex_to_bytes(h, buf)
	bignum* x = bignum_new()
	bignum_from_bytes(x, buf, n)
	free(buf)
	return x


void t_assert_eq_hex(bignum* got, char* expect_hex):
	bignum* want = t_from_hex(expect_hex)
	if (bignum_cmp(got, want) != 0):
		println(c"bignum mismatch; expected:")
		println(expect_hex)
		exit(1)
	bignum_free(want)


# Curve constants used as prime moduli for the modinv/modexp vectors.
char* T_P256_HEX():
	return c"ffffffff00000001000000000000000000000000ffffffffffffffffffffffff"


char* T_N256_HEX():
	return c"ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551"


char* T_A_HEX():
	return c"fedcba9876543210fedcba9876543210fedcba9876543210"


char* T_B_HEX():
	return c"123456789abcdef0123456789abcdef"


void test_small_add_sub():
	bignum* a = bignum_new()
	bignum* b = bignum_new()
	bignum* r = bignum_new()
	bignum_set_u32(a, 1000000)
	bignum_set_u32(b, 999)
	bignum_add(r, a, b)
	t_assert_eq_hex(r, c"f4627")            # 1000999
	bignum_copy(r, a)
	bignum_sub(r, b)
	t_assert_eq_hex(r, c"f3e59")            # 999001
	bignum_free(a)
	bignum_free(b)
	bignum_free(r)


void test_carry_across_limbs():
	# (2^15 - 1) + 1 crosses the first 15-bit limb boundary.
	bignum* a = bignum_new()
	bignum* one = bignum_new()
	bignum* r = bignum_new()
	bignum_set_u32(a, 32767)
	bignum_set_u32(one, 1)
	bignum_add(r, a, one)
	t_assert_eq_hex(r, c"8000")             # 32768 = 2^15
	# A chain of all-ones limbs: 2^45 - 1 plus 1 = 2^45, three limbs roll over.
	bignum_set_u32(a, 0)
	int i = 0
	while (i < 45):
		bignum_shl1(a)
		a.limbs[0] = a.limbs[0] | 1
		if (a.n == 0):
			a.n = 1
		i = i + 1
	bignum_add(r, a, one)
	t_assert_eq_hex(r, c"200000000000")     # 2^45
	bignum_free(a)
	bignum_free(one)
	bignum_free(r)


void test_add_sub_big():
	bignum* a = t_from_hex(T_A_HEX())
	bignum* b = t_from_hex(T_B_HEX())
	bignum* r = bignum_new()
	bignum_add(r, a, b)
	t_assert_eq_hex(r, c"fedcba9876543210ffffffffffffffffffffffffffffffff")
	bignum_copy(r, a)
	bignum_sub(r, b)
	t_assert_eq_hex(r, c"fedcba9876543210fdb97530eca86421fdb97530eca86421")
	bignum_free(a)
	bignum_free(b)
	bignum_free(r)


void test_mul():
	bignum* a = t_from_hex(T_A_HEX())
	bignum* b = t_from_hex(T_B_HEX())
	bignum* r = bignum_new()
	bignum_mul(r, a, b)
	t_assert_eq_hex(r, c"121fa00ad77d742247acc9140513b7446b1a52125b2c864458fab20783af1222236d88fe5618cf0")
	bignum_free(a)
	bignum_free(b)
	bignum_free(r)


void test_mod():
	bignum* a = t_from_hex(T_A_HEX())
	bignum* b = t_from_hex(T_B_HEX())
	bignum* r = bignum_new()
	bignum_mod(r, a, b)
	t_assert_eq_hex(r, c"e1f0fedcba9876551400")
	bignum_free(a)
	bignum_free(b)
	bignum_free(r)


void test_modexp():
	bignum* a = t_from_hex(T_A_HEX())
	bignum* b = t_from_hex(T_B_HEX())
	bignum* m = t_from_hex(T_P256_HEX())
	bignum* r = bignum_new()
	bignum_modexp(r, a, b, m)
	t_assert_eq_hex(r, c"864a5a89f082fa215b5b18e71728b3ee41452f4f00c931113ec3910c95e34305")
	bignum_free(a)
	bignum_free(b)
	bignum_free(m)
	bignum_free(r)


void test_modinv_prime_field():
	bignum* a = t_from_hex(T_A_HEX())
	bignum* m = t_from_hex(T_P256_HEX())
	bignum* r = bignum_new()
	bignum_modinv(r, a, m)
	t_assert_eq_hex(r, c"517a220794f7a27c13c8c8cc513b820ddbbacd15cb1a742b7b522394e9c740d7")
	# Cross-check: (a * a^{-1}) mod m == 1
	bignum* prod = bignum_new()
	bignum_modmul(prod, a, r, m)
	bignum* one = bignum_new()
	bignum_set_u32(one, 1)
	assert_equal(0, bignum_cmp(prod, one))
	bignum_free(a)
	bignum_free(m)
	bignum_free(r)
	bignum_free(prod)
	bignum_free(one)


void test_modinv_group_order():
	bignum* b = t_from_hex(T_B_HEX())
	bignum* n = t_from_hex(T_N256_HEX())
	bignum* r = bignum_new()
	bignum_modinv(r, b, n)
	t_assert_eq_hex(r, c"4cd80ea96507f8a589f066bb93b234eb6a48fc5eda0859993c68f55c11ce587a")
	bignum_free(b)
	bignum_free(n)
	bignum_free(r)


void test_byte_roundtrip():
	# 32-byte big-endian import/export must round-trip exactly, including the
	# leading zero padding.
	char* src = malloc(32)
	int i = 0
	while (i < 32):
		src[i] = (i * 7 + 3) & 255
		i = i + 1
	src[0] = 0    # force a leading zero to exercise left-padding on export
	bignum* x = bignum_new()
	bignum_from_bytes(x, src, 32)
	char* out = malloc(32)
	bignum_to_bytes(x, out, 32)
	i = 0
	while (i < 32):
		assert_equal(src[i] & 255, out[i] & 255)
		i = i + 1
	free(src)
	free(out)
	bignum_free(x)


void test_compare_and_zero():
	bignum* a = bignum_new()
	bignum* b = bignum_new()
	bignum_set_u32(a, 5)
	bignum_set_u32(b, 5)
	assert_equal(0, bignum_cmp(a, b))
	bignum_set_u32(b, 6)
	assert_equal(0 - 1, bignum_cmp(a, b))
	assert_equal(1, bignum_cmp(b, a))
	bignum_set_zero(a)
	assert_equal(1, bignum_is_zero(a))
	assert_equal(0, bignum_is_zero(b))
	bignum_free(a)
	bignum_free(b)
