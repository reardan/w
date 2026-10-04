/*
Byte views, owned byte buffers and checked binary cursors
(docs/projects/reliable_services.md, W2). Builds on lib/bytes.w's
fixed-width conventions and lib/checked.w's overflow checks.

OWNERSHIP
- byte_view {data, length} is BORROWED: it never owns or frees data. A
  view into a byte_buf (byte_buf_view, or a byte_reader span over one)
  becomes invalid as soon as that buffer grows (append/reserve may move
  the storage), is cleared, released, taken, or freed. Copy the bytes
  out (byte_view_clone) to keep them past such a call.
- byte_buf {data, length, capacity, max_capacity} OWNS data. Growth is
  checked: length + extra and the doubled capacity are overflow-checked
  and capped at max_capacity (<= 0 means "no cap beyond int range").
  byte_buf_release frees the storage; byte_buf_take transfers it to the
  caller (who frees it with free()) and leaves the buffer empty and
  reusable.

CURSORS
- byte_reader reads from a borrowed range with a STICKY status: every
  read checks the remaining length before touching memory; the first
  failure latches into status, the failing read does not advance pos, and
  every later read returns 0 (or an empty view) and keeps the original
  status. These checks are explicit code, so they hold regardless of the
  compiler's bounds-trap settings. Decode a whole record, then check
  byte_reader_status once.
- byte_writer appends to a byte_buf with the same sticky status; a write
  that would exceed max_capacity, overflow, or not fit its field width
  latches an error and writes nothing.

INTEGER CONVENTIONS (never silent truncation)
- u8/u16 read back as non-negative ints.
- u32 follows the masked 32-bit-word convention (lib/bytes.w): bit 31 set
  reads back negative on a 32-bit target, positive on a 64-bit one.
- u64 and varint read into the native word: the full 64-bit pattern on
  64-bit targets (bit 63 set reads back negative); on a 32-bit target a
  value whose high 32 bits are nonzero is BYTES_OVERFLOW. The *_parts
  forms carry any 64-bit value on every target as masked 32-bit (hi, lo)
  halves (u64.w's u64_set_parts/u64_hi32/u64_lo32 interoperate).
- Writers reject values outside the field: u8 needs 0..255, u16 0..65535,
  u32 a 32-bit pattern (any int on a 32-bit target; on 64-bit, any value
  in [-2^31, 2^32), so sign-extended literals and masked words both work).
  u64/varint accept any word; a 32-bit target zero-extends it.
- Varints are unsigned LEB128 (protobuf/wasm base-128), at most 10 bytes
  for 64 bits. Decoding rejects truncation (BYTES_TRUNCATED), more than
  10 bytes or a non-minimal encoding such as 80 00 (BYTES_MALFORMED), and
  a value above 2^64-1 or above the target word (BYTES_OVERFLOW).
*/
import lib.lib
import lib.memory
import lib.bytes
import lib.checked


# Status codes. BYTES_OK is 0 so `if (status)` tests failure.
const int BYTES_OK = 0
const int BYTES_TRUNCATED = 1     # fewer bytes remain than the read needs
const int BYTES_MALFORMED = 2     # invalid encoding (overlong/non-minimal varint)
const int BYTES_OVERFLOW = 3      # value does not fit the field or the target word
const int BYTES_TOO_LARGE = 4     # exceeds a caller maximum or max_capacity
const int BYTES_NO_MEMORY = 5     # allocation failed
const int BYTES_INVALID = 6       # invalid argument (negative length, unknown prefix kind)


# Length-prefix kinds for byte_reader_prefixed / byte_writer_prefixed.
const int BYTES_PREFIX_U8 = 1
const int BYTES_PREFIX_U16BE = 2
const int BYTES_PREFIX_U16LE = 3
const int BYTES_PREFIX_U32BE = 4
const int BYTES_PREFIX_U32LE = 5
const int BYTES_PREFIX_VARINT = 6


# Largest varint encoding of a 64-bit value.
const int BYTES_VARINT_MAX = 10


char* bytes_status_name(int status):
	if (status == BYTES_OK): return c"ok"
	if (status == BYTES_TRUNCATED): return c"truncated"
	if (status == BYTES_MALFORMED): return c"malformed"
	if (status == BYTES_OVERFLOW): return c"overflow"
	if (status == BYTES_TOO_LARGE): return c"too_large"
	if (status == BYTES_NO_MEMORY): return c"no_memory"
	if (status == BYTES_INVALID): return c"invalid"
	return c"unknown"


# ---- byte_view (borrowed) ---------------------------------------------------

struct byte_view:
	char* data
	int length


byte_view byte_view_of(char* data, int length):
	byte_view v
	v.data = data
	v.length = length
	if (length < 0): v.length = 0
	return v


byte_view byte_view_empty():
	return byte_view_of(cast(char*, 0), 0)


# out = v[start, start+length); 0 (and an empty out) when the range is
# not inside v.
int byte_view_slice(byte_view v, int start, int length, byte_view* out):
	out.data = cast(char*, 0)
	out.length = 0
	if ((start < 0) || (length < 0)): return 0
	if (start > v.length): return 0
	if (length > v.length - start): return 0
	out.data = &v.data[start]
	out.length = length
	return 1


int byte_view_compare(byte_view a, byte_view b):
	return bytes_compare(a.data, a.length, b.data, b.length)


int byte_view_equal(byte_view a, byte_view b):
	return bytes_equal(a.data, a.length, b.data, b.length)


# A malloc'd copy of the view's bytes (at least one byte allocated, so
# the result is non-null for an empty view); 0 on allocation failure.
char* byte_view_clone(byte_view v):
	int size = v.length
	if (size < 1): size = 1
	char* copy = malloc(size)
	if (copy == 0): return copy
	for i in range(v.length): copy[i] = v.data[i]
	return copy


# ---- byte_buf (owned) -------------------------------------------------------

struct byte_buf:
	char* data          # owned storage, 0 until the first reserve
	int length          # bytes in use
	int capacity        # bytes allocated
	int max_capacity    # growth cap; <= 0 means only the int range caps it


void byte_buf_init(byte_buf* b, int max_capacity):
	b.data = cast(char*, 0)
	b.length = 0
	b.capacity = 0
	b.max_capacity = max_capacity


byte_buf* byte_buf_new(int max_capacity):
	byte_buf* b = new byte_buf()
	byte_buf_init(b, max_capacity)
	return b


int byte_buf_limit(byte_buf* b):
	if (b.max_capacity <= 0): return checked_int_max()
	return b.max_capacity


# Ensures room for extra more bytes. Returns BYTES_OK, BYTES_INVALID
# (extra < 0), BYTES_TOO_LARGE (length + extra overflows or exceeds
# max_capacity) or BYTES_NO_MEMORY; the buffer is unchanged on failure.
int byte_buf_reserve(byte_buf* b, int extra):
	if (extra < 0): return BYTES_INVALID
	int needed = 0
	if (checked_size_add(b.length, extra, &needed) == 0): return BYTES_TOO_LARGE
	int limit = byte_buf_limit(b)
	if (needed > limit): return BYTES_TOO_LARGE
	if (needed <= b.capacity): return BYTES_OK
	int grown = 0
	if (checked_size(b.capacity, 2, &grown) == 0): grown = limit
	if (grown < 16): grown = 16
	if (grown > limit): grown = limit
	if (grown < needed): grown = needed
	char* data = 0
	if (b.data == 0): data = malloc(grown)
	else: data = realloc(b.data, b.capacity, grown)
	if (data == 0): return BYTES_NO_MEMORY
	b.data = data
	b.capacity = grown
	return BYTES_OK


int byte_buf_append(byte_buf* b, char* data, int length):
	int status = byte_buf_reserve(b, length)
	if (status != BYTES_OK): return status
	for i in range(length): b.data[b.length + i] = data[i]
	b.length = b.length + length
	return BYTES_OK


int byte_buf_append_view(byte_buf* b, byte_view v):
	return byte_buf_append(b, v.data, v.length)


int byte_buf_append_u8(byte_buf* b, int v):
	int status = byte_buf_reserve(b, 1)
	if (status != BYTES_OK): return status
	b.data[b.length] = v & 255
	b.length = b.length + 1
	return BYTES_OK


# Borrowed view of the current contents; invalid after the next growth,
# clear, release, take or free.
byte_view byte_buf_view(byte_buf* b):
	return byte_view_of(b.data, b.length)


# Drops the contents, keeps the storage.
void byte_buf_clear(byte_buf* b):
	b.length = 0


# Frees the storage; the buffer is empty and reusable (same max_capacity).
void byte_buf_release(byte_buf* b):
	if (b.data != 0): free(b.data)
	b.data = cast(char*, 0)
	b.length = 0
	b.capacity = 0


# Transfers ownership of the storage to the caller: returns it (0 when
# nothing was ever reserved), stores the byte count in length_out, and
# resets the buffer to empty without freeing. The caller frees the
# result with free().
char* byte_buf_take(byte_buf* b, int* length_out):
	char* data = b.data
	length_out[0] = b.length
	b.data = cast(char*, 0)
	b.length = 0
	b.capacity = 0
	return data


# Releases the storage and the heap struct from byte_buf_new.
void byte_buf_free(byte_buf* b):
	byte_buf_release(b)
	free(b)


# ---- byte_reader ------------------------------------------------------------

struct byte_reader:
	char* data
	int length
	int pos
	int status


void byte_reader_init(byte_reader* r, char* data, int length):
	r.data = data
	r.length = length
	r.pos = 0
	r.status = BYTES_OK
	if (length < 0):
		r.length = 0
		r.status = BYTES_INVALID


void byte_reader_init_view(byte_reader* r, byte_view v):
	byte_reader_init(r, v.data, v.length)


int byte_reader_status(byte_reader* r):
	return r.status


int byte_reader_ok(byte_reader* r):
	if (r.status == BYTES_OK): return 1
	return 0


int byte_reader_remaining(byte_reader* r):
	return r.length - r.pos


int byte_reader_at_end(byte_reader* r):
	if (r.pos == r.length): return 1
	return 0


# Latches status (first error wins) and returns 0 for tail calls.
int byte_reader_fail(byte_reader* r, int status):
	if (r.status == BYTES_OK): r.status = status
	return 0


# 1 when n more bytes may be read; otherwise latches and returns 0.
# 0 <= pos <= length always holds, so length - pos cannot overflow.
int byte_reader_need(byte_reader* r, int n):
	if (r.status != BYTES_OK): return 0
	if (n < 0): return byte_reader_fail(r, BYTES_INVALID)
	if (n > r.length - r.pos): return byte_reader_fail(r, BYTES_TRUNCATED)
	return 1


char* byte_reader_cursor(byte_reader* r):
	return &r.data[r.pos]


int byte_reader_u8(byte_reader* r):
	if (byte_reader_need(r, 1) == 0): return 0
	int v = r.data[r.pos] & 255
	r.pos = r.pos + 1
	return v


int byte_reader_u16be(byte_reader* r):
	if (byte_reader_need(r, 2) == 0): return 0
	int v = load_be16(byte_reader_cursor(r))
	r.pos = r.pos + 2
	return v


int byte_reader_u16le(byte_reader* r):
	if (byte_reader_need(r, 2) == 0): return 0
	int v = load_le16(byte_reader_cursor(r))
	r.pos = r.pos + 2
	return v


int byte_reader_u32be(byte_reader* r):
	if (byte_reader_need(r, 4) == 0): return 0
	int v = load_be32(byte_reader_cursor(r))
	r.pos = r.pos + 4
	return v


int byte_reader_u32le(byte_reader* r):
	if (byte_reader_need(r, 4) == 0): return 0
	int v = load_le32(byte_reader_cursor(r))
	r.pos = r.pos + 4
	return v


# Any 64-bit value as masked 32-bit halves; both 0 on failure.
int byte_reader_u64be_parts(byte_reader* r, int* hi, int* lo):
	hi[0] = 0
	lo[0] = 0
	if (byte_reader_need(r, 8) == 0): return 0
	load_be64_parts(byte_reader_cursor(r), hi, lo)
	r.pos = r.pos + 8
	return 1


int byte_reader_u64le_parts(byte_reader* r, int* hi, int* lo):
	hi[0] = 0
	lo[0] = 0
	if (byte_reader_need(r, 8) == 0): return 0
	load_le64_parts(byte_reader_cursor(r), hi, lo)
	r.pos = r.pos + 8
	return 1


# The native-word join for 64-bit reads: BYTES_OVERFLOW (pos unchanged)
# when the value needs more than a 32-bit target's word.
int byte_reader_word64(byte_reader* r, int hi, int lo, int consumed):
	int v = 0
	if (bytes_join64(hi, lo, &v) == 0): return byte_reader_fail(r, BYTES_OVERFLOW)
	r.pos = r.pos + consumed
	return v


int byte_reader_u64be(byte_reader* r):
	if (byte_reader_need(r, 8) == 0): return 0
	int hi = 0
	int lo = 0
	load_be64_parts(byte_reader_cursor(r), &hi, &lo)
	return byte_reader_word64(r, hi, lo, 8)


int byte_reader_u64le(byte_reader* r):
	if (byte_reader_need(r, 8) == 0): return 0
	int hi = 0
	int lo = 0
	load_le64_parts(byte_reader_cursor(r), &hi, &lo)
	return byte_reader_word64(r, hi, lo, 8)


int byte_reader_skip(byte_reader* r, int n):
	if (byte_reader_need(r, n) == 0): return 0
	r.pos = r.pos + n
	return 1


# out = the next n bytes, borrowed from the reader's data (no copy).
int byte_reader_bytes(byte_reader* r, int n, byte_view* out):
	out.data = cast(char*, 0)
	out.length = 0
	if (byte_reader_need(r, n) == 0): return 0
	out.data = byte_reader_cursor(r)
	out.length = n
	r.pos = r.pos + n
	return 1


# Copies the next n bytes into dst (which must hold n bytes).
int byte_reader_copy(byte_reader* r, char* dst, int n):
	if (byte_reader_need(r, n) == 0): return 0
	char* src = byte_reader_cursor(r)
	for i in range(n): dst[i] = src[i]
	r.pos = r.pos + n
	return 1


# Decodes an unsigned LEB128 varint at pos without consuming it: stores
# the masked 32-bit halves and returns the encoded byte count, or 0
# after latching TRUNCATED / MALFORMED / OVERFLOW.
int byte_reader_varint_peek(byte_reader* r, int* hi, int* lo):
	hi[0] = 0
	lo[0] = 0
	if (r.status != BYTES_OK): return 0
	int mask = bytes_mask32()
	int h = 0
	int l = 0
	int i = 0
	while (1):
		if (i == BYTES_VARINT_MAX): return byte_reader_fail(r, BYTES_MALFORMED)
		if (r.pos + i >= r.length): return byte_reader_fail(r, BYTES_TRUNCATED)
		int b = r.data[r.pos + i] & 255
		int payload = b & 127
		int shift = 7 * i
		if (shift < 32):
			l = (l | (payload << shift)) & mask
			if (shift > 25): h = h | (payload >> (32 - shift))
		else:
			# The 10th byte (shift 63) may only carry bit 63.
			if ((shift == 63) && (payload > 1)): return byte_reader_fail(r, BYTES_OVERFLOW)
			h = (h | (payload << (shift - 32))) & mask
		i = i + 1
		if ((b & 128) == 0):
			# A final 0 byte after the first adds nothing: non-minimal.
			if ((i > 1) && (b == 0)): return byte_reader_fail(r, BYTES_MALFORMED)
			hi[0] = h
			lo[0] = l
			return i
	return 0


# Any 64-bit varint as masked 32-bit halves, on every target.
int byte_reader_varint_parts(byte_reader* r, int* hi, int* lo):
	int n = byte_reader_varint_peek(r, hi, lo)
	if (n == 0): return 0
	r.pos = r.pos + n
	return 1


# A varint into the native word (see INTEGER CONVENTIONS).
int byte_reader_varint(byte_reader* r):
	int hi = 0
	int lo = 0
	int n = byte_reader_varint_peek(r, &hi, &lo)
	if (n == 0): return 0
	return byte_reader_word64(r, hi, lo, n)


# A length prefix of the given kind; BYTES_TOO_LARGE (prefix not
# consumed) when the length is negative as a word or exceeds max.
int byte_reader_length(byte_reader* r, int kind, int max):
	if (r.status != BYTES_OK): return 0
	if (max < 0): return byte_reader_fail(r, BYTES_INVALID)
	int start = r.pos
	int n = 0
	if (kind == BYTES_PREFIX_U8): n = byte_reader_u8(r)
	else if (kind == BYTES_PREFIX_U16BE): n = byte_reader_u16be(r)
	else if (kind == BYTES_PREFIX_U16LE): n = byte_reader_u16le(r)
	else if (kind == BYTES_PREFIX_U32BE): n = byte_reader_u32be(r)
	else if (kind == BYTES_PREFIX_U32LE): n = byte_reader_u32le(r)
	else if (kind == BYTES_PREFIX_VARINT): n = byte_reader_varint(r)
	else: return byte_reader_fail(r, BYTES_INVALID)
	if (r.status != BYTES_OK): return 0
	if ((n < 0) || (n > max)):
		r.pos = start
		return byte_reader_fail(r, BYTES_TOO_LARGE)
	return n


# A length-prefixed span (borrowed). The length must be <= max and the
# whole span present; on failure pos stays at the prefix.
int byte_reader_prefixed(byte_reader* r, int kind, int max, byte_view* out):
	out.data = cast(char*, 0)
	out.length = 0
	int start = r.pos
	int n = byte_reader_length(r, kind, max)
	if (r.status != BYTES_OK): return 0
	if (byte_reader_bytes(r, n, out) == 0):
		r.pos = start
		return 0
	return 1


# ---- byte_writer ------------------------------------------------------------

struct byte_writer:
	byte_buf* buf
	int status


void byte_writer_init(byte_writer* w, byte_buf* buf):
	w.buf = buf
	w.status = BYTES_OK


int byte_writer_status(byte_writer* w):
	return w.status


int byte_writer_ok(byte_writer* w):
	if (w.status == BYTES_OK): return 1
	return 0


int byte_writer_fail(byte_writer* w, int status):
	if (w.status == BYTES_OK): w.status = status
	return 0


# Reserves n bytes and returns 1, or latches the reserve failure.
int byte_writer_room(byte_writer* w, int n):
	if (w.status != BYTES_OK): return 0
	int status = byte_buf_reserve(w.buf, n)
	if (status != BYTES_OK): return byte_writer_fail(w, status)
	return 1


char* byte_writer_cursor(byte_writer* w):
	return &w.buf.data[w.buf.length]


int byte_writer_advance(byte_writer* w, int n):
	w.buf.length = w.buf.length + n
	return 1


# 1 when v names a 32-bit pattern: always on 32-bit ints; on 64-bit ints
# any v in [-2^31, 2^32), so both a masked word (0xdeadbeef zero-extended)
# and a sign-extended literal (cast(int, 0xdeadbeef)) are accepted.
int byte_writer_fits32(int v):
	int ignored = 0
	if (checked_narrow_u32(v, &ignored)): return 1
	return checked_narrow_i32(v, &ignored)


int byte_writer_u8(byte_writer* w, int v):
	if ((v < 0) || (v > 255)): return byte_writer_fail(w, BYTES_OVERFLOW)
	if (byte_writer_room(w, 1) == 0): return 0
	byte_writer_cursor(w)[0] = v
	return byte_writer_advance(w, 1)


int byte_writer_u16be(byte_writer* w, int v):
	if ((v < 0) || (v > 65535)): return byte_writer_fail(w, BYTES_OVERFLOW)
	if (byte_writer_room(w, 2) == 0): return 0
	store_be16(byte_writer_cursor(w), v)
	return byte_writer_advance(w, 2)


int byte_writer_u16le(byte_writer* w, int v):
	if ((v < 0) || (v > 65535)): return byte_writer_fail(w, BYTES_OVERFLOW)
	if (byte_writer_room(w, 2) == 0): return 0
	store_le16(byte_writer_cursor(w), v)
	return byte_writer_advance(w, 2)


int byte_writer_u32be(byte_writer* w, int v):
	if (byte_writer_fits32(v) == 0): return byte_writer_fail(w, BYTES_OVERFLOW)
	if (byte_writer_room(w, 4) == 0): return 0
	store_be32(byte_writer_cursor(w), v)
	return byte_writer_advance(w, 4)


int byte_writer_u32le(byte_writer* w, int v):
	if (byte_writer_fits32(v) == 0): return byte_writer_fail(w, BYTES_OVERFLOW)
	if (byte_writer_room(w, 4) == 0): return 0
	store_le32(byte_writer_cursor(w), v)
	return byte_writer_advance(w, 4)


int byte_writer_u64be_parts(byte_writer* w, int hi, int lo):
	if (byte_writer_room(w, 8) == 0): return 0
	store_be64_parts(byte_writer_cursor(w), hi, lo)
	return byte_writer_advance(w, 8)


int byte_writer_u64le_parts(byte_writer* w, int hi, int lo):
	if (byte_writer_room(w, 8) == 0): return 0
	store_le64_parts(byte_writer_cursor(w), hi, lo)
	return byte_writer_advance(w, 8)


int byte_writer_u64be(byte_writer* w, int v):
	int hi = 0
	int lo = 0
	bytes_split64(v, &hi, &lo)
	return byte_writer_u64be_parts(w, hi, lo)


int byte_writer_u64le(byte_writer* w, int v):
	int hi = 0
	int lo = 0
	bytes_split64(v, &hi, &lo)
	return byte_writer_u64le_parts(w, hi, lo)


int byte_writer_bytes(byte_writer* w, char* data, int length):
	if (length < 0): return byte_writer_fail(w, BYTES_INVALID)
	if (byte_writer_room(w, length) == 0): return 0
	char* dst = byte_writer_cursor(w)
	for i in range(length): dst[i] = data[i]
	return byte_writer_advance(w, length)


int byte_writer_view(byte_writer* w, byte_view v):
	return byte_writer_bytes(w, v.data, v.length)


# Encodes (hi:lo) as a minimal unsigned LEB128 varint into out (which
# must hold BYTES_VARINT_MAX bytes); returns the byte count.
int bytes_varint_encode_parts(char* out, int hi, int lo):
	int mask = bytes_mask32()
	int l = lo & mask
	int h = hi & mask
	int n = 0
	while (1):
		int b = l & 127
		l = (shr(l, 7) | ((h & 127) << 25)) & mask
		h = shr(h, 7)
		if ((l == 0) && (h == 0)):
			out[n] = b
			return n + 1
		out[n] = b | 128
		n = n + 1
	return n


# Encoded size of a varint for the native word v.
int bytes_varint_size(int v):
	int n = 1
	int x = unsigned_shr(v, 7)
	while (x != 0):
		n = n + 1
		x = unsigned_shr(x, 7)
	return n


int byte_writer_varint_parts(byte_writer* w, int hi, int lo):
	char[10] tmp
	int n = bytes_varint_encode_parts(&tmp[0], hi, lo)
	return byte_writer_bytes(w, &tmp[0], n)


# The native word v as an unsigned varint (zero-extended on 32-bit ints).
int byte_writer_varint(byte_writer* w, int v):
	int hi = 0
	int lo = 0
	bytes_split64(v, &hi, &lo)
	return byte_writer_varint_parts(w, hi, lo)


# Writes a length prefix of the given kind for length; BYTES_OVERFLOW
# when length does not fit the prefix field.
int byte_writer_length(byte_writer* w, int kind, int length):
	if (length < 0): return byte_writer_fail(w, BYTES_INVALID)
	if (kind == BYTES_PREFIX_U8): return byte_writer_u8(w, length)
	if (kind == BYTES_PREFIX_U16BE): return byte_writer_u16be(w, length)
	if (kind == BYTES_PREFIX_U16LE): return byte_writer_u16le(w, length)
	if (kind == BYTES_PREFIX_U32BE): return byte_writer_u32be(w, length)
	if (kind == BYTES_PREFIX_U32LE): return byte_writer_u32le(w, length)
	if (kind == BYTES_PREFIX_VARINT): return byte_writer_varint(w, length)
	return byte_writer_fail(w, BYTES_INVALID)


# A length prefix then the bytes. All-or-nothing: on failure the buffer
# is restored to its previous length.
int byte_writer_prefixed(byte_writer* w, int kind, char* data, int length):
	int start = w.buf.length
	if (byte_writer_length(w, kind, length) == 0): return 0
	if (byte_writer_bytes(w, data, length) == 0):
		w.buf.length = start
		return 0
	return 1
