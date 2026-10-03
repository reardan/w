# Fixed-width unsigned integers in byte buffers, big- and little-endian.
# Loads assemble unsigned bytes, so a 32-bit load follows the masked
# 32-bit-word convention (zero-extended on 64-bit targets, wrapping to
# negative on 32-bit ones); stores write the low bytes of v.
#
# 64-bit fields come in three forms (docs/projects/reliable_services.md, W2):
# - load/store_{be,le}64_parts: portable, every target. The value is a
#   (hi, lo) pair of masked 32-bit words, as libs/standard/distributed/
#   u64.w's u64_set_parts/u64_hi32/u64_lo32 speak.
# - load_{be,le}64_word: checked, every target. Fails (returns 0) when the
#   value does not fit the target word, i.e. on a 32-bit target whenever
#   the high 32 bits are nonzero. Use this (or lib.byte_buf's
#   byte_reader) for untrusted input.
# - load/store_{be,le}64: the native word. On 64-bit-int targets (x64,
#   arm64) the full 64-bit pattern (bit 63 set reads back negative, the
#   masked-word convention widened to 64 bits). On a 32-bit target a store
#   zero-extends v's 32-bit pattern, and a load whose high 32 bits are
#   nonzero aborts the process rather than silently truncating.
#
# bytes_compare/bytes_equal order raw byte strings (embedded NULs
# allowed) by unsigned lexicographic comparison.
import structures.string


int load_be16(char* p):
	return ((p[0] & 255) << 8) | (p[1] & 255)


int load_be24(char* p):
	return ((p[0] & 255) << 16) | ((p[1] & 255) << 8) | (p[2] & 255)


int load_be32(char* p):
	return ((p[0] & 255) << 24) | ((p[1] & 255) << 16) | ((p[2] & 255) << 8) | (p[3] & 255)


int load_le16(char* p):
	return (p[0] & 255) | ((p[1] & 255) << 8)


int load_le32(char* p):
	return (p[0] & 255) | ((p[1] & 255) << 8) | ((p[2] & 255) << 16) | ((p[3] & 255) << 24)


void store_be16(char* p, int v):
	p[0] = (v >> 8) & 255
	p[1] = v & 255


void store_be24(char* p, int v):
	p[0] = (v >> 16) & 255
	p[1] = (v >> 8) & 255
	p[2] = v & 255


void store_be32(char* p, int v):
	p[0] = (v >> 24) & 255
	p[1] = (v >> 16) & 255
	p[2] = (v >> 8) & 255
	p[3] = v & 255


void store_le16(char* p, int v):
	p[0] = v & 255
	p[1] = (v >> 8) & 255


void store_le32(char* p, int v):
	p[0] = v & 255
	p[1] = (v >> 8) & 255
	p[2] = (v >> 16) & 255
	p[3] = (v >> 24) & 255


# Big-endian appends to a string_builder (wire headers, length prefixes).
void string_append_be16(string_builder* b, int v):
	string_append_char(b, (v >> 8) & 255)
	string_append_char(b, v & 255)


void string_append_be24(string_builder* b, int v):
	string_append_char(b, (v >> 16) & 255)
	string_append_be16(b, v)


void string_append_be32(string_builder* b, int v):
	string_append_be16(b, (v >> 16) & 65535)
	string_append_be16(b, v)


# ---- 64-bit fields ----------------------------------------------------------

# 0xffffffff built at runtime (lib/sha256.w's sha256_mask32 discipline):
# -1 on a 32-bit target, 4294967295 on a 64-bit one; the same low 32 bits.
int bytes_mask32():
	int h = 1 << 16
	return h * h - 1


void store_be64_parts(char* p, int hi, int lo):
	store_be32(p, hi)
	store_be32(p + 4, lo)


void store_le64_parts(char* p, int hi, int lo):
	store_le32(p, lo)
	store_le32(p + 4, hi)


void load_be64_parts(char* p, int* hi, int* lo):
	hi[0] = load_be32(p)
	lo[0] = load_be32(p + 4)


void load_le64_parts(char* p, int* hi, int* lo):
	lo[0] = load_le32(p)
	hi[0] = load_le32(p + 4)


# Splits a native word into masked 32-bit halves: hi is 0 on a 32-bit
# target (v's pattern zero-extends).
void bytes_split64(int v, int* hi, int* lo):
	if (__word_size__ == 8):
		int mask = bytes_mask32()
		hi[0] = (v >> 32) & mask
		lo[0] = v & mask
		return
	hi[0] = 0
	lo[0] = v


# Joins masked 32-bit halves into a native word. Returns 0 (storing 0)
# when the value does not fit: on a 32-bit target, any nonzero hi.
int bytes_join64(int hi, int lo, int* out):
	if (__word_size__ == 8):
		int mask = bytes_mask32()
		out[0] = ((hi & mask) << 32) | (lo & mask)
		return 1
	if (hi != 0):
		out[0] = 0
		return 0
	out[0] = lo
	return 1


int load_be64_word(char* p, int* out):
	return bytes_join64(load_be32(p), load_be32(p + 4), out)


int load_le64_word(char* p, int* out):
	return bytes_join64(load_le32(p + 4), load_le32(p), out)


int bytes_join64_or_abort(int hi, int lo):
	int v = 0
	if (bytes_join64(hi, lo, &v) == 0):
		println2(c"bytes: 64-bit value does not fit a 32-bit int; use load_*64_parts or load_*64_word")
		exit(1)
	return v


int load_be64(char* p):
	return bytes_join64_or_abort(load_be32(p), load_be32(p + 4))


int load_le64(char* p):
	return bytes_join64_or_abort(load_le32(p + 4), load_le32(p))


void store_be64(char* p, int v):
	int hi = 0
	int lo = 0
	bytes_split64(v, &hi, &lo)
	store_be64_parts(p, hi, lo)


void store_le64(char* p, int v):
	int hi = 0
	int lo = 0
	bytes_split64(v, &hi, &lo)
	store_le64_parts(p, hi, lo)


void string_append_be64(string_builder* b, int v):
	int hi = 0
	int lo = 0
	bytes_split64(v, &hi, &lo)
	string_append_be32(b, hi)
	string_append_be32(b, lo)


# ---- comparison -------------------------------------------------------------

# Unsigned lexicographic order of two byte strings: -1, 0 or 1. A proper
# prefix sorts first. Bytes compare as 0..255 (never as signed chars), so
# 0x80..0xff sort after 0x00..0x7f and an embedded NUL is an ordinary byte.
int bytes_compare(char* a, int a_length, char* b, int b_length):
	int n = a_length
	if (b_length < n): n = b_length
	for i in range(n):
		int x = a[i] & 255
		int y = b[i] & 255
		if (x != y):
			if (x < y): return 0 - 1
			return 1
	if (a_length < b_length): return 0 - 1
	if (a_length > b_length): return 1
	return 0


int bytes_equal(char* a, int a_length, char* b, int b_length):
	if (a_length != b_length): return 0
	for i in range(a_length):
		if (a[i] != b[i]): return 0
	return 1
