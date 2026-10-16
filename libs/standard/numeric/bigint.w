# Arbitrary-precision signed integers with Python `int` semantics
# (docs/projects/stdlib_python_parity.md P3.5a).
#
# VALUES ARE IMMUTABLE. Every operation returns a freshly allocated bigint*
# that the caller releases with bigint_free(); inputs are never modified and
# may alias each other freely. Operations that Python would answer with an
# exception (division by zero, negative shift count, negative exponent
# without a modulus, isqrt of a negative, bad parse input) return 0 (null)
# instead.
#
# LIMB BASE: 2^15, one limb per word-sized int, little-endian, as in
# libs/standard/crypto/bignum.w. W has no type wider than the word on x86,
# so the base is chosen for the 32-bit target: a schoolbook
# multiply-accumulate t = r + a*b + carry stays below (2^15)^2 = 2^30 < 2^31.
# The same representation is used on x64 so results are identical on every
# target; x64 only widens the chunk used by decimal/string conversion
# (base^k up to 2^46 instead of 2^15, i.e. 10^13 instead of 10^4 per
# short-division pass).
#
# Representation: sign is -1, 0 or 1; n is the number of significant limbs
# (0 exactly when the value is zero, no leading zero limbs otherwise);
# limbs holds at least max(n, 1) words.
#
# Multiplication is schoolbook below bigint_karatsuba_threshold() limbs and
# Karatsuba above it. Division is Knuth's Algorithm D (quadratic); string
# conversion is chunked short division (quadratic with a small constant).
import lib.lib
import lib.memory
import lib.mem


const int BIGINT_LIMB_BITS = 15
const int BIGINT_BASE = 32768
const int BIGINT_MASK = 32767


struct bigint:
	int sign       # -1, 0 or 1
	int n          # significant limbs; 0 for the value zero
	int* limbs     # little-endian base-2^15 limbs


# ---- tuning -----------------------------------------------------------------

int BIGINT_KARATSUBA_OVERRIDE


# Operand size (in limbs, of the shorter factor) at which multiplication
# switches from schoolbook to Karatsuba.
int bigint_karatsuba_threshold():
	if (BIGINT_KARATSUBA_OVERRIDE > 0): return BIGINT_KARATSUBA_OVERRIDE
	return 40


# Overrides the Karatsuba cutoff (limbs >= 2); 0 restores the default.
# Tests use it to cross-check both multiplication paths.
void bigint_set_karatsuba_threshold(int limbs):
	if ((limbs != 0) && (limbs < 2)): limbs = 2
	BIGINT_KARATSUBA_OVERRIDE = limbs


# Largest chunk value for one short-division / multiply-add pass: chunk *
# 2^15 + limb must stay inside a signed word.
int bigint_chunk_limit():
	int limit = BIGINT_MASK
	if (__word_size__ == 8):
		limit = limit * BIGINT_BASE
		limit = limit * BIGINT_BASE * 2
	return limit


# ---- allocation -------------------------------------------------------------

int* bigint_limbs_alloc(int n):
	if (n < 1): n = 1
	int* p = cast(int*, malloc(n * __word_size__))
	mem_fill(p, 0, n)
	return p


# Wraps limbs (ownership transfers) into a value, trimming leading zeros.
bigint* bigint_make(int* limbs, int n, int sign):
	while ((n > 0) && (limbs[n - 1] == 0)): n = n - 1
	if (n == 0): sign = 0
	return new bigint(sign, n, limbs)


void bigint_free(bigint* a):
	if (a == 0): return
	free(cast(char*, a.limbs))
	free(cast(char*, a))


bigint* bigint_zero():
	return bigint_make(bigint_limbs_alloc(1), 0, 0)


bigint* bigint_from_int(int v):
	int* l = bigint_limbs_alloc(5)    # ceil(64 / 15) limbs cover any word
	int sign = 0
	if (v > 0): sign = 1
	if (v < 0): sign = 0 - 1
	int i = 0
	while (v != 0):
		# % and / truncate toward zero, so a negative v yields negative
		# digits; negating each digit avoids negating v (INT_MIN safe).
		int d = v % BIGINT_BASE
		if (d < 0): d = 0 - d
		l[i] = d
		v = v / BIGINT_BASE
		i = i + 1
	return bigint_make(l, i, sign)


bigint* bigint_copy(bigint* a):
	int* l = bigint_limbs_alloc(a.n)
	mem_copy(l, a.limbs, a.n)
	return bigint_make(l, a.n, a.sign)


bigint* bigint_neg(bigint* a):
	bigint* r = bigint_copy(a)
	r.sign = 0 - r.sign
	return r


bigint* bigint_abs(bigint* a):
	bigint* r = bigint_copy(a)
	if (r.sign < 0): r.sign = 1
	return r


# ---- predicates and comparison ----------------------------------------------

int bigint_sign(bigint* a):
	return a.sign


int bigint_is_zero(bigint* a):
	return a.sign == 0


int bigint_mag_trim(int* a, int n):
	while ((n > 0) && (a[n - 1] == 0)): n = n - 1
	return n


# Compares trimmed magnitudes: -1, 0 or 1.
int bigint_mag_cmp(int* a, int an, int* b, int bn):
	if (an != bn):
		if (an < bn): return 0 - 1
		return 1
	int i = an - 1
	while (i >= 0):
		if (a[i] != b[i]):
			if (a[i] < b[i]): return 0 - 1
			return 1
		i = i - 1
	return 0


# Signed comparison: -1 if a < b, 0 if equal, 1 if a > b.
int bigint_cmp(bigint* a, bigint* b):
	if (a.sign != b.sign):
		if (a.sign < b.sign): return 0 - 1
		return 1
	int c = bigint_mag_cmp(a.limbs, a.n, b.limbs, b.n)
	if (a.sign < 0): return 0 - c
	return c


int bigint_cmp_int(bigint* a, int v):
	bigint* b = bigint_from_int(v)
	int c = bigint_cmp(a, b)
	bigint_free(b)
	return c


int bigint_eq(bigint* a, bigint* b):
	return bigint_cmp(a, b) == 0


# Number of bits in |a| (Python int.bit_length); 0 for zero.
int bigint_bit_length(bigint* a):
	if (a.n == 0): return 0
	int top = a.limbs[a.n - 1]
	int bits = (a.n - 1) * BIGINT_LIMB_BITS
	while (top > 0):
		bits = bits + 1
		top = top >> 1
	return bits


# Bit i of |a|.
int bigint_mag_bit(bigint* a, int i):
	int li = i / BIGINT_LIMB_BITS
	if (li >= a.n): return 0
	return (a.limbs[li] >> (i % BIGINT_LIMB_BITS)) & 1


int bigint_is_odd(bigint* a):
	if (a.n == 0): return 0
	return a.limbs[0] & 1


# ---- conversion to int ------------------------------------------------------

# 1 when a fits a signed word-sized int.
int bigint_fits_int(bigint* a):
	int wbits = __word_size__ * 8
	int bl = bigint_bit_length(a)
	if (bl < wbits): return 1
	if ((bl > wbits) || (a.sign > 0)): return 0
	# -2^(wbits-1) fits: |a| must be exactly a power of two.
	int i = 0
	while (i < a.n - 1):
		if (a.limbs[i] != 0): return 0
		i = i + 1
	int top = a.limbs[a.n - 1]
	return (top & (top - 1)) == 0


# a as an int. *ok (if non-null) is 1 on success, 0 on overflow (result 0).
int bigint_to_int(bigint* a, int* ok):
	if (bigint_fits_int(a) == 0):
		if (ok != 0): *ok = 0
		return 0
	# Accumulate the negated magnitude so INT_MIN does not overflow.
	int acc = 0
	int i = a.n - 1
	while (i >= 0):
		acc = acc * BIGINT_BASE - a.limbs[i]
		i = i - 1
	if (a.sign > 0): acc = 0 - acc
	if (ok != 0): *ok = 1
	return acc


# ---- magnitude add / sub ----------------------------------------------------

# r = a + b over magnitudes; r needs max(an, bn) + 1 limbs and may alias a
# or b. Returns the trimmed length.
int bigint_mag_add(int* r, int* a, int an, int* b, int bn):
	if (an < bn):
		int* tp = a
		a = b
		b = tp
		int tn = an
		an = bn
		bn = tn
	int carry = 0
	int i = 0
	while (i < bn):
		int t = a[i] + b[i] + carry
		r[i] = t & BIGINT_MASK
		carry = t >> BIGINT_LIMB_BITS
		i = i + 1
	while (i < an):
		int t2 = a[i] + carry
		r[i] = t2 & BIGINT_MASK
		carry = t2 >> BIGINT_LIMB_BITS
		i = i + 1
	r[an] = carry
	return bigint_mag_trim(r, an + 1)


# r = a - b over magnitudes, requires a >= b; r needs an limbs and may alias
# a. Returns the trimmed length.
int bigint_mag_sub(int* r, int* a, int an, int* b, int bn):
	int borrow = 0
	int i = 0
	while (i < an):
		int bv = 0
		if (i < bn): bv = b[i]
		int d = a[i] - bv - borrow
		if (d < 0):
			d = d + BIGINT_BASE
			borrow = 1
		else: borrow = 0
		r[i] = d
		i = i + 1
	return bigint_mag_trim(r, an)


# r[off ..] += x, carrying upward inside r's rn limbs.
void bigint_mag_add_at(int* r, int rn, int off, int* x, int xn):
	int carry = 0
	int i = 0
	while ((i < xn) || ((carry != 0) && (off + i < rn))):
		int xv = 0
		if (i < xn): xv = x[i]
		int t = r[off + i] + xv + carry
		r[off + i] = t & BIGINT_MASK
		carry = t >> BIGINT_LIMB_BITS
		i = i + 1


# In place a = a * mul + add for a small non-negative mul and add
# (each <= bigint_chunk_limit()). a needs room for the grown value.
int bigint_mag_mul_small_add(int* a, int an, int mul, int add):
	int carry = add
	int i = 0
	while (i < an):
		int t = a[i] * mul + carry
		a[i] = t & BIGINT_MASK
		carry = t >> BIGINT_LIMB_BITS
		i = i + 1
	while (carry != 0):
		a[i] = carry & BIGINT_MASK
		carry = carry >> BIGINT_LIMB_BITS
		i = i + 1
	return bigint_mag_trim(a, i)


# q = a / d, returns a % d, for 0 < d <= bigint_chunk_limit(). q needs an
# limbs and may alias a.
int bigint_mag_divmod_small(int* q, int* a, int an, int d):
	int rem = 0
	int i = an - 1
	while (i >= 0):
		int cur = rem * BIGINT_BASE + a[i]
		int qd = cur / d
		q[i] = qd
		rem = cur - qd * d
		i = i - 1
	return rem


# ---- signed add / sub -------------------------------------------------------

# a + (bs * |b|).
bigint* bigint_addsub(bigint* a, bigint* b, int bs):
	if (bs == 0): return bigint_copy(a)
	if (a.sign == 0):
		bigint* c = bigint_copy(b)
		c.sign = bs
		return c
	int n = a.n
	if (b.n > n): n = b.n
	int* l = bigint_limbs_alloc(n + 1)
	if (a.sign == bs):
		return bigint_make(l, bigint_mag_add(l, a.limbs, a.n, b.limbs, b.n), bs)
	int c2 = bigint_mag_cmp(a.limbs, a.n, b.limbs, b.n)
	if (c2 == 0): return bigint_make(l, 0, 0)
	if (c2 > 0): return bigint_make(l, bigint_mag_sub(l, a.limbs, a.n, b.limbs, b.n), a.sign)
	return bigint_make(l, bigint_mag_sub(l, b.limbs, b.n, a.limbs, a.n), bs)


bigint* bigint_add(bigint* a, bigint* b):
	return bigint_addsub(a, b, b.sign)


bigint* bigint_sub(bigint* a, bigint* b):
	return bigint_addsub(a, b, 0 - b.sign)


bigint* bigint_add_int(bigint* a, int v):
	bigint* b = bigint_from_int(v)
	bigint* r = bigint_add(a, b)
	bigint_free(b)
	return r


# ---- multiplication ---------------------------------------------------------

# r += a * b (schoolbook); r needs an + bn limbs, distinct from a and b.
void bigint_mag_mul_school(int* r, int* a, int an, int* b, int bn):
	int i = 0
	while (i < an):
		int ai = a[i]
		if (ai != 0):
			int* rp = &r[i]
			int carry = 0
			for j in range(bn):
				int t = rp[j] + ai * b[j] + carry
				rp[j] = t & BIGINT_MASK
				carry = t >> BIGINT_LIMB_BITS
			int k = bn
			while (carry != 0):
				int t2 = rp[k] + carry
				rp[k] = t2 & BIGINT_MASK
				carry = t2 >> BIGINT_LIMB_BITS
				k = k + 1
		i = i + 1


# r = a * b for trimmed magnitudes. r must hold an + bn ZEROED limbs and be
# distinct from a and b. Karatsuba once the shorter factor reaches the
# threshold; very unbalanced operands are cut into slices of the shorter
# factor's length.
void bigint_mag_mul(int* r, int* a, int an, int* b, int bn):
	if (an < bn):
		int* tp = a
		a = b
		b = tp
		int tn = an
		an = bn
		bn = tn
	if (bn == 0): return
	if (bn < bigint_karatsuba_threshold()):
		bigint_mag_mul_school(r, a, an, b, bn)
		return
	if (an >= 2 * bn):
		int* part = bigint_limbs_alloc(2 * bn)
		int off = 0
		while (off < an):
			int len = an - off
			if (len > bn): len = bn
			int ln = bigint_mag_trim(&a[off], len)
			mem_fill(part, 0, 2 * bn)
			bigint_mag_mul(part, &a[off], ln, b, bn)
			bigint_mag_add_at(r, an + bn, off, part, bigint_mag_trim(part, ln + bn))
			off = off + bn
		free(cast(char*, part))
		return
	# Split both at m (< bn, so b1 is non-empty):
	#   a = a1*B^m + a0, b = b1*B^m + b0
	#   a*b = z2*B^2m + (s - z2 - z0)*B^m + z0, s = (a0+a1)(b0+b1)
	int m = an / 2
	int* a1 = &a[m]
	int* b1 = &b[m]
	int a0n = bigint_mag_trim(a, m)
	int b0n = bigint_mag_trim(b, m)
	int a1n = an - m
	int b1n = bn - m
	bigint_mag_mul(r, a, a0n, b, b0n)
	bigint_mag_mul(&r[2 * m], a1, a1n, b1, b1n)
	int* sa = bigint_limbs_alloc(an + 1)
	int* sb = bigint_limbs_alloc(bn + 1)
	int san = bigint_mag_add(sa, a, a0n, a1, a1n)
	int sbn = bigint_mag_add(sb, b, b0n, b1, b1n)
	int* z1 = bigint_limbs_alloc(san + sbn)
	bigint_mag_mul(z1, sa, san, sb, sbn)
	int z1n = bigint_mag_trim(z1, san + sbn)
	z1n = bigint_mag_sub(z1, z1, z1n, r, bigint_mag_trim(r, 2 * m))
	z1n = bigint_mag_sub(z1, z1, z1n, &r[2 * m], bigint_mag_trim(&r[2 * m], an + bn - 2 * m))
	bigint_mag_add_at(r, an + bn, m, z1, z1n)
	free(cast(char*, sa))
	free(cast(char*, sb))
	free(cast(char*, z1))


bigint* bigint_mul(bigint* a, bigint* b):
	if ((a.sign == 0) || (b.sign == 0)): return bigint_zero()
	int* l = bigint_limbs_alloc(a.n + b.n)
	bigint_mag_mul(l, a.limbs, a.n, b.limbs, b.n)
	return bigint_make(l, a.n + b.n, a.sign * b.sign)


bigint* bigint_mul_int(bigint* a, int v):
	bigint* b = bigint_from_int(v)
	bigint* r = bigint_mul(a, b)
	bigint_free(b)
	return r


# ---- division ---------------------------------------------------------------

# Knuth TAOCP vol. 2, 4.3.1, Algorithm D on trimmed magnitudes with
# bn >= 2 and an >= bn. q gets an - bn + 1 limbs, r gets bn limbs (both
# zeroed, distinct from the inputs). Overflow bounds are those documented in
# libs/standard/crypto/bignum.w's bignum_divmod (all < 2^31).
void bigint_mag_divmod_knuth(int* q, int* r, int* a, int an, int* b, int bn):
	int* un = bigint_limbs_alloc(an + 1)
	int* vn = bigint_limbs_alloc(bn)
	int s = 0
	int top = b[bn - 1]
	while (top < 16384):
		top = top << 1
		s = s + 1
	int rs = BIGINT_LIMB_BITS - s
	int i = bn - 1
	while (i > 0):
		vn[i] = ((b[i] << s) | (b[i - 1] >> rs)) & BIGINT_MASK
		i = i - 1
	vn[0] = (b[0] << s) & BIGINT_MASK
	un[an] = a[an - 1] >> rs
	i = an - 1
	while (i > 0):
		un[i] = ((a[i] << s) | (a[i - 1] >> rs)) & BIGINT_MASK
		i = i - 1
	un[0] = (a[0] << s) & BIGINT_MASK
	int vtop = vn[bn - 1]
	int vsec = vn[bn - 2]
	int j = an - bn
	while (j >= 0):
		int num = un[j + bn] * BIGINT_BASE + un[j + bn - 1]
		int qhat = num / vtop
		int rhat = num - qhat * vtop
		while ((qhat >= BIGINT_BASE) || (qhat * vsec > rhat * BIGINT_BASE + un[j + bn - 2])):
			qhat = qhat - 1
			rhat = rhat + vtop
			if (rhat >= BIGINT_BASE): break
		int* uj = &un[j]
		int k = 0
		i = 0
		while (i < bn):
			int p = qhat * vn[i]
			int t = uj[i] - k - (p & BIGINT_MASK)
			uj[i] = t & BIGINT_MASK
			k = (p >> BIGINT_LIMB_BITS) - (t >> BIGINT_LIMB_BITS)
			i = i + 1
		int tt = uj[bn] - k
		if (tt < 0):
			qhat = qhat - 1
			int c = 0
			i = 0
			while (i < bn):
				int t2 = uj[i] + vn[i] + c
				uj[i] = t2 & BIGINT_MASK
				c = t2 >> BIGINT_LIMB_BITS
				i = i + 1
			tt = tt + c
		un[j + bn] = tt
		q[j] = qhat
		j = j - 1
	i = 0
	while (i < bn):
		r[i] = (un[i] >> s) | ((un[i + 1] << rs) & BIGINT_MASK)
		i = i + 1
	free(cast(char*, un))
	free(cast(char*, vn))


# |a| divmod |b| (b non-zero) into non-negative *qo and *ro.
void bigint_mag_divmod(bigint* a, bigint* b, bigint** qo, bigint** ro):
	if (bigint_mag_cmp(a.limbs, a.n, b.limbs, b.n) < 0):
		*qo = bigint_zero()
		*ro = bigint_abs(a)
		return
	int* ql = bigint_limbs_alloc(a.n)
	if (b.n == 1):
		int rem = bigint_mag_divmod_small(ql, a.limbs, a.n, b.limbs[0])
		*qo = bigint_make(ql, a.n, 1)
		*ro = bigint_from_int(rem)
		return
	int* rl = bigint_limbs_alloc(b.n)
	bigint_mag_divmod_knuth(ql, rl, a.limbs, a.n, b.limbs, b.n)
	*qo = bigint_make(ql, a.n - b.n + 1, 1)
	*ro = bigint_make(rl, b.n, 1)


# Floor division (Python divmod): q = floor(a / b), r = a - q*b, so r is
# zero or has b's sign. Returns 0 (leaving *q and *r untouched) when b is
# zero, else 1. q or r may be null when that result is not wanted.
int bigint_divmod(bigint* a, bigint* b, bigint** q, bigint** r):
	if (b.sign == 0): return 0
	bigint* qq = 0
	bigint* rr = 0
	bigint_mag_divmod(a, b, &qq, &rr)
	if (qq.n != 0): qq.sign = a.sign * b.sign
	if (rr.n != 0): rr.sign = a.sign
	if ((rr.sign != 0) && (a.sign != b.sign)):
		bigint* q2 = bigint_add_int(qq, 0 - 1)
		bigint_free(qq)
		qq = q2
		bigint* r2 = bigint_add(rr, b)
		bigint_free(rr)
		rr = r2
	if (q != 0): *q = qq
	else: bigint_free(qq)
	if (r != 0): *r = rr
	else: bigint_free(rr)
	return 1


# a // b (floor); null when b is zero.
bigint* bigint_floordiv(bigint* a, bigint* b):
	bigint* q = 0
	bigint_divmod(a, b, &q, 0)
	return q


# a % b (result has b's sign); null when b is zero.
bigint* bigint_mod(bigint* a, bigint* b):
	bigint* r = 0
	bigint_divmod(a, b, 0, &r)
	return r


# Truncating division (C semantics: quotient rounds toward zero, remainder
# has a's sign). Returns 0 when b is zero.
int bigint_divmod_trunc(bigint* a, bigint* b, bigint** q, bigint** r):
	if (b.sign == 0): return 0
	bigint* qq = 0
	bigint* rr = 0
	bigint_mag_divmod(a, b, &qq, &rr)
	if (qq.n != 0): qq.sign = a.sign * b.sign
	if (rr.n != 0): rr.sign = a.sign
	if (q != 0): *q = qq
	else: bigint_free(qq)
	if (r != 0): *r = rr
	else: bigint_free(rr)
	return 1


bigint* bigint_shl(bigint* a, int k);
bigint* bigint_shr(bigint* a, int k);


# ---- powers, gcd, roots -----------------------------------------------------

# a ** e for e >= 0 (0 ** 0 == 1); null for a negative e.
bigint* bigint_pow(bigint* a, int e):
	if (e < 0): return 0
	bigint* result = bigint_from_int(1)
	bigint* base = bigint_copy(a)
	while (e > 0):
		if ((e & 1) != 0):
			bigint* t = bigint_mul(result, base)
			bigint_free(result)
			result = t
		e = e >> 1
		if (e > 0):
			bigint* t2 = bigint_mul(base, base)
			bigint_free(base)
			base = t2
	bigint_free(base)
	return result


# gcd(|a|, |b|), always non-negative; gcd(0, 0) == 0.
bigint* bigint_gcd(bigint* a, bigint* b):
	bigint* x = bigint_abs(a)
	bigint* y = bigint_abs(b)
	while (y.sign != 0):
		bigint* t = bigint_mod(x, y)
		bigint_free(x)
		x = y
		y = t
	bigint_free(y)
	return x


# lcm(|a|, |b|), non-negative; 0 when either is zero.
bigint* bigint_lcm(bigint* a, bigint* b):
	if ((a.sign == 0) || (b.sign == 0)): return bigint_zero()
	bigint* g = bigint_gcd(a, b)
	bigint* q = bigint_floordiv(a, g)
	bigint* p = bigint_mul(q, b)
	if (p.sign < 0): p.sign = 1
	bigint_free(g)
	bigint_free(q)
	return p


# Modular inverse x with (a * x) % m == 1 % m, reduced into m's sign range
# like Python's pow(a, -1, m). Null when m is zero or gcd(a, m) != 1.
bigint* bigint_modinv(bigint* a, bigint* m):
	if (m.sign == 0): return 0
	bigint* am = bigint_abs(m)
	bigint* old_r = bigint_mod(a, am)
	bigint* r = am
	bigint* old_s = bigint_from_int(1)
	bigint* s = bigint_zero()
	while (r.sign != 0):
		bigint* q = 0
		bigint* rem = 0
		bigint_divmod(old_r, r, &q, &rem)
		bigint_free(old_r)
		old_r = r
		r = rem
		bigint* qs = bigint_mul(q, s)
		bigint* ns = bigint_sub(old_s, qs)
		bigint_free(qs)
		bigint_free(q)
		bigint_free(old_s)
		old_s = s
		s = ns
	bigint* result = 0
	if (bigint_cmp_int(old_r, 1) == 0): result = bigint_mod(old_s, m)
	bigint_free(old_r)
	bigint_free(r)
	bigint_free(old_s)
	bigint_free(s)
	return result


# Python pow(a, e, m): the result has m's sign (or is zero). A negative e
# uses the modular inverse of a. Null when m is zero or e < 0 and a has no
# inverse modulo m.
bigint* bigint_powmod(bigint* a, bigint* e, bigint* m):
	if (m.sign == 0): return 0
	bigint* am = bigint_abs(m)
	bigint* base = 0
	if (e.sign < 0):
		base = bigint_modinv(a, am)
		if (base == 0):
			bigint_free(am)
			return 0
	else: base = bigint_mod(a, am)
	bigint* one = bigint_from_int(1)
	bigint* result = bigint_mod(one, am)
	bigint_free(one)
	int i = bigint_bit_length(e) - 1
	while (i >= 0):
		bigint* sq = bigint_mul(result, result)
		bigint_free(result)
		result = bigint_mod(sq, am)
		bigint_free(sq)
		if (bigint_mag_bit(e, i) != 0):
			bigint* pr = bigint_mul(result, base)
			bigint_free(result)
			result = bigint_mod(pr, am)
			bigint_free(pr)
		i = i - 1
	if ((m.sign < 0) && (result.sign != 0)):
		bigint* adj = bigint_add(result, m)
		bigint_free(result)
		result = adj
	bigint_free(base)
	bigint_free(am)
	return result


bigint* bigint_powmod_int(bigint* a, int e, bigint* m):
	bigint* eb = bigint_from_int(e)
	bigint* r = bigint_powmod(a, eb, m)
	bigint_free(eb)
	return r


# floor(sqrt(a)) for a >= 0 (Python math.isqrt); null for negative a.
bigint* bigint_isqrt(bigint* a):
	if (a.sign < 0): return 0
	if (a.sign == 0): return bigint_zero()
	bigint* one = bigint_from_int(1)
	bigint* x = bigint_shl(one, (bigint_bit_length(a) + 1) / 2)
	bigint_free(one)
	while (1):
		bigint* d = bigint_floordiv(a, x)
		bigint* s = bigint_add(x, d)
		bigint* y = bigint_shr(s, 1)
		bigint_free(d)
		bigint_free(s)
		if (bigint_cmp(y, x) >= 0):
			bigint_free(y)
			return x
		bigint_free(x)
		x = y
	return x


# Product lo * (lo+1) * ... * hi by binary splitting (balanced operands
# keep Karatsuba effective).
bigint* bigint_product_range(int lo, int hi):
	if (lo > hi): return bigint_from_int(1)
	if (hi - lo < 8):
		bigint* r = bigint_from_int(lo)
		int k = lo + 1
		while (k <= hi):
			bigint* t = bigint_mul_int(r, k)
			bigint_free(r)
			r = t
			k = k + 1
		return r
	int mid = lo + (hi - lo) / 2
	bigint* left = bigint_product_range(lo, mid)
	bigint* right = bigint_product_range(mid + 1, hi)
	bigint* p = bigint_mul(left, right)
	bigint_free(left)
	bigint_free(right)
	return p


# n! for n >= 0; null for negative n.
bigint* bigint_factorial(int n):
	if (n < 0): return 0
	if (n < 2): return bigint_from_int(1)
	return bigint_product_range(2, n)


# ---- shifts -----------------------------------------------------------------

# a << k (a * 2^k); null for k < 0.
bigint* bigint_shl(bigint* a, int k):
	if (k < 0): return 0
	if (a.sign == 0): return bigint_zero()
	int q = k / BIGINT_LIMB_BITS
	int s = k % BIGINT_LIMB_BITS
	int* l = bigint_limbs_alloc(a.n + q + 1)
	int i = 0
	while (i < a.n):
		int v = a.limbs[i] << s
		l[i + q] = l[i + q] | (v & BIGINT_MASK)
		l[i + q + 1] = v >> BIGINT_LIMB_BITS
		i = i + 1
	return bigint_make(l, a.n + q + 1, a.sign)


# |a| >> k as a non-negative value.
bigint* bigint_mag_shr(bigint* a, int k):
	int q = k / BIGINT_LIMB_BITS
	int s = k % BIGINT_LIMB_BITS
	if (q >= a.n): return bigint_zero()
	int rn = a.n - q
	int* l = bigint_limbs_alloc(rn)
	int i = 0
	while (i < rn):
		int v = a.limbs[i + q] >> s
		if (i + q + 1 < a.n): v = v | ((a.limbs[i + q + 1] << (BIGINT_LIMB_BITS - s)) & BIGINT_MASK)
		l[i] = v
		i = i + 1
	return bigint_make(l, rn, 1)


# a >> k, rounding toward negative infinity like Python; null for k < 0.
bigint* bigint_shr(bigint* a, int k):
	if (k < 0): return 0
	if (a.sign >= 0): return bigint_mag_shr(a, k)
	# floor(-m / 2^k) == -(((m - 1) >> k) + 1)
	bigint* m1 = bigint_neg(a)
	bigint* t = bigint_add_int(m1, 0 - 1)
	bigint* sh = bigint_mag_shr(t, k)
	bigint* r = bigint_add_int(sh, 1)
	r.sign = 0 - r.sign
	bigint_free(m1)
	bigint_free(t)
	bigint_free(sh)
	return r


# ---- bitwise (infinite two's complement, like Python) -----------------------

# a in two's complement over len limbs (len > a.n, so the top limb holds
# only sign bits).
int* bigint_twos(bigint* a, int len):
	int* t = bigint_limbs_alloc(len)
	mem_copy(t, a.limbs, a.n)
	if (a.sign < 0):
		# ~(|a| - 1)
		int i = 0
		while (t[i] == 0):
			t[i] = BIGINT_MASK
			i = i + 1
		t[i] = t[i] - 1
		i = 0
		while (i < len):
			t[i] = (~t[i]) & BIGINT_MASK
			i = i + 1
	return t


# op: 0 = and, 1 = or, 2 = xor.
bigint* bigint_bitop(bigint* a, bigint* b, int op):
	int len = a.n
	if (b.n > len): len = b.n
	len = len + 1
	int* ta = bigint_twos(a, len)
	int* tb = bigint_twos(b, len)
	int i = 0
	while (i < len):
		if (op == 0): ta[i] = ta[i] & tb[i]
		else if (op == 1): ta[i] = ta[i] | tb[i]
		else: ta[i] = ta[i] ^ tb[i]
		i = i + 1
	free(cast(char*, tb))
	if ((ta[len - 1] & 16384) == 0): return bigint_make(ta, len, 1)
	# Negative: magnitude = ~t + 1.
	i = 0
	while (i < len):
		ta[i] = (~ta[i]) & BIGINT_MASK
		i = i + 1
	int carry = 1
	i = 0
	while ((carry != 0) && (i < len)):
		int v = ta[i] + carry
		ta[i] = v & BIGINT_MASK
		carry = v >> BIGINT_LIMB_BITS
		i = i + 1
	return bigint_make(ta, len, 0 - 1)


bigint* bigint_and(bigint* a, bigint* b):
	return bigint_bitop(a, b, 0)


bigint* bigint_or(bigint* a, bigint* b):
	return bigint_bitop(a, b, 1)


bigint* bigint_xor(bigint* a, bigint* b):
	return bigint_bitop(a, b, 2)


# ~a == -a - 1.
bigint* bigint_not(bigint* a):
	bigint* n = bigint_neg(a)
	bigint* r = bigint_add_int(n, 0 - 1)
	bigint_free(n)
	return r


# ---- parsing ----------------------------------------------------------------

int bigint_digit_value(char c):
	if ((c >= '0') && (c <= '9')): return c - '0'
	if ((c >= 'a') && (c <= 'z')): return c - 'a' + 10
	if ((c >= 'A') && (c <= 'Z')): return c - 'A' + 10
	return 99


int bigint_is_space(char c):
	return (c == ' ') || (c == 9) || (c == 10) || (c == 11) || (c == 12) || (c == 13)


# Largest k with base^k <= bigint_chunk_limit(); *power gets base^k.
int bigint_chunk_digits(int base, int* power):
	int limit = bigint_chunk_limit()
	int p = base
	int k = 1
	while (p <= limit / base):
		p = p * base
		k = k + 1
	*power = p
	return k


# Python int(s, base): base 0 auto-detects 0x/0o/0b prefixes (and then
# rejects other leading zeros), bases 2..36 accept their digits (and, for
# 16/8/2, the matching prefix). Surrounding ASCII whitespace, one leading
# sign and single underscores between digits (or right after a prefix) are
# allowed. Returns null on any syntax error or an unsupported base.
bigint* bigint_parse(char* s, int base):
	if ((base != 0) && ((base < 2) || (base > 36))): return 0
	int end = strlen(s)
	int i = 0
	while ((i < end) && (bigint_is_space(s[i]) != 0)): i = i + 1
	while ((end > i) && (bigint_is_space(s[end - 1]) != 0)): end = end - 1
	int sign = 1
	if ((i < end) && ((s[i] == '+') || (s[i] == '-'))):
		if (s[i] == '-'): sign = 0 - 1
		i = i + 1
	int prefixed = 0
	if ((i + 1 < end) && (s[i] == '0')):
		char pc = s[i + 1]
		int pb = 0
		if ((pc == 'x') || (pc == 'X')): pb = 16
		if ((pc == 'o') || (pc == 'O')): pb = 8
		if ((pc == 'b') || (pc == 'B')): pb = 2
		if ((pb != 0) && ((base == 0) || (base == pb))):
			base = pb
			i = i + 2
			prefixed = 1
	int auto_decimal = 0
	if (base == 0):
		base = 10
		auto_decimal = 1
	int* digits = cast(int*, malloc((end - i + 1) * __word_size__))
	int count = 0
	int prev_underscore = 0
	int ok = 1
	while ((i < end) && (ok != 0)):
		char c = s[i]
		if (c == '_'):
			if ((prev_underscore != 0) || ((count == 0) && (prefixed == 0))): ok = 0
			prev_underscore = 1
		else:
			int v = bigint_digit_value(c)
			if (v >= base): ok = 0
			digits[count] = v
			count = count + 1
			prev_underscore = 0
		i = i + 1
	if ((prev_underscore != 0) || (count == 0)): ok = 0
	if ((ok != 0) && (auto_decimal != 0) && (digits[0] == 0)):
		# Python rejects "012" under base 0; all-zero strings are fine.
		int z = 0
		while (z < count):
			if (digits[z] != 0): ok = 0
			z = z + 1
	if (ok == 0):
		free(cast(char*, digits))
		return 0
	int power = 0
	int k = bigint_chunk_digits(base, &power)
	# Bits needed <= count * 6 (base <= 36 < 2^6).
	int cap = (count * 6) / BIGINT_LIMB_BITS + 2
	int* l = bigint_limbs_alloc(cap)
	int n = 0
	int pos = 0
	int first = count % k
	if (first == 0): first = k
	while (pos < count):
		int len = k
		if (pos == 0): len = first
		int mul = 1
		int val = 0
		int j = 0
		while (j < len):
			val = val * base + digits[pos + j]
			mul = mul * base
			j = j + 1
		n = bigint_mag_mul_small_add(l, n, mul, val)
		pos = pos + len
	free(cast(char*, digits))
	return bigint_make(l, n, sign)


# Decimal shorthand for bigint_parse(s, 10).
bigint* bigint_from_string(char* s):
	return bigint_parse(s, 10)


# ---- formatting -------------------------------------------------------------

# a in base 2..36 with lowercase digits, a leading '-' when negative and
# the given prefix (may be c"") between sign and digits. Null for a bad base.
char* bigint_format(bigint* a, int base, char* prefix):
	if ((base < 2) || (base > 36)): return 0
	int plen = strlen(prefix)
	int power = 0
	int k = bigint_chunk_digits(base, &power)
	int n = a.n
	int* work = bigint_limbs_alloc(n)
	mem_copy(work, a.limbs, n)
	# Chunks, least significant first; at most 15 digits per limb.
	int* chunks = cast(int*, malloc(((n * BIGINT_LIMB_BITS) / k + 2) * __word_size__))
	int c = 0
	while (n > 0):
		chunks[c] = bigint_mag_divmod_small(work, work, n, power)
		n = bigint_mag_trim(work, n)
		c = c + 1
	free(cast(char*, work))
	if (c == 0):
		chunks[0] = 0
		c = 1
	char* out = cast(char*, malloc(c * k + plen + 3))
	int o = 0
	if (a.sign < 0):
		out[o] = '-'
		o = o + 1
	int pi = 0
	while (pi < plen):
		out[o] = prefix[pi]
		o = o + 1
		pi = pi + 1
	char* digitchars = c"0123456789abcdefghijklmnopqrstuvwxyz"
	# Top chunk without leading zeros (zero itself prints as one digit).
	int v = chunks[c - 1]
	int t = 1
	int probe = v / base
	while (probe > 0):
		t = t + 1
		probe = probe / base
	int d0 = t - 1
	while (d0 >= 0):
		out[o + d0] = digitchars[v % base]
		v = v / base
		d0 = d0 - 1
	o = o + t
	int ci = c - 2
	while (ci >= 0):
		int w = chunks[ci]
		int d = k - 1
		while (d >= 0):
			out[o + d] = digitchars[w % base]
			w = w / base
			d = d - 1
		o = o + k
		ci = ci - 1
	out[o] = 0
	free(cast(char*, chunks))
	return out


# Decimal string, like Python str(a).
char* bigint_to_string(bigint* a):
	return bigint_format(a, 10, c"")


# Digits in base 2..36 without prefix, like Python's format/numpy base_repr.
char* bigint_to_string_base(bigint* a, int base):
	return bigint_format(a, base, c"")


# Python hex(a): "0x1f", "-0x1f".
char* bigint_to_hex(bigint* a):
	return bigint_format(a, 16, c"0x")


# Python oct(a): "0o17".
char* bigint_to_oct(bigint* a):
	return bigint_format(a, 8, c"0o")


# Python bin(a): "0b101".
char* bigint_to_bin(bigint* a):
	return bigint_format(a, 2, c"0b")


# ---- bytes (big-endian, unsigned) -------------------------------------------

# Python int.from_bytes(b, "big").
bigint* bigint_from_bytes_be(char* data, int len):
	int* l = bigint_limbs_alloc((len * 8) / BIGINT_LIMB_BITS + 2)
	int n = 0
	int i = 0
	while (i < len):
		n = bigint_mag_mul_small_add(l, n, 256, data[i] & 255)
		i = i + 1
	return bigint_make(l, n, 1)


# Python a.to_bytes(len, "big") for a >= 0: writes exactly len bytes (zero
# padded). Returns 1, or 0 (writing nothing) when a is negative or does not
# fit in len bytes.
int bigint_to_bytes_be(bigint* a, char* out, int len):
	if ((a.sign < 0) || (bigint_bit_length(a) > len * 8)): return 0
	int i = 0
	while (i < len):
		int bit = (len - 1 - i) * 8
		int v = 0
		int k = 0
		while (k < 8):
			v = v | (bigint_mag_bit(a, bit + k) << k)
			k = k + 1
		out[i] = v
		i = i + 1
	return 1
