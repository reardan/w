# Unit tests for libs/standard/crypto/bignum.w. Reference values were produced
# by Python's arbitrary-precision ints (see the module's genvec harness) and
# are checked in as literal hex; the test parses hex locally (test-only
# helpers, no hex module dependency per the phase-6 scope rules).
import lib.testing
import libs.standard.crypto.bignum
import lib.hex


# Parse a big-endian hex string into out; returns the byte length. Handles an
# odd number of nibbles by treating the leading nibble as a half byte.
int t_hex_to_bytes(char* h, char* out):
	int l = strlen(h)
	int nbytes = (l + 1) / 2
	int hi = 0
	int oi = 0
	if ((l & 1) == 1):
		out[0] = hex_decode_char(h[0])
		hi = 1
		oi = 1
	while (hi < l):
		out[oi] = (hex_decode_char(h[hi]) << 4) | hex_decode_char(h[hi + 1])
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
	for i in range(45):
		bignum_shl1(a)
		a.limbs[0] = a.limbs[0] | 1
		if (a.n == 0):
			a.n = 1
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

# ---- Algorithm D cross-checks against the old bit-serial division ---------

# Test oracle: the bit-at-a-time long division bignum_divmod used before it
# moved to Knuth's Algorithm D. Slow but obviously correct.
void t_divmod_bitserial(bignum* a, bignum* m, bignum* q, bignum* r):
	bignum_set_zero(q)
	bignum_set_zero(r)
	int i = bignum_bit_length(a) - 1
	while (i >= 0):
		bignum_shl1(r)
		if (bignum_get_bit(a, i) != 0):
			r.limbs[0] = r.limbs[0] | 1
			if (r.n == 0):
				r.n = 1
		if (bignum_cmp(r, m) >= 0):
			bignum_sub(r, m)
			bignum_set_bit(q, i)
		i = i - 1
	bignum_normalize(q)
	bignum_normalize(r)


int T_RNG


# 31-bit LCG (deterministic; masks keep it word-size independent).
int t_rand():
	T_RNG = (T_RNG * 1103515245 + 12345) & 2147483647
	return (T_RNG >> 8) & 32767


# Limb values biased toward the boundaries that stress normalization and the
# qhat correction (0, 1, B/2 - 1, B/2, B - 1) plus uniform limbs.
int t_rand_limb():
	int k = t_rand() % 8
	switch (k):
		case 0: return 0
		case 1: return 1
		case 2: return 16383
		case 3: return 16384
		case 4: return 32767
	return t_rand()


# Fill x with n random limbs; the top limb is forced non-zero and, when
# small_top is set, kept small so normalization shifts by many bits.
void t_rand_bignum(bignum* x, int n, int small_top):
	bignum_set_zero(x)
	for i in range(n):
		x.limbs[i] = t_rand_limb()
	if (n > 0):
		if (small_top != 0):
			x.limbs[n - 1] = 1 + (t_rand() % 7)
		elif (x.limbs[n - 1] == 0):
			x.limbs[n - 1] = 1 + t_rand()
	x.n = n
	bignum_normalize(x)


# Check divmod(a, m) against the oracle and the identity a == q*m + r, r < m.
void t_check_divmod(bignum* a, bignum* m):
	bignum* q = bignum_new()
	bignum* r = bignum_new()
	bignum* q2 = bignum_new()
	bignum* r2 = bignum_new()
	bignum* back = bignum_new()
	# Leave garbage-free but non-empty outputs to exercise stale-limb clearing.
	bignum_set_u32(q, 12345)
	bignum_copy(r, a)
	bignum_divmod(a, m, q, r)
	t_divmod_bitserial(a, m, q2, r2)
	assert_equal(0, bignum_cmp(q, q2))
	assert_equal(0, bignum_cmp(r, r2))
	assert_equal(q2.n, q.n)
	assert_equal(r2.n, r.n)
	assert_equal(0 - 1, bignum_cmp(r, m))
	# Limbs above n must stay zero (the representation invariant).
	int i = q.n
	while (i < BIGNUM_CAP):
		assert_equal(0, q.limbs[i])
		i = i + 1
	i = r.n
	while (i < BIGNUM_CAP):
		assert_equal(0, r.limbs[i])
		i = i + 1
	bignum_mul(back, q, m)
	bignum_add(back, back, r)
	assert_equal(0, bignum_cmp(back, a))
	# bignum_mod and bignum_modmul (via a * 1) agree with divmod.
	bignum_mod(r2, a, m)
	assert_equal(0, bignum_cmp(r, r2))
	bignum* one = bignum_new()
	bignum_set_u32(one, 1)
	bignum_modmul(r2, a, one, m)
	assert_equal(0, bignum_cmp(r, r2))
	bignum_free(one)
	bignum_free(q)
	bignum_free(r)
	bignum_free(q2)
	bignum_free(r2)
	bignum_free(back)


void test_divmod_random_vs_bitserial():
	T_RNG = 20260925
	bignum* a = bignum_new()
	bignum* m = bignum_new()
	for iter in range(1500):
		int mn = 1 + (t_rand() % 20)
		int an = t_rand() % 42
		t_rand_bignum(m, mn, (iter / 3) % 2)
		t_rand_bignum(a, an, 0)
		t_check_divmod(a, m)
	bignum_free(a)
	bignum_free(m)


void test_divmod_edges():
	T_RNG = 7
	bignum* a = bignum_new()
	bignum* m = bignum_new()
	bignum* t = bignum_new()
	for iter in range(60):
		int mn = 1 + (iter % 12)
		t_rand_bignum(m, mn, iter % 2)
		# a == 0
		bignum_set_zero(a)
		t_check_divmod(a, m)
		# a == m (q = 1, r = 0)
		bignum_copy(a, m)
		t_check_divmod(a, m)
		# a == m - 1 (a < m)
		bignum_sub_small(a, 1)
		t_check_divmod(a, m)
		# a == k*m and k*m - 1 for a random multi-limb k
		t_rand_bignum(t, 1 + (iter % 9), 0)
		bignum_mul(a, t, m)
		t_check_divmod(a, m)
		bignum_sub_small(a, 1)
		t_check_divmod(a, m)
		# a == m*m - 1 (largest remainder shape for a modmul)
		bignum_mul(a, m, m)
		bignum_sub_small(a, 1)
		t_check_divmod(a, m)
	# Divisor one: q = a, r = 0.
	bignum_set_u32(m, 1)
	t_rand_bignum(a, 30, 0)
	t_check_divmod(a, m)
	# Single-limb divisors at the extremes.
	bignum_set_u32(m, 32767)
	t_check_divmod(a, m)
	bignum_set_u32(m, 2)
	t_check_divmod(a, m)
	# Two-limb divisor with top limb 1 (normalization shifts by 14 bits).
	bignum_set_u32(m, 32768 + 5)
	t_check_divmod(a, m)
	bignum_free(a)
	bignum_free(m)
	bignum_free(t)


# Operands (found by a Python model of the same algorithm) whose trial
# quotient survives the qhat/v[n-2] test yet is still one too large, forcing
# the D6 add-back step.
void t_check_addback(char* ah, char* mh, char* qh, char* rh):
	bignum* a = t_from_hex(ah)
	bignum* m = t_from_hex(mh)
	bignum* q = bignum_new()
	bignum* r = bignum_new()
	bignum_divmod(a, m, q, r)
	t_assert_eq_hex(q, qh)
	t_assert_eq_hex(r, rh)
	t_check_divmod(a, m)
	bignum_free(a)
	bignum_free(m)
	bignum_free(q)
	bignum_free(r)


void test_divmod_addback():
	t_check_addback(c"7ffe7ffffffffffc001", c"fffdfffffff", c"7fff7fff", c"5fff4000")
	t_check_addback(c"7ffe7ffffffe000ffff", c"1fffdfffc001", c"3fff7fff", c"1fff60014000")
	t_check_addback(c"80010000ffff0003fff4001", c"4000800100000014001", c"1ffff", c"3fff7fffffdbffe8002")
	t_check_addback(c"7ffe8002fffe0003fff", c"1fffa000c001", c"3fffffff", c"1fff40010000")
# wbuild: target=crypto_bignum_test tag=tests dep=wv2
# wbuild: step="bin/wv2 libs/standard/crypto/bignum_test.w -o bin/crypto_bignum_test"
# wbuild: step="bin/crypto_bignum_test"
# wbuild: step="bin/wv2 x64 libs/standard/crypto/bignum_test.w -o bin/crypto_bignum_test_x64"
# wbuild: step="bin/crypto_bignum_test_x64"
