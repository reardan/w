/*
libs/extras/protobuf/varint.w: proto3's base-128 varint plus the zigzag
transform for sint32/sint64 (docs/projects/protobuf.md §2, §6.1).

Host-word-size hazard this file is built around (CLAUDE.md's rules on
`int` being word-sized -- 32 bits on the default x86 target, 64 bits on
x64; README.md's Language snapshot: int64/uint64 are x64-only types):
the wire format defines a plain (non-zigzag) protobuf int32 field with a
negative value to sign-extend to a full 64 bits *before* varint encoding
-- specifically so int32 and int64 fields share one wire representation
-- which always costs exactly 10 bytes (never an early-exit
optimization; every real encoder emits all 10). On the 32-bit target
there is no native 64-bit register to hold that extension, and even on
x64, a value-dependent "shift until zero" loop cannot use the native
(arithmetic, sign-preserving) `>>` for a negative operand: it never
reaches zero, it saturates at -1 forever, with no way to tell "all 64
conceptual bits consumed" from "still inside the infinite sign
extension". So every function below that might need more than 32
significant bits represents the value as an explicit (lo, hi) pair of
32-bit halves, shifted only through the shr() intrinsic
(grammar/bit_builtin.w): shr is defined to operate on its operand's low
32 bits as unsigned and return a zero-extended result on every target
regardless of host word width (the same guarantee crc32.w's table-
doubling loop leans on) -- a true logical shift, so it reaches exactly
zero after a bounded number of steps even starting from an all-ones
pattern. That makes the core (lo, hi) codec below byte-identical machine
behavior on both targets: the 32-bit build simply never has a nonzero
"hi" half coming from its own native values.

Verified by hand for value = -1 (docs/projects/protobuf.md §2's "negative
int32 as 10-byte varint" case): the encode loop below produces
FF FF FF FF FF FF FF FF FF 01, the canonical protobuf encoding of a
64-bit-sign-extended -1, and the decode loop reconstructs
lo = hi = 0xFFFFFFFF from those bytes -- both cross-checked against the
"total significant bits = max(64 - 7*step, 0), split lo-then-hi" closed
form before being committed here (see tests/protobuf_test.w's varint
edge cases).
*/
import lib.memory


# All 32 bits set, built at runtime rather than as a literal token
# (mirrors libs/extras/compress/crc32.w's mask32() exactly -- see that
# file's header comment for why 0xffffffff can't appear as a literal:
# it sign-extends to -1 on every target, including x64, so `x &
# 0xffffffff` never truncates there). Wraps to -1 (all 32 bits, 32-bit
# target) or to the positive value 4294967295 (low 32 bits set, high
# bits clear, x64) -- the same bit pattern on both, which is all a
# bitwise AND/OR/XOR ever observes.
int varint_mask32():
	int h = 1 << 16
	return h * h - 1


# ---- core (lo, hi) 32-bit-pair codec ---------------------------------
#
# lo is the value's bits 0-31, hi its bits 32-63 (both already masked to
# exactly 32 bits by the caller -- hi = 0 for anything that fits in 32
# bits unsigned; hi = varint_mask32() for a negative 32-bit value's
# 64-bit sign extension; a genuine 64-bit value's own high word
# otherwise). This is the one primitive every wrapper below builds on.

# Encodes (hi:lo) as an unsigned base-128 varint, 7 payload bits per
# byte, continuation bit (0x80) set on every byte but the last. Returns
# bytes written (at most 10, protobuf's own defined maximum for a
# 64-bit quantity).
int varint_encode_parts(int lo, int hi, char* out):
	int mask = varint_mask32()
	int l = lo & mask
	int h = hi & mask
	int n = 0
	while (1):
		int b = l & 127
		# Shift the 64-bit (h:l) pair right by 7 as two 32-bit halves:
		# the low 7 bits vacated from h's bottom carry into l's top.
		int carry = (h & 127) << 25
		int next_l = (shr(l, 7) | carry) & mask
		int next_h = shr(h, 7) & mask
		l = next_l
		h = next_h
		if ((l == 0) && (h == 0)):
			out[n] = b
			return n + 1
		out[n] = b | 128
		n = n + 1


# Decodes a base-128 varint into its (lo, hi) 32-bit halves. Returns
# bytes consumed; -1 if the input ran out before a terminating byte
# (message.w's PB_ERR_TRUNCATED), or 0 if 10 bytes went by with no
# terminator -- exceeding the maximum a 64-bit value can ever need, since
# a well-formed encoder never emits an 11th continuation byte
# (message.w's PB_ERR_BAD_VARINT). Both are falsy/non-positive, so a
# caller that only wants "did this succeed" can still test `<= 0`; one
# that wants the distinction (message.w does) checks the sign.
int varint_decode_parts(char* data, int length, int* lo_out, int* hi_out):
	int lo = 0
	int hi = 0
	int shift = 0
	int i = 0
	while (1):
		if (i >= length):
			return -1
		if (i >= 10):
			return 0
		int b = data[i] & 255
		int payload = b & 127
		if (shift < 32):
			if ((shift + 7) <= 32):
				lo = lo | (payload << shift)
			else:
				# This group straddles bit 31 -- split it: the low
				# part finishes lo, the high part starts hi. Only the
				# shift=28 group can ever straddle (28+7=35 > 32,
				# 21+7=28 <= 32), since 7 does not divide 32.
				int low_bits = 32 - shift
				int low_mask = (1 << low_bits) - 1
				lo = lo | ((payload & low_mask) << shift)
				hi = hi | shr(payload, low_bits)
		else:
			hi = hi | (payload << (shift - 32))
		i = i + 1
		if ((b & 128) == 0):
			lo_out[0] = lo
			hi_out[0] = hi
			return i
		shift = shift + 7


# ---- word-sized convenience wrappers ---------------------------------

# Sign-extends a 32-bit bit pattern (already masked to the low 32 bits)
# to the full host word. A no-op on the 32-bit target (the register
# already IS the correctly-signed 32-bit value); on x64 it replicates
# bit 31 into bits 32-63 so the result is usable directly as a genuine
# signed `int` -- e.g. in a caller's `== -1` comparison -- rather than
# only becoming correct after a later truncating store into a narrower
# field (docs/projects/protobuf.md §2's explicit warning about trusting
# an un-sign-extended value that "arrived via a truncating store").
int sign_extend32(int lo32):
	if (__word_size__ == 4):
		return lo32
	if ((shr(lo32, 31) & 1) == 0):
		return lo32
	int mask = varint_mask32()
	int high = mask << 32
	return lo32 | high


# Unsigned 32-bit varint (uint32, bool, and the post-zigzag encoding of
# sint32/sint64): never sign-extends, always <= 5 bytes.
int varint_encode_u32(int value, char* out):
	return varint_encode_parts(value, 0, out)


int varint_decode_u32(char* data, int length, int* out):
	int lo = 0
	int hi = 0
	int n = varint_decode_parts(data, length, &lo, &hi)
	if (n <= 0):
		return n
	out[0] = lo & varint_mask32()
	return n


# Plain (non-zigzag) protobuf int32: non-negative values take the
# uint32 path; a negative value costs exactly 10 bytes, the 64-bit sign
# extension (docs/projects/protobuf.md §2 -- the well-known wire
# inefficiency that sint32 exists to avoid).
int varint_encode_i32(int value, char* out):
	int mask = varint_mask32()
	int lo = value & mask
	int hi = 0
	if (value < 0):
		hi = mask
	return varint_encode_parts(lo, hi, out)


# Decodes a plain int32 varint (1-10 bytes) back into a properly
# sign-extended host `int`. Only the low 32 bits of the decoded value
# are kept -- matching every real protobuf decoder's behavior when an
# int32 field receives the full 10-byte encoding, since the high bits
# are pure sign-extension padding for a value that already fits in 32
# bits.
int varint_decode_i32(char* data, int length, int* out):
	int lo = 0
	int hi = 0
	int n = varint_decode_parts(data, length, &lo, &hi)
	if (n <= 0):
		return n
	out[0] = sign_extend32(lo & varint_mask32())
	return n


# ---- zigzag (sint32) --------------------------------------------------

# (n << 1) ^ (n >> 31), computed through mask32()-bounded arithmetic so
# a wider (x64) host's extra high bits never leak into the shift/sign
# test (docs/projects/protobuf.md §2's zigzag formula, mirroring
# crc32.w's "build 32-bit values at runtime, mask explicitly"
# discipline).
int zigzag_encode32(int n):
	int mask = varint_mask32()
	int nn = n & mask
	int bit31 = shr(nn, 31) & 1
	int signmask = 0
	if (bit31 == 1):
		signmask = mask
	return ((nn << 1) & mask) ^ signmask


# (n >> 1) ^ -(n & 1); returns a properly sign-extended host `int` (see
# sign_extend32) so the result is directly usable as the signed value,
# not just correct bits for a later truncating store.
int zigzag_decode32(int n):
	int mask = varint_mask32()
	int nn = n & mask
	int odd = nn & 1
	int signmask = 0
	if (odd == 1):
		signmask = mask
	int result = (shr(nn, 1) ^ signmask) & mask
	return sign_extend32(result)


# ---- x64-only 64-bit wrappers ------------------------------------------
#
# int64/uint64 are x64-only types (README.md's Language snapshot), so
# these are only ever meaningfully called from x64-compiled programs --
# but they are written using only int32/uint32-width operations (never
# the `int64` type token), so this file itself compiles cleanly on the
# default 32-bit target too (matching docs/projects/protobuf.md §1.3's
# note on json_builtin.w/json_codec.w's own seed-vs-leaf split: nothing
# here needs to be arch-gated at the file level).

int zigzag_encode64_parts(int lo, int hi, int* out_lo, int* out_hi):
	int mask = varint_mask32()
	int l = lo & mask
	int h = hi & mask
	int sign = shr(h, 31) & 1
	int signmask = 0
	if (sign == 1):
		signmask = mask
	int new_lo = (l << 1) & mask
	int carry = shr(l, 31) & 1
	int new_hi = ((h << 1) | carry) & mask
	out_lo[0] = new_lo ^ signmask
	out_hi[0] = new_hi ^ signmask
	return 0


int zigzag_decode64_parts(int rlo, int rhi, int* out_lo, int* out_hi):
	# (z >> 1) ^ -(z & 1): shift FIRST, then XOR with the sign mask --
	# unlike encode (where shift-then-XOR and XOR-then-shift happen to
	# commute because the XOR only ever touches whole words), decode's
	# two steps do not commute, since XORing the un-shifted low bit
	# would land in the wrong position after the shift. Mirrors
	# zigzag_decode32's ordering exactly.
	int mask = varint_mask32()
	int odd = rlo & 1
	int signmask = 0
	if (odd == 1):
		signmask = mask
	int shifted_lo = (shr(rlo, 1) | ((rhi & 1) << 31)) & mask
	int shifted_hi = shr(rhi, 1) & mask
	out_lo[0] = shifted_lo ^ signmask
	out_hi[0] = shifted_hi ^ signmask
	return 0


# Word-sized convenience for genuinely x64-hosted 64-bit values (an
# int64/uint64 struct field read as one native `int`, which is 64 bits
# wide only on x64 -- see message.w's PB_KIND_INT64/UINT64/SINT64 for
# how a field's raw bytes are split into (lo, hi) without ever naming
# the int64 type).
int zigzag_encode64(int n):
	int lo = n & varint_mask32()
	# n >> 32 is a native (full host-width) arithmetic shift, only
	# meaningful when __word_size__ == 8 (the only case this is ever
	# called from a real x64 int64/uint64 field); shr(..., 0) then
	# truncates that to a clean, zero-extended low-32-bit pattern.
	int hi = shr(n >> 32, 0)
	int out_lo = 0
	int out_hi = 0
	zigzag_encode64_parts(lo, hi, &out_lo, &out_hi)
	return out_lo | (out_hi << 32)


int zigzag_decode64(int n):
	int lo = n & varint_mask32()
	int hi = shr(n >> 32, 0)
	int out_lo = 0
	int out_hi = 0
	zigzag_decode64_parts(lo, hi, &out_lo, &out_hi)
	int result = out_lo | (out_hi << 32)
	return result
