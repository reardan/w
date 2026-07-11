/*
Fixed-width unsigned 64-bit integers for distributed-protocol state
(docs/projects/distributed.md, phase 1).

Raft terms/log indexes and hybrid-logical-clock timestamps want 64 bits,
but W's int is word-sized: 32 bits on the x86 target, where save_int64
(code_generator/integer.w) can only sign-smear the top four bytes. This
module gives protocol code one u64 representation whose observable
behavior is identical on 32- and 64-bit targets.

LIMB BASE 2^16, following bignum.w's headroom rule (libs/standard/
crypto/bignum.w keeps 15-bit limbs so multiply-accumulate fits a signed
32-bit int; u64 never multiplies limbs, so 16-bit limbs leave add/sub
carries comfortably inside signed 32-bit arithmetic): w0..w3 little-
endian, each an int in [0, 0xffff]. No stored limb ever has bit 31 set,
so nothing here depends on the masked-32-bit-word convention
(lib/sha256.w) or on host shift semantics.

All values are unsigned. Operations mutate their first argument
(bignum.w style); u64_clone copies when the caller needs the old value.
The 32-bit accessors (u64_lo32/u64_hi32) and u64_set_parts speak the
masked-32-bit-word convention: only the low 32 bits of those ints carry
state, and on a 32-bit host a word with bit 31 set is stored negative.

The wire format is 8 little-endian bytes — byte-compatible with
save_int64 output on 64-bit hosts for values < 2^63.
*/
import lib.memory
import lib.assert


struct u64:
	int w0   # bits 0..15
	int w1   # bits 16..31
	int w2   # bits 32..47
	int w3   # bits 48..63


# ---- construction -----------------------------------------------------------

u64* u64_new():
	u64* a = new u64()
	a.w0 = 0
	a.w1 = 0
	a.w2 = 0
	a.w3 = 0
	return a


void u64_free(u64* a):
	free(a)


void u64_set_zero(u64* a):
	a.w0 = 0
	a.w1 = 0
	a.w2 = 0
	a.w3 = 0


# v must be non-negative, so every legal input means the same value on
# every target. On 64-bit hosts v may use up to 63 bits.
void u64_set_int(u64* a, int v):
	assert1(v >= 0)
	a.w0 = v & 65535
	a.w1 = (v >> 16) & 65535
	a.w2 = 0
	a.w3 = 0
	if (__word_size__ == 8):
		a.w2 = (v >> 32) & 65535
		a.w3 = (v >> 48) & 65535


# hi32/lo32 are masked 32-bit words: only their low 32 bits are read, so
# a negative int on a 32-bit host contributes its raw bit pattern.
void u64_set_parts(u64* a, int hi32, int lo32):
	a.w0 = lo32 & 65535
	a.w1 = (lo32 >> 16) & 65535
	a.w2 = hi32 & 65535
	a.w3 = (hi32 >> 16) & 65535


u64* u64_new_int(int v):
	u64* a = u64_new()
	u64_set_int(a, v)
	return a


u64* u64_new_parts(int hi32, int lo32):
	u64* a = u64_new()
	u64_set_parts(a, hi32, lo32)
	return a


void u64_copy(u64* dst, u64* src):
	dst.w0 = src.w0
	dst.w1 = src.w1
	dst.w2 = src.w2
	dst.w3 = src.w3


u64* u64_clone(u64* a):
	u64* b = u64_new()
	u64_copy(b, a)
	return b


# ---- accessors --------------------------------------------------------------

# Low/high 32 bits as a masked 32-bit word (may be stored negative on a
# 32-bit host when bit 31 of the word is set).
int u64_lo32(u64* a):
	return (a.w1 << 16) | a.w0


int u64_hi32(u64* a):
	return (a.w3 << 16) | a.w2


# 1 when the value is exactly representable as a non-negative int on
# every target (i.e. it fits 31 bits).
int u64_fits_int(u64* a):
	if (a.w3 != 0 || a.w2 != 0):
		return 0
	if (a.w1 >= 32768):
		return 0
	return 1


# The value as a host int; asserts u64_fits_int so the result is
# target-independent.
int u64_to_int(u64* a):
	assert1(u64_fits_int(a))
	return (a.w1 << 16) | a.w0


# ---- comparison -------------------------------------------------------------

int u64_is_zero(u64* a):
	if (a.w0 == 0 && a.w1 == 0 && a.w2 == 0 && a.w3 == 0):
		return 1
	return 0


int u64_eq(u64* a, u64* b):
	if (a.w0 == b.w0 && a.w1 == b.w1 && a.w2 == b.w2 && a.w3 == b.w3):
		return 1
	return 0


# Unsigned compare: -1 when a < b, 0 when equal, 1 when a > b. Limbs are
# always in [0, 0xffff], so plain int comparison is correct everywhere.
int u64_cmp(u64* a, u64* b):
	if (a.w3 != b.w3):
		if (a.w3 < b.w3):
			return 0 - 1
		return 1
	if (a.w2 != b.w2):
		if (a.w2 < b.w2):
			return 0 - 1
		return 1
	if (a.w1 != b.w1):
		if (a.w1 < b.w1):
			return 0 - 1
		return 1
	if (a.w0 != b.w0):
		if (a.w0 < b.w0):
			return 0 - 1
		return 1
	return 0


# a = max(a, b), the merge step of logical clocks.
void u64_max(u64* a, u64* b):
	if (u64_cmp(a, b) < 0):
		u64_copy(a, b)


# ---- arithmetic (mod 2^64) --------------------------------------------------

void u64_add(u64* a, u64* b):
	int c = a.w0 + b.w0
	a.w0 = c & 65535
	c = (c >> 16) + a.w1 + b.w1
	a.w1 = c & 65535
	c = (c >> 16) + a.w2 + b.w2
	a.w2 = c & 65535
	c = (c >> 16) + a.w3 + b.w3
	a.w3 = c & 65535


# a += v for a small non-negative host int (v < 2^31 on every target).
void u64_add_int(u64* a, int v):
	assert1(v >= 0)
	if (__word_size__ == 8):
		assert1((v >> 31) == 0)
	int c = a.w0 + (v & 65535)
	a.w0 = c & 65535
	c = (c >> 16) + a.w1 + ((v >> 16) & 65535)
	a.w1 = c & 65535
	c = (c >> 16) + a.w2
	a.w2 = c & 65535
	c = (c >> 16) + a.w3
	a.w3 = c & 65535


void u64_inc(u64* a):
	u64_add_int(a, 1)


# a -= b (mod 2^64). Returns 1 when b > a (the subtraction borrowed),
# 0 otherwise.
int u64_sub(u64* a, u64* b):
	int d = a.w0 - b.w0
	a.w0 = d & 65535
	d = (d >> 16) + a.w1 - b.w1
	a.w1 = d & 65535
	d = (d >> 16) + a.w2 - b.w2
	a.w2 = d & 65535
	d = (d >> 16) + a.w3 - b.w3
	a.w3 = d & 65535
	if ((d >> 16) != 0):
		return 1
	return 0


# ---- shifts -----------------------------------------------------------------

# a <<= k. Shifts of 64 or more zero the value.
void u64_shl(u64* a, int k):
	assert1(k >= 0)
	if (k >= 64):
		u64_set_zero(a)
		return
	while (k >= 16):
		a.w3 = a.w2
		a.w2 = a.w1
		a.w1 = a.w0
		a.w0 = 0
		k = k - 16
	if (k > 0):
		int up = 16 - k
		a.w3 = ((a.w3 << k) | (a.w2 >> up)) & 65535
		a.w2 = ((a.w2 << k) | (a.w1 >> up)) & 65535
		a.w1 = ((a.w1 << k) | (a.w0 >> up)) & 65535
		a.w0 = (a.w0 << k) & 65535


# a >>= k (logical). Shifts of 64 or more zero the value.
void u64_shr(u64* a, int k):
	assert1(k >= 0)
	if (k >= 64):
		u64_set_zero(a)
		return
	while (k >= 16):
		a.w0 = a.w1
		a.w1 = a.w2
		a.w2 = a.w3
		a.w3 = 0
		k = k - 16
	if (k > 0):
		int up = 16 - k
		a.w0 = ((a.w1 << up) | (a.w0 >> k)) & 65535
		a.w1 = ((a.w2 << up) | (a.w1 >> k)) & 65535
		a.w2 = ((a.w3 << up) | (a.w2 >> k)) & 65535
		a.w3 = a.w3 >> k


# ---- wire format ------------------------------------------------------------

# 8 little-endian bytes.
void u64_save_le(char* p, u64* a):
	p[0] = a.w0
	p[1] = a.w0 >> 8
	p[2] = a.w1
	p[3] = a.w1 >> 8
	p[4] = a.w2
	p[5] = a.w2 >> 8
	p[6] = a.w3
	p[7] = a.w3 >> 8


void u64_load_le(u64* a, char* p):
	a.w0 = (p[0] & 255) | ((p[1] & 255) << 8)
	a.w1 = (p[2] & 255) | ((p[3] & 255) << 8)
	a.w2 = (p[4] & 255) | ((p[5] & 255) << 8)
	a.w3 = (p[6] & 255) | ((p[7] & 255) << 8)


# ---- formatting -------------------------------------------------------------

void u64_hex4(char* s, int off, int v):
	char* digits = c"0123456789abcdef"
	s[off] = digits[(v >> 12) & 15]
	s[off + 1] = digits[(v >> 8) & 15]
	s[off + 2] = digits[(v >> 4) & 15]
	s[off + 3] = digits[v & 15]


# 16 lowercase hex digits, malloc'd and NUL-terminated; caller frees.
char* u64_to_hex(u64* a):
	char* s = malloc(17)
	u64_hex4(s, 0, a.w3)
	u64_hex4(s, 4, a.w2)
	u64_hex4(s, 8, a.w1)
	u64_hex4(s, 12, a.w0)
	s[16] = 0
	return s


# Decimal string, malloc'd and NUL-terminated; caller frees. Repeated
# division by 10 across the limbs: the per-limb dividend is at most
# 9 * 65536 + 65535 < 2^20, so it fits a signed int on every target.
char* u64_to_dec(u64* a):
	char* tmp = malloc(21)
	int t3 = a.w3
	int t2 = a.w2
	int t1 = a.w1
	int t0 = a.w0
	int n = 0
	while (t3 != 0 || t2 != 0 || t1 != 0 || t0 != 0):
		int rem = 0
		int cur = rem * 65536 + t3
		t3 = cur / 10
		rem = cur - t3 * 10
		cur = rem * 65536 + t2
		t2 = cur / 10
		rem = cur - t2 * 10
		cur = rem * 65536 + t1
		t1 = cur / 10
		rem = cur - t1 * 10
		cur = rem * 65536 + t0
		t0 = cur / 10
		rem = cur - t0 * 10
		tmp[n] = 48 + rem
		n = n + 1
	if (n == 0):
		tmp[n] = 48
		n = n + 1
	char* s = malloc(n + 1)
	int i = 0
	while (i < n):
		s[i] = tmp[n - 1 - i]
		i = i + 1
	s[n] = 0
	free(tmp)
	return s
