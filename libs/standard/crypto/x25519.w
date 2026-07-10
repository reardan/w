/*
X25519 (RFC 7748) Diffie-Hellman scalar multiplication, pure W.

Part of the native HTTPS stack (libs/standard/plans/11_native_http_tls.md,
phase 5): the TLS 1.3 key exchange. Public surface:

  void x25519_clamp(char* k)                             clamp a 32-byte scalar
  int  x25519_scalarmult(char* out, char* k, char* u)    out = X25519(k, u)
  int  x25519_scalarmult_base(char* out, char* k)        out = X25519(k, 9)

All buffers are caller-owned 32-byte arrays. The scalar is clamped on a
local copy inside scalarmult (per RFC 7748 decodeScalarX25519), so callers
pass raw private-key bytes; x25519_clamp is exposed for callers that store
clamped keys. Both scalarmult entry points return 0 on success and -1 when
the result is the all-zero value, which happens exactly when the peer sent
a low-order point (RFC 7748 section 6.1 check); the check is a constant-
time OR-fold over the output bytes.

Field representation (the 32-bit portability rule from plan 11: no int64
anywhere, every intermediate must fit a signed 32-bit int):

  An element of GF(2^255-19) is 20 signed limbs h[0..19] in base 2^13,
  value = sum(h[k] * 2^(13k)), kept loosely reduced modulo p = 2^255-19.
  20 limbs span 2^260, and 2^260 = 2^5 * 2^255 == 32*19 = 608 (mod p), so
  a carry out of limb 19 folds back into limb 0 multiplied by 608.

  Limb-bound invariant: every field element "at rest" (i.e. an output of
  any x25519_fe_* operation) has |h[k]| <= 9407.

  Why nothing overflows 32 bits (the load-bearing bound):
  - Schoolbook multiplication accumulates 39 columns; a column is a sum of
    at most 20 products of two limbs, so |column| <= 20 * 9407^2
    = 1,769,832,980 < 2^31 - 1 = 2,147,483,647.
  - Carry propagation adds a carry of at most |column|/2^13 + 1 < 2^18
    before splitting, still < 2^31.
  - The 608-fold after carrying works on limbs already reduced to
    [0, 8191], so 8191 + 608*8191 < 2^23; only the very top carry term
    reaches 8191 + 608*216102 < 2^28.
  - Addition/subtraction of two at-rest elements stays within
    |h[k]| <= 2*9407 = 18814, then one carry pass restores the invariant:
    limbs land in [0, 8191] and the 608-fold leaves limb 0 in
    [-1824, 9407] (final carry in [-3, 2], 8191 + 608*2 = 9407).
  - Multiplication output gets two carry passes, landing in [-608, 8799].
  - The a24 = 121665 scaling gives |h[k]| <= 9407 * 121665
    = 1,144,502,655 < 2^31, then two carry passes.

  Limbs can be negative (subtraction carries no bias); this is sound
  because W's >> is an arithmetic shift, so carry = v >> 13 floors toward
  minus infinity and v & 8191 is the matching non-negative remainder:
  v == (v >> 13) * 8192 + (v & 8191) for any v.

Constant-time discipline: the Montgomery ladder always runs 255 steps,
the conditional swap is xor/mask arithmetic, the exponent driving the
inversion is the public constant p-2, and the final freeze uses masked
selects. No branch or memory index depends on secret data.

Not thread-safe concerns: none; all state is local (malloc/free per call).
*/
import lib.memory


# --- field element helpers -------------------------------------------------

int* x25519_fe_new():
	int* h = cast(int*, malloc(20 * __word_size__))
	int k = 0
	while (k < 20):
		h[k] = 0
		k = k + 1
	return h


void x25519_fe_copy(int* out, int* a):
	int k = 0
	while (k < 20):
		out[k] = a[k]
		k = k + 1


# One carry pass: reduce every limb to [0, 8191], then fold the carry out
# of limb 19 (units of 2^260 == 608 mod p) back into limb 0.
# Precondition |h[k]| < 2^31 - 2^18 so v = h[k] + carry cannot overflow.
void x25519_fe_carry(int* h):
	int carry = 0
	int k = 0
	while (k < 20):
		int v = h[k] + carry
		h[k] = v & 8191
		carry = v >> 13
		k = k + 1
	h[0] = h[0] + 608 * carry


# out = a + b followed by one carry pass. Inputs at rest (|limb| <= 9407)
# give |a[k] + b[k]| <= 18814, and the carry pass returns to the at-rest
# bound (see the module header).
void x25519_fe_add(int* out, int* a, int* b):
	int k = 0
	while (k < 20):
		out[k] = a[k] + b[k]
		k = k + 1
	x25519_fe_carry(out)


void x25519_fe_sub(int* out, int* a, int* b):
	int k = 0
	while (k < 20):
		out[k] = a[k] - b[k]
		k = k + 1
	x25519_fe_carry(out)


# Reduce 39 raw schoolbook columns t[0..38] (|t[k]| <= 20*9407^2 < 2^31)
# into 20 at-rest limbs in out. First a carry pass turns the columns into
# base-2^13 digits in [0, 8191] plus a final carry (digit 39, |.| <=
# 216102); then digits 20..38 and that carry fold down by 608 (2^260 == 608
# mod p, so digit 20+j folds onto digit j and digit 39 onto digit 19); two
# more carry passes restore the at-rest bound.
void x25519_fe_reduce(int* out, int* t):
	int carry = 0
	int k = 0
	while (k < 39):
		int v = t[k] + carry
		t[k] = v & 8191
		carry = v >> 13
		k = k + 1
	k = 0
	while (k < 19):
		out[k] = t[k] + 608 * t[k + 20]
		k = k + 1
	out[19] = t[19] + 608 * carry
	x25519_fe_carry(out)
	x25519_fe_carry(out)


# out = a * b mod p. Schoolbook 20x20: every product |a[i]*b[j]| <= 9407^2
# and a column sums at most 20 of them, so every prefix of the column
# accumulation stays below 20 * 9407^2 = 1,769,832,980 < 2^31. Products go
# through a scratch buffer, so out may alias a or b.
void x25519_fe_mul(int* out, int* a, int* b):
	int* t = cast(int*, malloc(39 * __word_size__))
	int k = 0
	while (k < 39):
		t[k] = 0
		k = k + 1
	int i = 0
	while (i < 20):
		int ai = a[i]
		int j = 0
		while (j < 20):
			t[i + j] = t[i + j] + ai * b[j]
			j = j + 1
		i = i + 1
	x25519_fe_reduce(out, t)
	free(t)


# out = a^2 mod p. Same column bound as x25519_fe_mul: the doubled cross
# terms 2*a[i]*a[j] (i < j) plus the squares contribute exactly the same
# total magnitude per column, <= 20 * 9407^2 < 2^31; the individual term
# 2 * (a[i] * a[j]) <= 2 * 9407^2 < 2^28 also fits.
void x25519_fe_sq(int* out, int* a):
	int* t = cast(int*, malloc(39 * __word_size__))
	int k = 0
	while (k < 39):
		t[k] = 0
		k = k + 1
	int i = 0
	while (i < 20):
		int ai = a[i]
		t[i + i] = t[i + i] + ai * ai
		int j = i + 1
		while (j < 20):
			t[i + j] = t[i + j] + 2 * (ai * a[j])
			j = j + 1
		i = i + 1
	x25519_fe_reduce(out, t)
	free(t)


# out = a * 121665 (the Montgomery a24 constant). |a[k]| * 121665 <=
# 9407 * 121665 = 1,144,502,655 < 2^31; two carry passes restore the
# at-rest bound.
void x25519_fe_mul121665(int* out, int* a):
	int k = 0
	while (k < 20):
		out[k] = a[k] * 121665
		k = k + 1
	x25519_fe_carry(out)
	x25519_fe_carry(out)


# Constant-time conditional swap: b must be 0 or 1. mask is 0 or all ones;
# the xor trick swaps every limb bit-for-bit when the mask is set and is a
# no-op otherwise, with no data-dependent branch.
void x25519_fe_cswap(int* f, int* g, int b):
	int mask = 0 - b
	int k = 0
	while (k < 20):
		int x = mask & (f[k] ^ g[k])
		f[k] = f[k] ^ x
		g[k] = g[k] ^ x
		k = k + 1


# Load a little-endian 32-byte u-coordinate. Bit 255 is masked off, as
# RFC 7748 section 5 requires for X25519 inputs. Limbs land in [0, 8191].
void x25519_fe_frombytes(int* h, char* s):
	int k = 0
	while (k < 20):
		h[k] = 0
		k = k + 1
	int bit = 0
	while (bit < 255):
		int v = ((s[bit >> 3] & 255) >> (bit & 7)) & 1
		int q = bit / 13
		h[q] = h[q] | (v << (bit - q * 13))
		bit = bit + 1


# Fill pd with the base-2^13 digits of p = 2^255 - 19: adding 19 to
# [8173, 8191 x 18, 255] carries through to exactly 2^8 * 2^247 = 2^255.
void x25519_fe_p_digits(int* pd):
	pd[0] = 8173
	int k = 1
	while (k < 19):
		pd[k] = 8191
		k = k + 1
	pd[19] = 255


# Freeze h to its canonical representative in [0, p) and store it as 32
# little-endian bytes. Steps, with h at rest on entry:
#  1. carry pass: limbs 1..19 in [0, 8191], limb 0 in [-608, 8799].
#  2. fold bits 255+ of limb 19 (2^255 == 19 mod p): limb 0 <= 8799 + 19*31
#     = 9388.
#  3. add p once so the value is strictly positive (the value was
#     > -2^14 > -p), now in (0, 3p).
#  4. plain carry pass (all limbs non-negative, no top carry possible
#     since the value < 3p < 2^257 and limb 19 holds bits 247+).
#  5. conditionally subtract p twice with a masked select (borrow out of
#     the top limb decides, no branch), landing in [0, p).
#  6. emit bits 0..254 (bit 255 of a canonical value is always 0).
void x25519_fe_tobytes(char* s, int* h):
	x25519_fe_carry(h)
	int hi = h[19] >> 8
	h[19] = h[19] & 255
	h[0] = h[0] + 19 * hi

	int* pd = cast(int*, malloc(20 * __word_size__))
	x25519_fe_p_digits(pd)
	int k = 0
	while (k < 20):
		h[k] = h[k] + pd[k]
		k = k + 1
	int carry = 0
	k = 0
	while (k < 20):
		int v = h[k] + carry
		h[k] = v & 8191
		carry = v >> 13
		k = k + 1

	# Two constant-time conditional subtractions of p.
	int* m = cast(int*, malloc(20 * __word_size__))
	int rep = 0
	while (rep < 2):
		int borrow = 0
		k = 0
		while (k < 20):
			int v = h[k] - pd[k] - borrow
			m[k] = v & 8191
			borrow = (v >> 13) & 1
			k = k + 1
		# borrow == 1 means h < p: keep h. mask = 0 in that case, all
		# ones when the subtraction did not underflow.
		int mask = borrow - 1
		k = 0
		while (k < 20):
			int x = mask & (h[k] ^ m[k])
			h[k] = h[k] ^ x
			k = k + 1
		rep = rep + 1
	free(m)
	free(pd)

	k = 0
	while (k < 32):
		s[k] = 0
		k = k + 1
	int bit = 0
	while (bit < 255):
		int q = bit / 13
		int v = (h[q] >> (bit - q * 13)) & 1
		s[bit >> 3] = s[bit >> 3] | (v << (bit & 7))
		bit = bit + 1


# out = z^(p-2) = z^-1 mod p (Fermat). p-2 = 2^255 - 21 has every bit of
# 0..254 set except bits 2 and 4, so square-and-multiply from bit 253 down
# takes the multiply on all but those two. The exponent is a public
# constant, so this branch pattern is fixed and leaks nothing.
void x25519_fe_invert(int* out, int* z):
	int* c = x25519_fe_new()
	x25519_fe_copy(c, z)
	int i = 253
	while (i >= 0):
		x25519_fe_sq(c, c)
		if ((i != 2) & (i != 4)):
			x25519_fe_mul(c, c, z)
		i = i - 1
	x25519_fe_copy(out, c)
	free(c)


# --- public API ------------------------------------------------------------

# Clamp a 32-byte X25519 scalar in place (RFC 7748 decodeScalarX25519):
# clear the low 3 bits, clear the top bit, set bit 254.
void x25519_clamp(char* k):
	k[0] = k[0] & 248
	k[31] = (k[31] & 127) | 64


# out = X25519(scalar, point): the u-coordinate of scalar * P where P has
# u-coordinate `point`. All three are 32-byte buffers; scalar is clamped
# on an internal copy. Montgomery ladder per RFC 7748 section 5: exactly
# 255 iterations, swaps done with x25519_fe_cswap, no secret-dependent
# branches. Returns 0 on success, -1 when the output is all zero (low-
# order input point); the zero check ORs the output bytes, constant-time.
int x25519_scalarmult(char* out, char* scalar, char* point):
	char* e = malloc(32)
	int i = 0
	while (i < 32):
		e[i] = scalar[i]
		i = i + 1
	x25519_clamp(e)

	int* x1 = x25519_fe_new()
	x25519_fe_frombytes(x1, point)
	int* x2 = x25519_fe_new()
	x2[0] = 1
	int* z2 = x25519_fe_new()
	int* x3 = x25519_fe_new()
	x25519_fe_copy(x3, x1)
	int* z3 = x25519_fe_new()
	z3[0] = 1

	int* a = x25519_fe_new()
	int* aa = x25519_fe_new()
	int* b = x25519_fe_new()
	int* bb = x25519_fe_new()
	int* ed = x25519_fe_new()
	int* c = x25519_fe_new()
	int* d = x25519_fe_new()
	int* da = x25519_fe_new()
	int* cb = x25519_fe_new()
	int* t = x25519_fe_new()

	int swap = 0
	int pos = 254
	while (pos >= 0):
		int bit = ((e[pos >> 3] & 255) >> (pos & 7)) & 1
		swap = swap ^ bit
		x25519_fe_cswap(x2, x3, swap)
		x25519_fe_cswap(z2, z3, swap)
		swap = bit

		x25519_fe_add(a, x2, z2)
		x25519_fe_sq(aa, a)
		x25519_fe_sub(b, x2, z2)
		x25519_fe_sq(bb, b)
		x25519_fe_sub(ed, aa, bb)
		x25519_fe_add(c, x3, z3)
		x25519_fe_sub(d, x3, z3)
		x25519_fe_mul(da, d, a)
		x25519_fe_mul(cb, c, b)
		x25519_fe_add(t, da, cb)
		x25519_fe_sq(x3, t)
		x25519_fe_sub(t, da, cb)
		x25519_fe_sq(t, t)
		x25519_fe_mul(z3, x1, t)
		x25519_fe_mul(x2, aa, bb)
		x25519_fe_mul121665(t, ed)
		x25519_fe_add(t, aa, t)
		x25519_fe_mul(z2, ed, t)
		pos = pos - 1
	x25519_fe_cswap(x2, x3, swap)
	x25519_fe_cswap(z2, z3, swap)

	x25519_fe_invert(z2, z2)
	x25519_fe_mul(x2, x2, z2)
	x25519_fe_tobytes(out, x2)

	# Wipe the clamped private scalar before releasing it.
	i = 0
	while (i < 32):
		e[i] = 0
		i = i + 1
	free(e)
	free(x1)
	free(x2)
	free(z2)
	free(x3)
	free(z3)
	free(a)
	free(aa)
	free(b)
	free(bb)
	free(ed)
	free(c)
	free(d)
	free(da)
	free(cb)
	free(t)

	# Low-order point rejection: an all-zero shared secret is an error.
	int acc = 0
	i = 0
	while (i < 32):
		acc = acc | (out[i] & 255)
		i = i + 1
	if (acc == 0):
		return -1
	return 0


# out = X25519(scalar, 9): scalar multiplication of the curve base point,
# i.e. public-key generation. Same return convention as x25519_scalarmult
# (a clamped scalar can never yield zero here, so this returns 0).
int x25519_scalarmult_base(char* out, char* scalar):
	char* base = malloc(32)
	base[0] = 9
	int i = 1
	while (i < 32):
		base[i] = 0
		i = i + 1
	int result = x25519_scalarmult(out, scalar, base)
	free(base)
	return result
