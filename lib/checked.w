/*
Checked word arithmetic: overflow-reporting add/subtract/multiply,
unsigned comparison and shifts, range-checked narrowing, and allocation
size helpers (docs/projects/reliable_services.md, W2).

W's int is word-sized (32 bits on x86/win32, 64 bits on x64/arm64) and
its arithmetic wraps like the hardware; there is no wider type to
compute into on the 32-bit target. Every helper here therefore detects
overflow from the wrapped result itself (sign tests, a division
round-trip, or half-word decomposition), so the same source is correct
at both word sizes.

Calling convention: `int checked_X(..., int* out)` returns 1 and stores
the exact result in out[0], or returns 0 and stores 0 when the result
is not representable. out must be a valid pointer.

Signed helpers treat ints as numbers. The `_u` helpers treat ints as
UNSIGNED WORD BIT PATTERNS (a 32-bit target's -1 is 0xffffffff, a 64-bit
target's -1 is 2^64-1): the masked-word convention of lib/sha256.w,
widened to the full word.

Note: the built-in `uint` type does not make `<`/`>` unsigned today
(`uint a = cast(uint, -1); a > 1` is false on x86 and x64), so code that
needs an unsigned ordering must call unsigned_lt/unsigned_cmp below.
*/


# Bits in an int on this target (32 or 64).
int checked_word_bits():
	return __word_size__ * 8


# The most negative int: -2^31 or -2^63. Built from a shift, never a
# literal (a literal with bit 31 set sign-extends; see grammar/int_literal.w).
int checked_int_min():
	return 1 << (checked_word_bits() - 1)


int checked_int_max():
	return ~checked_int_min()


# 1 when x, read as an unsigned word, is less than y.
int unsigned_lt(int x, int y):
	int bias = checked_int_min()
	if ((x ^ bias) < (y ^ bias)): return 1
	return 0


int unsigned_le(int x, int y):
	if (unsigned_lt(y, x)): return 0
	return 1


# -1, 0 or 1 comparing x and y as unsigned words.
int unsigned_cmp(int x, int y):
	if (x == y): return 0
	if (unsigned_lt(x, y)): return 0 - 1
	return 1


# Logical right shift of the whole word (unlike the shr() intrinsic,
# which only sees the low 32 bits). k < 0 is treated as 0; k >= the word
# width yields 0.
int unsigned_shr(int x, int k):
	int bits = checked_word_bits()
	if (k <= 0): return x
	if (k >= bits): return 0
	return (x >> k) & ((1 << (bits - k)) - 1)


int checked_fail(int* out):
	out[0] = 0
	return 0


int checked_ok(int* out, int v):
	out[0] = v
	return 1


# ---- signed -----------------------------------------------------------------

int checked_add(int a, int b, int* out):
	int s = a + b
	# Overflow iff both operands share a sign the wrapped sum lacks.
	if (((a ^ s) & (b ^ s)) < 0): return checked_fail(out)
	return checked_ok(out, s)


int checked_sub(int a, int b, int* out):
	int d = a - b
	# Overflow iff the operands differ in sign and d's sign differs from a's.
	if (((a ^ b) & (a ^ d)) < 0): return checked_fail(out)
	return checked_ok(out, d)


int checked_mul(int a, int b, int* out):
	if ((a == 0) || (b == 0)): return checked_ok(out, 0)
	int min = checked_int_min()
	# The two cases where the division check below would itself trap.
	if (a == 0 - 1):
		if (b == min): return checked_fail(out)
		return checked_ok(out, 0 - b)
	if (b == 0 - 1):
		if (a == min): return checked_fail(out)
		return checked_ok(out, 0 - a)
	int p = a * b
	# A wrapped product differs from a*b by a multiple of 2^bits, which
	# truncating division by |a| <= 2^(bits-1) cannot hide.
	if ((p / a) != b): return checked_fail(out)
	return checked_ok(out, p)


int checked_neg(int a, int* out):
	if (a == checked_int_min()): return checked_fail(out)
	return checked_ok(out, 0 - a)


# ---- unsigned word ----------------------------------------------------------

int checked_add_u(int a, int b, int* out):
	int s = a + b
	if (unsigned_lt(s, a)): return checked_fail(out)
	return checked_ok(out, s)


int checked_sub_u(int a, int b, int* out):
	if (unsigned_lt(a, b)): return checked_fail(out)
	return checked_ok(out, a - b)


# Unsigned multiply via half words: a = a1*2^h + a0, b = b1*2^h + b0
# with h = bits/2. Every partial product is below 2^bits, so it never
# wraps, and the result fits iff a1*b1 == 0, the cross term fits h bits,
# and the final add does not carry.
int checked_mul_u(int a, int b, int* out):
	int h = checked_word_bits() / 2
	int half_mask = (1 << h) - 1
	int a1 = unsigned_shr(a, h)
	int a0 = a & half_mask
	int b1 = unsigned_shr(b, h)
	int b0 = b & half_mask
	if ((a1 != 0) && (b1 != 0)): return checked_fail(out)
	int cross = a1 * b0 + a0 * b1
	if (unsigned_shr(cross, h) != 0): return checked_fail(out)
	return checked_add_u(cross << h, a0 * b0, out)


# ---- narrowing --------------------------------------------------------------
#
# v is a signed number; each helper succeeds iff v lies in the named
# range, storing v unchanged. On the 32-bit target every int already fits
# int32, and u32 accepts exactly the non-negative ints (a negative int
# there is not a u32 *number*; masked-word bit patterns are not
# narrowing's business).

int checked_range(int v, int lo, int hi, int* out):
	if ((v < lo) || (v > hi)): return checked_fail(out)
	return checked_ok(out, v)


int checked_narrow_i32(int v, int* out):
	int spare = checked_word_bits() - 32
	if (((v << spare) >> spare) != v): return checked_fail(out)
	return checked_ok(out, v)


int checked_narrow_u32(int v, int* out):
	if (v < 0): return checked_fail(out)
	if (unsigned_shr(v, 31) > 1): return checked_fail(out)
	return checked_ok(out, v)


int checked_narrow_i16(int v, int* out):
	return checked_range(v, 0 - 32768, 32767, out)


int checked_narrow_u16(int v, int* out):
	return checked_range(v, 0, 65535, out)


int checked_narrow_i8(int v, int* out):
	return checked_range(v, 0 - 128, 127, out)


int checked_narrow_u8(int v, int* out):
	return checked_range(v, 0, 255, out)


# ---- allocation sizes -------------------------------------------------------

# count * elem_size as a non-negative int (an allocation byte count).
# Fails on a negative operand or on overflow.
int checked_size(int count, int elem_size, int* out):
	if ((count < 0) || (elem_size < 0)): return checked_fail(out)
	return checked_mul(count, elem_size, out)


# a + b as a non-negative int (header + payload, length + extra).
int checked_size_add(int a, int b, int* out):
	if ((a < 0) || (b < 0)): return checked_fail(out)
	return checked_add(a, b, out)
