# Arbitrary-precision unsigned integers for public-key verification and the
# ECDSA server-signing path (RFC 6979). Part of the pure-W native HTTPS stack
# (issue #155, phase 6). No FFI, no int64.
#
# LIMB BASE: 2^15 (15 bits per limb), each limb stored in a signed 32-bit int
# holding a value in [0, 2^15 - 1]. The base is chosen so that schoolbook
# multiply-accumulate never overflows a signed 32-bit int:
#
#   In mul() the inner accumulator is  t = r + a_i*b_j + carry  where every
#   stored limb (r, a_i, b_j) is < L = 2^15 and, by induction, carry <= L-1:
#       t <= (L-1) + (L-1)^2 + (L-1) = (L-1)(L+1) = L^2 - 1 = 2^30 - 1
#   so t < 2^30 < 2^31 - 1 and carry_next = t >> 15 <= L-1 (induction holds).
#   Base 2^16 would give products up to (2^16-1)^2 ~ 2^32 which overflows a
#   signed int, so 2^15 is used for the headroom (documented per the plan's
#   "32-bit portability rule").
#
# All values are unsigned (non-negative). Every operation keeps limbs masked
# to 15 bits. Public-key verification handles no secrets and may be
# variable-time; the ECDSA signing helpers here are variable-time too (the
# constant-time discipline for the secret scalar lives in the elliptic-curve
# ladder in ecdsa_p256.w, which calls these).
import lib.memory


# ---- representation ---------------------------------------------------------

int BIGNUM_LIMB_BITS():
	return 15


int BIGNUM_LIMB_MASK():
	return 32767   # 2^15 - 1, low 15 bits


# Limb capacity. A base-2^15 limb holds 15 bits, so 560 limbs cover 8400 bits.
# The largest intermediate is the full-width product of two operands < modulus;
# for a 4096-bit modulus (274 limbs) that product is 548 limbs, which fits.
int BIGNUM_CAP():
	return 560


struct bignum:
	int n          # number of significant limbs (0 means the value zero)
	int* limbs     # BIGNUM_CAP() limbs, little-endian, each in [0, 2^15)


bignum* bignum_new():
	bignum* a = new bignum()
	a.n = 0
	a.limbs = cast(int*, malloc(BIGNUM_CAP() * __word_size__))
	int i = 0
	while (i < BIGNUM_CAP()):
		a.limbs[i] = 0
		i = i + 1
	return a


void bignum_free(bignum* a):
	free(cast(char*, a.limbs))
	free(cast(char*, a))


void bignum_set_zero(bignum* a):
	int i = 0
	while (i < a.n):
		a.limbs[i] = 0
		i = i + 1
	a.n = 0


# Drop leading zero limbs so n is the true significant-limb count.
void bignum_normalize(bignum* a):
	while ((a.n > 0) & (a.limbs[a.n - 1] == 0)):
		a.n = a.n - 1


int bignum_is_zero(bignum* a):
	bignum_normalize(a)
	if (a.n == 0):
		return 1
	return 0


void bignum_set_u32(bignum* a, int v):
	# v is treated as a non-negative value spread over three 15-bit limbs
	# (45 bits of room). Callers here only pass small constants.
	bignum_set_zero(a)
	int mask = BIGNUM_LIMB_MASK()
	a.limbs[0] = v & mask
	a.limbs[1] = (v >> 15) & mask
	a.limbs[2] = (v >> 30) & 3
	a.n = 3
	bignum_normalize(a)


void bignum_copy(bignum* dst, bignum* src):
	int i = 0
	while (i < src.n):
		dst.limbs[i] = src.limbs[i]
		i = i + 1
	while (i < dst.n):
		dst.limbs[i] = 0
		i = i + 1
	dst.n = src.n


# Constant-shape copy for the elliptic-curve ladder: copies exactly
# BIGNUM_CAP() limbs regardless of significant length, so the memory-access
# pattern does not depend on the source value.
void bignum_copy_full(bignum* dst, bignum* src):
	int i = 0
	while (i < BIGNUM_CAP()):
		dst.limbs[i] = src.limbs[i]
		i = i + 1
	dst.n = src.n


# Constant-time conditional copy: dst = bit ? src : dst. Touches every limb up
# to BIGNUM_CAP() so the access pattern is independent of the operand values;
# used by the elliptic-curve ladder's branch-free point select.
void bignum_cselect(int bit, bignum* dst, bignum* src):
	int mask = 0 - bit          # 0 if bit==0, all-ones if bit==1
	int notmask = ~mask
	int i = 0
	while (i < BIGNUM_CAP()):
		dst.limbs[i] = (dst.limbs[i] & notmask) | (src.limbs[i] & mask)
		i = i + 1
	dst.n = (dst.n & notmask) | (src.n & mask)


# ---- comparison -------------------------------------------------------------

# -1 if a<b, 0 if a==b, 1 if a>b (by magnitude).
int bignum_cmp(bignum* a, bignum* b):
	int na = a.n
	int nb = b.n
	while ((na > 0) & (a.limbs[na - 1] == 0)):
		na = na - 1
	while ((nb > 0) & (b.limbs[nb - 1] == 0)):
		nb = nb - 1
	if (na != nb):
		if (na < nb):
			return 0 - 1
		return 1
	int i = na - 1
	while (i >= 0):
		if (a.limbs[i] != b.limbs[i]):
			if (a.limbs[i] < b.limbs[i]):
				return 0 - 1
			return 1
		i = i - 1
	return 0


# ---- bit access -------------------------------------------------------------

int bignum_bit_length(bignum* a):
	int i = a.n - 1
	while ((i >= 0) & (a.limbs[i] == 0)):
		i = i - 1
	if (i < 0):
		return 0
	int limb = a.limbs[i]
	int bits = i * BIGNUM_LIMB_BITS()
	while (limb > 0):
		bits = bits + 1
		limb = limb >> 1
	return bits


int bignum_get_bit(bignum* a, int bit):
	int limb = bit / BIGNUM_LIMB_BITS()
	int off = bit % BIGNUM_LIMB_BITS()
	if (limb >= a.n):
		return 0
	return (a.limbs[limb] >> off) & 1


void bignum_set_bit(bignum* a, int bit):
	int limb = bit / BIGNUM_LIMB_BITS()
	int off = bit % BIGNUM_LIMB_BITS()
	a.limbs[limb] = a.limbs[limb] | (1 << off)
	if (limb + 1 > a.n):
		a.n = limb + 1


# a <<= 1 (multiply by two).
void bignum_shl1(bignum* a):
	int mask = BIGNUM_LIMB_MASK()
	int carry = 0
	int i = 0
	while (i < a.n):
		int v = (a.limbs[i] << 1) | carry
		a.limbs[i] = v & mask
		carry = (v >> 15) & 1
		i = i + 1
	if (carry != 0):
		a.limbs[a.n] = 1
		a.n = a.n + 1


# ---- add / sub --------------------------------------------------------------

# r = a + b. r may alias a or b.
void bignum_add(bignum* r, bignum* a, bignum* b):
	int mask = BIGNUM_LIMB_MASK()
	int n = a.n
	if (b.n > n):
		n = b.n
	int carry = 0
	int i = 0
	while (i < n):
		int av = 0
		if (i < a.n):
			av = a.limbs[i]
		int bv = 0
		if (i < b.n):
			bv = b.limbs[i]
		int t = av + bv + carry
		r.limbs[i] = t & mask
		carry = t >> 15
		i = i + 1
	if (carry != 0):
		r.limbs[n] = carry
		n = n + 1
	# Clear any stale high limbs if r aliased a larger operand.
	while (i < r.n):
		if (i >= n):
			r.limbs[i] = 0
		i = i + 1
	r.n = n
	bignum_normalize(r)


# a -= b, requires a >= b. Borrow-propagating subtraction in place.
void bignum_sub(bignum* a, bignum* b):
	int base = 1 << 15
	int borrow = 0
	int i = 0
	while (i < a.n):
		int bv = 0
		if (i < b.n):
			bv = b.limbs[i]
		int d = a.limbs[i] - bv - borrow
		if (d < 0):
			d = d + base
			borrow = 1
		else:
			borrow = 0
		a.limbs[i] = d
		i = i + 1
	bignum_normalize(a)


# Subtract a small non-negative int (fits in a couple of limbs) in place,
# requires a >= v.
void bignum_sub_small(bignum* a, int v):
	int base = 1 << 15
	int borrow = v
	int i = 0
	while ((borrow != 0) & (i < a.n)):
		int d = a.limbs[i] - (borrow & BIGNUM_LIMB_MASK())
		borrow = borrow >> 15
		if (d < 0):
			d = d + base
			borrow = borrow + 1
		a.limbs[i] = d
		i = i + 1
	bignum_normalize(a)


# ---- multiply ---------------------------------------------------------------

# r = a * b. r must be distinct from a and b.
void bignum_mul(bignum* r, bignum* a, bignum* b):
	int mask = BIGNUM_LIMB_MASK()
	int total = a.n + b.n
	int i = 0
	while (i < total):
		r.limbs[i] = 0
		i = i + 1
	# Clear stale high limbs above the product width.
	while (i < r.n):
		r.limbs[i] = 0
		i = i + 1
	i = 0
	while (i < a.n):
		int ai = a.limbs[i]
		int carry = 0
		int j = 0
		while (j < b.n):
			int t = r.limbs[i + j] + ai * b.limbs[j] + carry
			r.limbs[i + j] = t & mask
			carry = t >> 15
			j = j + 1
		r.limbs[i + b.n] = r.limbs[i + b.n] + carry
		i = i + 1
	r.n = total
	bignum_normalize(r)


# ---- divide / mod -----------------------------------------------------------

# q = a / m, r = a % m via bit-at-a-time long division. Requires m != 0.
# q and r must be distinct from a and m and from each other.
void bignum_divmod(bignum* a, bignum* m, bignum* q, bignum* r):
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


# r = a % m. r must be distinct from a and m.
void bignum_mod(bignum* r, bignum* a, bignum* m):
	bignum* qq = bignum_new()
	bignum_divmod(a, m, qq, r)
	bignum_free(qq)


# ---- modular arithmetic -----------------------------------------------------

# r = (a * b) % m. r must be distinct from m; a and b may alias each other.
void bignum_modmul(bignum* r, bignum* a, bignum* b, bignum* m):
	bignum* t = bignum_new()
	bignum* qq = bignum_new()
	bignum_mul(t, a, b)
	bignum_divmod(t, m, qq, r)
	bignum_free(t)
	bignum_free(qq)


# r = (a + b) % m, requires a < m and b < m. r must not alias m.
void bignum_addmod(bignum* r, bignum* a, bignum* b, bignum* m):
	bignum_add(r, a, b)
	if (bignum_cmp(r, m) >= 0):
		bignum_sub(r, m)


# r = (a - b) % m, requires a < m and b < m. r distinct from a, b, m.
void bignum_submod(bignum* r, bignum* a, bignum* b, bignum* m):
	if (bignum_cmp(a, b) >= 0):
		bignum_copy(r, a)
		bignum_sub(r, b)
	else:
		# r = a + m - b
		bignum_add(r, a, m)
		bignum_sub(r, b)


# r = (base ^ exp) % m via left-to-right square-and-multiply. Variable-time
# in the exponent; used only for public-key verification and for Fermat
# inverses over the (prime) P-256 field and group order.
void bignum_modexp(bignum* r, bignum* base, bignum* exp, bignum* m):
	bignum* result = bignum_new()
	bignum_set_u32(result, 1)
	bignum* b = bignum_new()
	bignum_mod(b, base, m)
	bignum* tmp = bignum_new()
	int nbits = bignum_bit_length(exp)
	int i = nbits - 1
	while (i >= 0):
		bignum_modmul(tmp, result, result, m)
		bignum_copy(result, tmp)
		if (bignum_get_bit(exp, i) != 0):
			bignum_modmul(tmp, result, b, m)
			bignum_copy(result, tmp)
		i = i - 1
	bignum_copy(r, result)
	bignum_free(result)
	bignum_free(b)
	bignum_free(tmp)


# r = a^(-1) mod m, computed as a^(m-2) mod m (Fermat's little theorem).
# REQUIRES m prime and gcd(a, m) = 1 -- true for the P-256 field prime and the
# group order, which is all this stack needs. r distinct from a and m.
void bignum_modinv(bignum* r, bignum* a, bignum* m):
	bignum* e = bignum_new()
	bignum_copy(e, m)
	bignum_sub_small(e, 2)
	bignum_modexp(r, a, e, m)
	bignum_free(e)


# ---- byte import / export (big-endian) --------------------------------------

# Load a big-endian byte string of length len into a (most significant first).
void bignum_from_bytes(bignum* a, char* bytes, int len):
	bignum_set_zero(a)
	int i = 0
	while (i < len):
		int bval = bytes[i] & 255
		# This byte's least significant bit sits at position (len-1-i)*8.
		int base_bit = (len - 1 - i) * 8
		int k = 0
		while (k < 8):
			if (((bval >> k) & 1) != 0):
				bignum_set_bit(a, base_bit + k)
			k = k + 1
		i = i + 1
	bignum_normalize(a)


# Write a as a big-endian byte string of exactly len bytes (zero padded on the
# left). Bits above len*8 are dropped.
void bignum_to_bytes(bignum* a, char* out, int len):
	int i = 0
	while (i < len):
		int base_bit = (len - 1 - i) * 8
		int bval = 0
		int k = 0
		while (k < 8):
			bval = bval | (bignum_get_bit(a, base_bit + k) << k)
			k = k + 1
		out[i] = bval
		i = i + 1


# Number of whole bytes needed to represent a (0 for zero).
int bignum_byte_length(bignum* a):
	int bits = bignum_bit_length(a)
	return (bits + 7) / 8
