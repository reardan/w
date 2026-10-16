# libs.standard.formats.struct: Python's struct module for W.
#
# Converts between byte strings and sequences of values described by a
# format string: an optional first character picking byte order, size and
# alignment, then format codes with optional repeat counts ("<2HI4s").
#
#   @  native order, native sizes, native alignment (the default)
#   =  native order, standard sizes, no alignment
#   <  little-endian, standard sizes, no alignment
#   >  big-endian, standard sizes, no alignment
#   !  network (= big-endian), standard sizes, no alignment
#
#   code  value kind          standard size  native size (x86 / 64-bit)
#   x     pad byte, no value  1              1
#   c     STRUCT_BYTES (1)    1              1
#   b B   STRUCT_INT          1              1
#   ?     STRUCT_BOOL         1              1
#   h H   STRUCT_INT          2              2
#   i I   STRUCT_INT          4              4
#   l L   STRUCT_INT          4              4 / 8 (STRUCT_INT64/UINT64)
#   q Q   STRUCT_INT64/UINT64 8              8
#   n N   (native only)       -              word size
#   P     (native only)       -              word size
#   f     STRUCT_FLOAT        4              4
#   d     STRUCT_DOUBLE       8              8
#   s     STRUCT_BYTES        count bytes    count bytes
#   p     STRUCT_BYTES        count bytes    count bytes (Pascal string)
#
# Native order is little-endian on every W target. Native alignment puts
# each item at a multiple of its size, except that the 32-bit x86 ABI
# aligns q/Q/d at 4; as in Python there is no trailing padding (end a
# format with "0q" or similar to pad it). Whitespace between codes is
# ignored. A count before s/p is the byte length of one item; before x it
# is a number of pad bytes; before any other code it repeats the code.
# The half-float code 'e' is not supported.
#
# W has no varargs of mixed types, so values travel in a struct_values
# list of tagged items: build one with the struct_values_add_* helpers for
# struct_pack, and read struct_unpack's result with the struct_values_*
# accessors. Every 64-bit quantity is also available as a (hi, lo) pair
# of masked 32-bit words (lib/bytes.w's convention), so q/Q/d work on the
# 32-bit x86 target, where int is 32 bits and float64 does not compile:
#
# - STRUCT_INT holds a native int. On 32-bit targets a 4-byte unsigned
#   code (I, L) accepts any int as its raw 32-bit pattern and unpacks
#   values >= 2**31 as negative ints (lib/bytes.w's load_le32 rule);
#   64-bit targets range-check exactly as Python does.
# - STRUCT_INT64 / STRUCT_UINT64 hold a 64-bit integer as (hi, lo), read
#   as signed or unsigned when range-checking. struct_values_int joins
#   them into a native int (aborting on a 32-bit target if the value
#   does not fit; struct_values_int_checked reports instead).
# - STRUCT_FLOAT holds a W float (float32). The f code packs it exactly;
#   d packs it widened exactly to float64.
# - STRUCT_DOUBLE holds IEEE-754 binary64 bits as (hi, lo). On 64-bit
#   targets convert with lib/fmath64.w's float64_bits/float64_from_bits
#   and lib/bytes.w's bytes_split64/bytes_join64. A double cannot be
#   packed with the f code (no narrowing; that is an error).
# - An integer item packs with f (converted to float32) and with d when
#   exactly representable (|value| < 2**53; larger is an error).
# - STRUCT_BYTES holds a byte string (embedded NULs allowed; the copy
#   kept by struct_values is NUL-terminated for convenience).
#
# Failures return 0 (or -1 from struct_calcsize) and leave a message in
# struct_error(); successful calls reset it to "".
import lib.lib
import lib.bytes
import lib.mem

const int STRUCT_INT = 1
const int STRUCT_BOOL = 2
const int STRUCT_INT64 = 3
const int STRUCT_UINT64 = 4
const int STRUCT_FLOAT = 5
const int STRUCT_DOUBLE = 6
const int STRUCT_BYTES = 7

# Formats larger than this are rejected rather than risk int overflow.
const int STRUCT_MAX_SIZE = 268435456

struct struct_item:
	int kind
	int hi
	int lo
	char* data
	int length

struct struct_values:
	list[struct_item] items

char* struct_error_message


char* struct_error():
	if (struct_error_message == 0): return c""
	return struct_error_message


int struct_fail(char* message):
	struct_error_message = message
	return 0


# ---- value lists -------------------------------------------------------------

struct_values* struct_values_new():
	struct_values* v = new struct_values()
	v.items = new list[struct_item]
	return v


void struct_values_free(struct_values* v):
	if (v == 0): return
	for struct_item* it in v.items:
		if (it.data != 0): free(it.data)
	v.items.free()
	free(v)


void struct_values_push(struct_values* v, int kind, int hi, int lo, char* data, int length):
	struct_item it
	it.kind = kind
	it.hi = hi
	it.lo = lo
	it.data = data
	it.length = length
	v.items.push(it)


void struct_values_add_int(struct_values* v, int x):
	struct_values_push(v, STRUCT_INT, 0, x, 0, 0)


void struct_values_add_bool(struct_values* v, int x):
	int b = 0
	if (x != 0): b = 1
	struct_values_push(v, STRUCT_BOOL, 0, b, 0, 0)


# A signed 64-bit integer as masked 32-bit halves (two's complement).
void struct_values_add_int64(struct_values* v, int hi, int lo):
	int mask = bytes_mask32()
	struct_values_push(v, STRUCT_INT64, hi & mask, lo & mask, 0, 0)


# An unsigned 64-bit integer as masked 32-bit halves.
void struct_values_add_uint64(struct_values* v, int hi, int lo):
	int mask = bytes_mask32()
	struct_values_push(v, STRUCT_UINT64, hi & mask, lo & mask, 0, 0)


int struct_float_bits(float f):
	int32* p = cast(int32*, &f)
	return *p & bytes_mask32()


float struct_float_from_bits(int bits):
	float f
	int32* p = cast(int32*, &f)
	*p = bits
	return f


void struct_values_add_float(struct_values* v, float f):
	struct_values_push(v, STRUCT_FLOAT, 0, struct_float_bits(f), 0, 0)


# A float32 given as its raw IEEE-754 bit pattern.
void struct_values_add_float_bits(struct_values* v, int bits):
	struct_values_push(v, STRUCT_FLOAT, 0, bits & bytes_mask32(), 0, 0)


# A float64 given as the (hi, lo) halves of its IEEE-754 bit pattern.
void struct_values_add_double_bits(struct_values* v, int hi, int lo):
	int mask = bytes_mask32()
	struct_values_push(v, STRUCT_DOUBLE, hi & mask, lo & mask, 0, 0)


char* struct_copy_bytes(char* p, int n):
	char* copy = cast(char*, malloc(n + 1))
	if (n > 0): mem_copy(copy, p, n)
	copy[n] = 0
	return copy


# Copies n bytes from p (embedded NULs allowed).
void struct_values_add_bytes(struct_values* v, char* p, int n):
	struct_values_push(v, STRUCT_BYTES, 0, 0, struct_copy_bytes(p, n), n)


# Copies a NUL-terminated string (without the terminator).
void struct_values_add_string(struct_values* v, char* s):
	struct_values_add_bytes(v, s, strlen(s))


int struct_values_length(struct_values* v):
	return v.items.length


int struct_values_kind(struct_values* v, int i):
	return v.items[i].kind


# The (hi, lo) halves of a 64-bit item (INT64, UINT64, DOUBLE); for INT
# and BOOL items hi is the sign extension of lo, for FLOAT hi is 0.
int struct_values_hi(struct_values* v, int i):
	struct_item* it = &v.items[i]
	if (it.kind == STRUCT_INT || it.kind == STRUCT_BOOL):
		int hi = 0
		int lo = 0
		bytes_split64(it.lo, &hi, &lo)
		if (__word_size__ == 4 && it.lo < 0): hi = bytes_mask32()
		return hi
	return it.hi


int struct_values_lo(struct_values* v, int i):
	struct_item* it = &v.items[i]
	if (it.kind == STRUCT_INT || it.kind == STRUCT_BOOL):
		return it.lo & bytes_mask32()
	return it.lo


# An integer item as a native int; returns 1, or 0 (storing 0) when the
# item is not an integer or does not fit the target word.
int struct_values_int_checked(struct_values* v, int i, int* out):
	struct_item* it = &v.items[i]
	if (it.kind == STRUCT_INT || it.kind == STRUCT_BOOL):
		out[0] = it.lo
		return 1
	if (it.kind == STRUCT_INT64 || it.kind == STRUCT_UINT64):
		if (__word_size__ == 4 && it.kind == STRUCT_INT64):
			# A negative int64 fits when hi is all ones and lo's sign bit is set.
			if (it.hi == bytes_mask32() && it.lo < 0):
				out[0] = it.lo
				return 1
		return bytes_join64(it.hi, it.lo, out)
	out[0] = 0
	return 0


# An integer item as a native int; aborts when it does not fit (see
# struct_values_int_checked and struct_values_hi/lo).
int struct_values_int(struct_values* v, int i):
	int out = 0
	if (struct_values_int_checked(v, i, &out) == 0):
		println2(c"struct: item is not an integer that fits a native int; use struct_values_hi/lo")
		exit(1)
	return out


int struct_values_bool(struct_values* v, int i):
	int out = 0
	struct_values_int_checked(v, i, &out)
	return out != 0


float struct_values_float(struct_values* v, int i):
	return struct_float_from_bits(v.items[i].lo)


# The bytes of a BYTES item (owned by v, NUL-terminated) and its length.
char* struct_values_bytes(struct_values* v, int i):
	return v.items[i].data


int struct_values_bytes_length(struct_values* v, int i):
	return v.items[i].length


# ---- format parsing ----------------------------------------------------------

struct struct_format:
	int big_endian
	int native
	list[int] codes
	list[int] counts
	int size
	int items


void struct_format_free(struct_format* f):
	if (f == 0): return
	f.codes.free()
	f.counts.free()
	free(f)


int struct_is_space(int ch):
	return ch == ' ' || ch == 9 || ch == 10 || ch == 11 || ch == 12 || ch == 13


# Size of one code in this mode, or 0 for an unknown code.
int struct_code_size(int code, int native):
	if (code == 'x' || code == 'c' || code == 'b' || code == 'B' || code == '?' || code == 's' || code == 'p'): return 1
	if (code == 'h' || code == 'H'): return 2
	if (code == 'i' || code == 'I' || code == 'f'): return 4
	if (code == 'q' || code == 'Q' || code == 'd'): return 8
	if (code == 'l' || code == 'L'):
		if (native): return __word_size__
		return 4
	if (native && (code == 'n' || code == 'N' || code == 'P')): return __word_size__
	return 0


int struct_code_align(int code, int native):
	if (native == 0): return 1
	int size = struct_code_size(code, 1)
	if (size == 8 && __word_size__ == 4): return 4
	return size


struct_format* struct_format_parse(char* fmt):
	struct_format* f = new struct_format()
	f.codes = new list[int]
	f.counts = new list[int]
	f.native = 1
	int i = 0
	int first = fmt[0]
	if (first == '@'): i = 1
	elif (first == '='):
		f.native = 0
		i = 1
	elif (first == '<'):
		f.native = 0
		i = 1
	elif (first == '>' || first == '!'):
		f.native = 0
		f.big_endian = 1
		i = 1
	int size = 0
	int items = 0
	while (fmt[i] != 0):
		int ch = fmt[i]
		if (struct_is_space(ch)):
			i = i + 1
			continue
		int count = 1
		if (ch >= '0' && ch <= '9'):
			count = 0
			while (fmt[i] >= '0' && fmt[i] <= '9'):
				if (count > STRUCT_MAX_SIZE):
					struct_format_free(f)
					struct_fail(c"total struct size too long")
					return 0
				count = count * 10 + (fmt[i] - '0')
				i = i + 1
			if (fmt[i] == 0):
				struct_format_free(f)
				struct_fail(c"repeat count given without format specifier")
				return 0
			ch = fmt[i]
		int item_size = struct_code_size(ch, f.native)
		if (item_size == 0):
			struct_format_free(f)
			struct_fail(c"bad char in struct format")
			return 0
		int align = struct_code_align(ch, f.native)
		size = (size + align - 1) / align * align
		if (ch == 's' || ch == 'p'):
			size = size + count
			items = items + 1
		elif (ch == 'x'):
			size = size + count
		else:
			if (count > STRUCT_MAX_SIZE / item_size):
				struct_format_free(f)
				struct_fail(c"total struct size too long")
				return 0
			size = size + count * item_size
			items = items + count
		if (size > STRUCT_MAX_SIZE):
			struct_format_free(f)
			struct_fail(c"total struct size too long")
			return 0
		f.codes.push(ch)
		f.counts.push(count)
		i = i + 1
	f.size = size
	f.items = items
	return f


# The packed size of fmt in bytes, or -1 (see struct_error) when fmt is bad.
int struct_calcsize(char* fmt):
	struct_format* f = struct_format_parse(fmt)
	if (f == 0): return 0 - 1
	int size = f.size
	struct_format_free(f)
	struct_error_message = 0
	return size


# ---- integers and floats -----------------------------------------------------

# An integer item as (neg, hi, lo): the 64-bit two's complement pattern in
# masked halves plus whether the mathematical value is negative. Returns
# 0 for non-integer kinds.
int struct_item_integer(struct_item* it, int* neg, int* hi, int* lo):
	int mask = bytes_mask32()
	if (it.kind == STRUCT_INT || it.kind == STRUCT_BOOL):
		int x = it.lo
		neg[0] = x < 0
		if (__word_size__ == 8):
			bytes_split64(x, hi, lo)
		else:
			lo[0] = x
			hi[0] = 0
			if (x < 0): hi[0] = mask
		return 1
	if (it.kind == STRUCT_INT64 || it.kind == STRUCT_UINT64):
		hi[0] = it.hi
		lo[0] = it.lo
		neg[0] = 0
		if (it.kind == STRUCT_INT64 && (it.hi & (1 << 31)) != 0): neg[0] = 1
		return 1
	return 0


# Whether (neg, hi, lo) fits a size-byte integer code.
int struct_int_fits(int size, int is_signed, int neg, int hi, int lo):
	int mask = bytes_mask32()
	if (size == 8):
		if (is_signed): return neg || (hi & (1 << 31)) == 0
		return neg == 0
	if (is_signed):
		int low_bits = (1 << (size * 8 - 1)) - 1
		if (neg):
			return hi == mask && ((lo | low_bits) & mask) == mask
		return hi == 0 && (lo & ~low_bits & mask) == 0
	if (neg): return 0
	if (hi != 0): return 0
	if (size == 4): return 1
	return (lo & ~((1 << (size * 8)) - 1) & mask) == 0


int struct_is_unsigned_code(int code):
	return code == 'B' || code == 'H' || code == 'I' || code == 'L' || code == 'Q' || code == 'N' || code == 'P'


void struct_store_int(char* p, int size, int big_endian, int hi, int lo):
	if (size == 8):
		if (big_endian): store_be64_parts(p, hi, lo)
		else: store_le64_parts(p, hi, lo)
		return
	for k in range(size):
		int shift = k * 8
		int at = k
		if (big_endian): at = size - 1 - k
		p[at] = (lo >> shift) & 255


# Exact float32 -> float64 widening on bit patterns.
void struct_widen_float(int bits, int* hi, int* lo):
	int sign = (bits >> 31) & 1
	int e = (bits >> 23) & 255
	int man = bits & 8388607
	int e64 = 0
	if (e == 255): e64 = 2047
	elif (e == 0):
		if (man != 0):
			e64 = 1023 - 126
			while ((man & 8388608) == 0):
				man = man << 1
				e64 = e64 - 1
			man = man & 8388607
	else:
		e64 = e - 127 + 1023
	hi[0] = ((sign << 31) | (e64 << 20) | (man >> 3)) & bytes_mask32()
	lo[0] = (man & 7) << 29


# Shifts the 64-bit pair (hi, lo) left by 0 <= n < 64 bits.
void struct_shl64(int* hi, int* lo, int n):
	int mask = bytes_mask32()
	if (n == 0): return
	if (n >= 32):
		hi[0] = (lo[0] << (n - 32)) & mask
		lo[0] = 0
		return
	int carried = (lo[0] >> (32 - n)) & ((1 << n) - 1)
	hi[0] = ((hi[0] << n) | carried) & mask
	lo[0] = (lo[0] << n) & mask


# Exact integer -> float64 bits; returns 0 when |value| needs rounding
# (more than 53 significant bits).
int struct_int_to_double(int neg, int hi, int lo, int* dhi, int* dlo):
	int mask = bytes_mask32()
	int mhi = hi & mask
	int mlo = lo & mask
	if (neg):
		mlo = (~mlo + 1) & mask
		int carry = 0
		if (mlo == 0): carry = 1
		mhi = (~mhi + carry) & mask
	dhi[0] = 0
	dlo[0] = 0
	if (mhi == 0 && mlo == 0): return 1
	int top = 0
	for k in range(32):
		if (((mlo >> k) & 1) != 0): top = k
	if (mhi != 0):
		for k in range(32):
			if (((mhi >> k) & 1) != 0): top = 32 + k
	if (top > 52): return 0
	struct_shl64(&mhi, &mlo, 52 - top)
	int sign = 0
	if (neg): sign = 1
	dhi[0] = ((sign << 31) | ((1023 + top) << 20) | (mhi & 1048575)) & mask
	dlo[0] = mlo
	return 1


int struct_truthy(struct_item* it):
	if (it.kind == STRUCT_BYTES): return it.length != 0
	if (it.kind == STRUCT_FLOAT): return (it.lo & 2147483647) != 0
	if (it.kind == STRUCT_DOUBLE): return (it.hi & 2147483647) != 0 || it.lo != 0
	return it.hi != 0 || it.lo != 0


# ---- packing -----------------------------------------------------------------

# Packs one value for code at p; returns 1 or 0 with struct_error set.
int struct_pack_one(int code, int size, int big_endian, struct_item* it, char* p):
	if (code == '?'):
		p[0] = struct_truthy(it)
		return 1
	if (code == 'c'):
		if (it.kind != STRUCT_BYTES || it.length != 1): return struct_fail(c"char format requires a bytes object of length 1")
		p[0] = it.data[0]
		return 1
	if (code == 'f'):
		int bits = 0
		if (it.kind == STRUCT_FLOAT): bits = it.lo
		elif (it.kind == STRUCT_INT):
			float converted = it.lo
			bits = struct_float_bits(converted)
		else: return struct_fail(c"required argument is not a float")
		struct_store_int(p, 4, big_endian, 0, bits)
		return 1
	if (code == 'd'):
		int dhi = 0
		int dlo = 0
		if (it.kind == STRUCT_DOUBLE):
			dhi = it.hi
			dlo = it.lo
		elif (it.kind == STRUCT_FLOAT): struct_widen_float(it.lo, &dhi, &dlo)
		elif (it.kind == STRUCT_INT):
			int ineg = 0
			int ihi = 0
			int ilo = 0
			struct_item_integer(it, &ineg, &ihi, &ilo)
			if (struct_int_to_double(ineg, ihi, ilo, &dhi, &dlo) == 0):
				return struct_fail(c"int not exactly representable as a double; pass double bits")
		else: return struct_fail(c"required argument is not a float")
		struct_store_int(p, 8, big_endian, dhi, dlo)
		return 1
	int neg = 0
	int hi = 0
	int lo = 0
	if (struct_item_integer(it, &neg, &hi, &lo) == 0):
		return struct_fail(c"required argument is not an integer")
	int is_signed = struct_is_unsigned_code(code) == 0
	int fits = struct_int_fits(size, is_signed, neg, hi, lo)
	# 32-bit targets: an int is the raw pattern of a 4-byte unsigned code.
	if (fits == 0 && __word_size__ == 4 && size == 4 && is_signed == 0 && it.kind == STRUCT_INT): fits = 1
	if (fits == 0): return struct_fail(c"argument out of range")
	struct_store_int(p, size, big_endian, hi, lo)
	return 1


int struct_pack_format(struct_format* f, char* out, struct_values* v):
	if (v.items.length != f.items): return struct_fail(c"pack expected a different number of items")
	int offset = 0
	int item = 0
	for k in range(f.codes.length):
		int code = f.codes[k]
		int count = f.counts[k]
		int size = struct_code_size(code, f.native)
		int align = struct_code_align(code, f.native)
		while (offset % align != 0):
			out[offset] = 0
			offset = offset + 1
		if (code == 'x'):
			for j in range(count): out[offset + j] = 0
			offset = offset + count
		elif (code == 's' || code == 'p'):
			struct_item* it = &v.items[item]
			item = item + 1
			if (it.kind != STRUCT_BYTES): return struct_fail(c"argument for 's' or 'p' must be a bytes object")
			for j in range(count): out[offset + j] = 0
			if (code == 's'):
				int n = it.length
				if (n > count): n = count
				if (n > 0): mem_copy(out + offset, it.data, n)
			elif (count > 0):
				int m = it.length
				if (m > count - 1): m = count - 1
				if (m > 0): mem_copy(out + offset + 1, it.data, m)
				if (m > 255): m = 255
				out[offset] = m
			offset = offset + count
		else:
			for j in range(count):
				if (struct_pack_one(code, size, f.big_endian, &v.items[item], &out[offset]) == 0): return 0
				item = item + 1
				offset = offset + size
	struct_error_message = 0
	return 1


# Packs v according to fmt into a new malloc'd buffer of *out_length
# bytes (plus a NUL past the end). Returns 0 on error (see struct_error).
char* struct_pack(char* fmt, struct_values* v, int* out_length):
	out_length[0] = 0
	struct_format* f = struct_format_parse(fmt)
	if (f == 0): return 0
	char* out = cast(char*, malloc(f.size + 1))
	out[f.size] = 0
	if (struct_pack_format(f, out, v) == 0):
		free(out)
		struct_format_free(f)
		return 0
	out_length[0] = f.size
	struct_format_free(f)
	return out


# Normalizes a Python-style offset (negative counts from the end) and
# checks that size bytes fit; returns the offset or -1.
int struct_check_offset(int offset, int buffer_length, int size, char* short_message):
	if (offset < 0):
		if (offset + buffer_length < 0):
			struct_fail(c"offset out of range for buffer")
			return 0 - 1
		offset = offset + buffer_length
	if (buffer_length - offset < size):
		struct_fail(short_message)
		return 0 - 1
	return offset


# Packs v into buf[offset..] (buf holds buffer_length bytes; a negative
# offset counts from the end). Returns 1, or 0 leaving buf untouched.
int struct_pack_into(char* fmt, char* buf, int buffer_length, int offset, struct_values* v):
	struct_format* f = struct_format_parse(fmt)
	if (f == 0): return 0
	int at = struct_check_offset(offset, buffer_length, f.size, c"pack_into requires a bigger buffer")
	if (at < 0):
		struct_format_free(f)
		return 0
	char* tmp = cast(char*, malloc(f.size + 1))
	int ok = struct_pack_format(f, tmp, v)
	if (ok && f.size > 0): mem_copy(buf + at, tmp, f.size)
	free(tmp)
	struct_format_free(f)
	return ok


# ---- unpacking ---------------------------------------------------------------

int struct_load_int(char* p, int size, int big_endian, int is_signed):
	int x = 0
	for k in range(size):
		int at = k
		if (big_endian == 0): at = size - 1 - k
		x = (x << 8) | (p[at] & 255)
	if (is_signed):
		if (size == 1 && x >= 128): x = x - 256
		elif (size == 2 && x >= 32768): x = x - 65536
		elif (size == 4 && __word_size__ == 8 && (x & (1 << 31)) != 0):
			x = x - (1 << 16) * (1 << 16)
	return x


struct_values* struct_unpack_format(struct_format* f, char* buf):
	struct_values* v = struct_values_new()
	int offset = 0
	for k in range(f.codes.length):
		int code = f.codes[k]
		int count = f.counts[k]
		int size = struct_code_size(code, f.native)
		int align = struct_code_align(code, f.native)
		offset = (offset + align - 1) / align * align
		if (code == 'x'):
			offset = offset + count
		elif (code == 's'):
			struct_values_add_bytes(v, &buf[offset], count)
			offset = offset + count
		elif (code == 'p'):
			int n = 0
			if (count > 0):
				n = buf[offset] & 255
				if (n >= count): n = count - 1
			struct_values_add_bytes(v, &buf[offset + 1], n)
			offset = offset + count
		else:
			for j in range(count):
				char* p = &buf[offset]
				if (code == 'c'): struct_values_add_bytes(v, p, 1)
				elif (code == '?'): struct_values_add_bool(v, p[0] != 0)
				elif (code == 'f'): struct_values_add_float_bits(v, struct_load_int(p, 4, f.big_endian, 0))
				elif (code == 'd' || size == 8):
					int hi = 0
					int lo = 0
					if (f.big_endian): load_be64_parts(p, &hi, &lo)
					else: load_le64_parts(p, &hi, &lo)
					if (code == 'd'): struct_values_add_double_bits(v, hi, lo)
					elif (struct_is_unsigned_code(code)): struct_values_add_uint64(v, hi, lo)
					else: struct_values_add_int64(v, hi, lo)
				else:
					struct_values_add_int(v, struct_load_int(p, size, f.big_endian, struct_is_unsigned_code(code) == 0))
				offset = offset + size
	struct_error_message = 0
	return v


# Unpacks buf, which must hold exactly struct_calcsize(fmt) bytes, into a
# new struct_values (free with struct_values_free). Returns 0 on error.
struct_values* struct_unpack(char* fmt, char* buf, int length):
	struct_format* f = struct_format_parse(fmt)
	if (f == 0): return 0
	if (length != f.size):
		struct_format_free(f)
		struct_fail(c"unpack requires a buffer of exactly calcsize(fmt) bytes")
		return 0
	struct_values* v = struct_unpack_format(f, buf)
	struct_format_free(f)
	return v


# Unpacks from buf[offset..] (a negative offset counts from the end);
# buf must hold at least offset + calcsize(fmt) bytes.
struct_values* struct_unpack_from(char* fmt, char* buf, int length, int offset = 0):
	struct_format* f = struct_format_parse(fmt)
	if (f == 0): return 0
	int at = struct_check_offset(offset, length, f.size, c"unpack_from requires a bigger buffer")
	if (at < 0):
		struct_format_free(f)
		return 0
	struct_values* v = struct_unpack_format(f, &buf[at])
	struct_format_free(f)
	return v
