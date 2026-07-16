/*
libs/extras/compress/crc32.w: CRC-32, RFC 1952 §8's reflected polynomial
(0xEDB88320) -- the variant used by zlib, gzip(1), PNG, and git, and the
checksum gzip.w's trailer needs (docs/projects/compress.md §5.1).

W-specific hazard (docs/projects/compress.md §6.1): 0xEDB88320 and the
all-ones mask 0xFFFFFFFF both have bit 31 set, so neither may appear as a
literal token (grammar/int_literal.w warns -- a hex/binary literal with
bit 31 set sign-extends to a negative int on the 32-bit target but not on
x64, so the same token means different things on the two word widths).
Both are built at runtime instead, mirroring lib/sha256.w's
sha256_mask32()/lib/rand.w's rand_mask32(): the polynomial from two
sub-2^31 16-bit halves shifted together, the mask via the "1<<16, square,
minus one" trick (wraps to -1 on a 32-bit host, to 0xffffffff-as-a-
positive-int on x64 -- both are the same bit pattern, which is all a
bitwise AND ever observes).

The 256-entry table is generated at process start from the polynomial via
the standard doubling algorithm (RFC 1952 §8's own suggested
implementation) rather than committed as a literal table -- unlike
lib/sha256.w's round constants, which are arbitrary and not derivable,
the CRC-32 table is a pure function of the one polynomial word. Built
once and cached (lib/x/unsafe/sha1.w's sha1_k_cache is the precedent for
this lazy-global-cache shape), never freed -- a process-lifetime table,
like every other cached constant table in this tree.

Every right shift goes through the shr() intrinsic (grammar/bit_builtin.w)
rather than W's native (arithmetic) >>, so no host sign bit smears into
the result on the 32-bit target.
*/
import lib.memory


# 0xFFFFFFFF, built without a literal token that has bit 31 set: identity
# on the 32-bit target (h*h wraps to 0, so h*h-1 is -1, i.e. every bit
# set), the same bit pattern as a non-negative int on x64.
int crc32_mask32():
	int h = 1 << 16
	return h * h - 1


# 0xEDB88320 assembled from two 16-bit halves, each well under 2^31 so
# neither literal trips the bit-31 warning; the shift/or is a runtime
# computation, not a literal token, so it is exempt (grammar/int_literal.w
# only inspects literal tokens).
int crc32_poly():
	int high = 0xedb8
	int low = 0x8320
	return ((high << 16) | low) & crc32_mask32()


int* crc32_table_cache


int* crc32_build_table():
	int* table = cast(int*, malloc(256 * __word_size__))
	int poly = crc32_poly()
	int mask = crc32_mask32()
	int n = 0
	while (n < 256):
		int word = n
		int k = 0
		while (k < 8):
			if ((word & 1) != 0):
				word = shr(word, 1) ^ poly
			else:
				word = shr(word, 1)
			k = k + 1
		table[n] = word & mask
		n = n + 1
	return table


int* crc32_table():
	if (crc32_table_cache == 0):
		crc32_table_cache = crc32_build_table()
	return crc32_table_cache


# Continues a checksum: crc=0 starts a fresh one (mirrors zlib's crc32()
# convention exactly -- crc32_update(0, data, len) is a one-shot digest,
# and crc32_update(crc32_update(0, a, na), b, nb) equals the digest of
# a+b concatenated). A negative length is treated as zero, matching
# libs/standard/crypto/base64.w's base64_encode convention.
int crc32_update(int crc, char* data, int length):
	if (length < 0):
		length = 0
	int* table = crc32_table()
	int mask = crc32_mask32()
	int c = crc ^ mask
	int i = 0
	while (i < length):
		int idx = (c ^ (data[i] & 255)) & 255
		c = shr(c, 8) ^ table[idx]
		i = i + 1
	return c ^ mask


int crc32_of(char* data, int length):
	return crc32_update(0, data, length)
