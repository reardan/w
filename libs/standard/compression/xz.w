/*
libs/standard/compression/xz.w: a one-shot decoder for the .xz container
with the LZMA2 filter (plus the Delta filter), and for the legacy raw
`.lzma` (LZMA_alone) format, which shares the LZMA core -- Python's
lzma.decompress for those formats (stdlib parity P3.3b; decode only).

	int n = 0
	int err = 0
	char* out = lzma_decompress(data, len, 0, &n, &err)   # FORMAT_AUTO
	if (out == 0): println(xz_error_string(err))
	...
	free(out)

All three entry points take (data, len, max_output, &out_len, &out_error)
and return a malloc'd buffer of out_len bytes (with a NUL one byte past
the end, so an empty result is still a non-zero pointer), or 0 with
*out_len = 0 and *out_error set to an XZ_ERR_* code. max_output <= 0
means unbounded; otherwise decoding fails closed with XZ_ERR_TOO_LARGE
once the output would exceed it (a decompression-bomb guard). Corrupt
or truncated input never reads outside `data` and never crashes.

  xz_decompress          .xz only            (Python FORMAT_XZ)
  lzma_alone_decompress  .lzma only          (Python FORMAT_ALONE)
  lzma_decompress        detect per stream   (Python FORMAT_AUTO, the
                                              lzma.decompress default)

.xz container (tukaani xz-file-format 1.2.1): stream header/footer with
their CRC32s, block headers (CRC32, optional compressed/uncompressed
sizes, filter chain), block padding, the index (records checked against
the blocks actually decoded, CRC32), the footer's backward size, and
any number of concatenated streams separated by stream padding (zero
bytes in multiples of four). Integrity checks: None, CRC32 and CRC64
are verified, SHA-256 is verified through libs/standard/crypto/sha2.w;
the other check ids the format reserves are skipped unverified with
their declared sizes, as liblzma does without LZMA_TELL_UNSUPPORTED_CHECK.
Filters: LZMA2 (last, required) and Delta before it; BCJ and every other
filter id fail with XZ_ERR_OPTIONS.

Python parity notes. Like Python's lzma.decompress, after the first
stream has decoded, trailing bytes that are not a further valid stream
are ignored (the second stream's output is dropped), except that a
further stream that is merely truncated fails. Two documented
deviations: stream padding between/after .xz streams is honored per the
xz spec (`xz -d` behavior), where CPython stops at the first padding
byte; and an LZMA_alone header with a known uncompressed size stops at
that size without looking for an end marker.

32/64-bit portability: the range coder's range/code, the CRC64 halves
and every other 32-bit quantity live in uint32 locals (an unsigned word
on x86, a zero-extended register on x64/arm64), so comparisons and
shifts are unsigned on every target and no literal with bit 31 set
appears. Sizes in the format are 63-bit VLIs; values that do not fit in
31 bits are rejected as corrupt (no such block can be held in memory on
the 32-bit target anyway).

The CRC tables are built per call and freed with the decoder (no lazy
process-lifetime global), so W_TEST_LEAKS stays meaningful for callers.
The CRC32 table comes from libs/extras/compress/crc32.w's
crc32_build_table. lib/sha256.w caches its round constants lazily on
first use (one 64-word block, never freed).
*/
import lib.memory
import lib.mem
import libs.extras.compress.crc32
import libs.standard.crypto.sha2


const int XZ_OK = 0
const int XZ_ERR_FORMAT = 1
const int XZ_ERR_OPTIONS = 2
const int XZ_ERR_DATA = 3
const int XZ_ERR_CHECK = 4
const int XZ_ERR_TRUNCATED = 5
const int XZ_ERR_TOO_LARGE = 6


char* xz_error_string(int code):
	if (code == XZ_OK): return c"xz: ok"
	if (code == XZ_ERR_FORMAT): return c"xz: input format not recognized"
	if (code == XZ_ERR_OPTIONS): return c"xz: unsupported options (filter, flags or properties)"
	if (code == XZ_ERR_DATA): return c"xz: corrupt input data"
	if (code == XZ_ERR_CHECK): return c"xz: integrity check mismatch"
	if (code == XZ_ERR_TRUNCATED):
		return c"xz: compressed data ended before the end-of-stream marker was reached"
	if (code == XZ_ERR_TOO_LARGE): return c"xz: output exceeded the caller's max_output cap"
	return c"xz: unknown error"


# Probability-array layout (one int per 11-bit probability).
const int XZP_IS_MATCH = 0
const int XZP_IS_REP = 192
const int XZP_IS_REP0 = 204
const int XZP_IS_REP1 = 216
const int XZP_IS_REP2 = 228
const int XZP_IS_REP0_LONG = 240
const int XZP_DIST_SLOT = 432
const int XZP_DIST_SPECIAL = 688
const int XZP_ALIGN = 802
const int XZP_LEN_MATCH = 818
const int XZP_LEN_REP = 1332
const int XZP_LITERAL = 1846
# LITERAL + 0x300 << (lc + lp) with lc + lp <= 4.
const int XZP_TOTAL = 14134

const int XZ_MODE_XZ = 1
const int XZ_MODE_ALONE = 2
const int XZ_MODE_AUTO = 3


struct xz_dec:
	char* in_data
	int in_len
	# range decoder
	int rc_pos
	int rc_limit
	int range
	int code
	# output: the whole output doubles as the LZMA dictionary
	char* out
	int out_len
	int out_cap
	int max_output
	int dict_start
	# LZMA state
	int* probs
	int lc
	int lp
	int pb
	int state
	int rep0
	int rep1
	int rep2
	int rep3
	int eopm
	int error
	# varint cursor
	int vpos
	# index bookkeeping for the current stream: (unpadded, uncompressed) pairs
	int* records
	int record_count
	int record_cap
	# per-call checksum tables
	int* crc32_tab
	int* crc64_hi
	int* crc64_lo


void xz_fail(xz_dec* d, int code):
	if (d.error == 0): d.error = code


# A truncation when the bound is the end of the input, corruption when it
# is a length field inside the stream.
void xz_fail_bound(xz_dec* d, int bound):
	if (bound >= d.in_len): xz_fail(d, XZ_ERR_TRUNCATED)
	else: xz_fail(d, XZ_ERR_DATA)


int xz_u8(xz_dec* d, int p):
	return d.in_data[p] & 255


int xz_le32(xz_dec* d, int p):
	uint32 v = xz_u8(d, p) | (xz_u8(d, p + 1) << 8) | (xz_u8(d, p + 2) << 16) | (xz_u8(d, p + 3) << 24)
	return v


# ---- checksums --------------------------------------------------------

int xz_crc32(xz_dec* d, char* data, int len):
	if (d.crc32_tab == 0): d.crc32_tab = crc32_build_table()
	int* table = d.crc32_tab
	uint32 c = -1
	for i in range(len):
		c = (c >> 8) ^ table[(c ^ (data[i] & 255)) & 255]
	uint32 r = c ^ -1
	return r


# Stored CRC32 at p over len bytes at start.
int xz_crc32_ok(xz_dec* d, int start, int len, int p):
	uint32 want = xz_le32(d, p)
	uint32 got = xz_crc32(d, &d.in_data[start], len)
	return want == got


# CRC-64/XZ (ECMA-182, reflected polynomial 0xC96C5795D7870F42), as two
# 32-bit halves.
void xz_crc64_tables(xz_dec* d):
	uint32 poly_hi = (0xc96c << 16) | 0x5795
	uint32 poly_lo = (0xd787 << 16) | 0x0f42
	int* hi_tab = cast(int*, malloc(256 * __word_size__))
	int* lo_tab = cast(int*, malloc(256 * __word_size__))
	for n in range(256):
		uint32 hi = 0
		uint32 lo = n
		for k in range(8):
			int low_bit = lo & 1
			lo = (lo >> 1) | ((hi & 1) << 31)
			hi = hi >> 1
			if (low_bit != 0):
				lo = lo ^ poly_lo
				hi = hi ^ poly_hi
		hi_tab[n] = hi
		lo_tab[n] = lo
	d.crc64_hi = hi_tab
	d.crc64_lo = lo_tab


# Writes the 8-byte little-endian CRC64 of data to out.
void xz_crc64(xz_dec* d, char* data, int len, char* out):
	if (d.crc64_hi == 0): xz_crc64_tables(d)
	int* hi_tab = d.crc64_hi
	int* lo_tab = d.crc64_lo
	uint32 hi = -1
	uint32 lo = -1
	for i in range(len):
		int idx = (lo ^ (data[i] & 255)) & 255
		lo = ((lo >> 8) | (hi << 24)) ^ lo_tab[idx]
		hi = (hi >> 8) ^ hi_tab[idx]
	hi = hi ^ -1
	lo = lo ^ -1
	for k in range(4):
		out[k] = (lo >> (8 * k)) & 255
		out[k + 4] = (hi >> (8 * k)) & 255


int xz_check_size(int check_id):
	if (check_id == 0): return 0
	if (check_id <= 3): return 4
	if (check_id <= 6): return 8
	if (check_id <= 9): return 16
	if (check_id <= 12): return 32
	return 64


# Verifies the block check stored at p for out[start..start+len).
int xz_check_ok(xz_dec* d, int check_id, int start, int len, int p):
	char* data = &d.out[start]
	if (check_id == 1):
		uint32 want = xz_le32(d, p)
		uint32 got = xz_crc32(d, data, len)
		return want == got
	char* digest = 0
	int n = 0
	if (check_id == 4):
		n = 8
		digest = cast(char*, malloc(8))
		xz_crc64(d, data, len, digest)
	else if (check_id == 10):
		n = 32
		digest = cast(char*, malloc(32))
		whash_oneshot(WHASH_SHA256, data, len, digest)
	else:
		return 1
	int ok = mem_eq[char](digest, &d.in_data[p], n)
	free(digest)
	return ok


# ---- output buffer ----------------------------------------------------

# Room for extra more bytes plus the trailing NUL.
void xz_grow(xz_dec* d, int extra):
	int need = d.out_len + extra + 1
	if (need <= d.out_cap): return
	int cap = d.out_cap * 2
	if (cap < need): cap = need
	d.out = realloc(d.out, d.out_cap, cap)
	d.out_cap = cap


# Room for extra more bytes (plus the trailing NUL); 0 and an error when
# the caller's cap would be exceeded.
int xz_reserve(xz_dec* d, int extra):
	if ((d.max_output >= 0) && (extra > d.max_output - d.out_len)):
		xz_fail(d, XZ_ERR_TOO_LARGE)
		return 0
	xz_grow(d, extra)
	return 1


# ---- range decoder ----------------------------------------------------

int xzr_next(xz_dec* d):
	if (d.rc_pos >= d.rc_limit):
		xz_fail_bound(d, d.rc_limit)
		return 0
	int b = d.in_data[d.rc_pos] & 255
	d.rc_pos = d.rc_pos + 1
	return b


# Starts a range coder over in[p..limit): five init bytes, the first 0.
void xzr_init(xz_dec* d, int p, int limit):
	d.rc_pos = p
	d.rc_limit = limit
	uint32 all = -1
	d.range = all
	if (xzr_next(d) != 0): xz_fail(d, XZ_ERR_DATA)
	uint32 code = 0
	for i in range(4): code = (code << 8) | xzr_next(d)
	d.code = code


int xzr_bit(xz_dec* d, int* probs, int i):
	uint32 range = d.range
	uint32 code = d.code
	int p = probs[i]
	uint32 bound = (range >> 11) * p
	int bit = 0
	if (code < bound):
		range = bound
		probs[i] = p + ((2048 - p) >> 5)
	else:
		range = range - bound
		code = code - bound
		probs[i] = p - (p >> 5)
		bit = 1
	if (range < 16777216):
		range = range << 8
		code = (code << 8) | xzr_next(d)
	d.range = range
	d.code = code
	return bit


int xzr_direct(xz_dec* d, int count):
	uint32 range = d.range
	uint32 code = d.code
	uint32 r = 0
	for i in range(count):
		range = range >> 1
		int bit = 0
		if (code >= range):
			code = code - range
			bit = 1
		r = (r << 1) | bit
		if (range < 16777216):
			range = range << 8
			code = (code << 8) | xzr_next(d)
	d.range = range
	d.code = code
	return r


int xzr_tree(xz_dec* d, int base, int bits):
	int* probs = d.probs
	int m = 1
	for i in range(bits): m = (m << 1) | xzr_bit(d, probs, base + m)
	return m - (1 << bits)


int xzr_reverse(xz_dec* d, int base, int bits):
	int* probs = d.probs
	int m = 1
	int sym = 0
	for i in range(bits):
		int bit = xzr_bit(d, probs, base + m)
		m = (m << 1) | bit
		sym = sym | (bit << i)
	return sym


# ---- LZMA -------------------------------------------------------------

# Sets lc/lp/pb from a properties byte; 0 when invalid (lc + lp > 4).
int xz_lzma_props(xz_dec* d, int props):
	if (props > 224): return 0
	d.pb = props / 45
	int rem = props % 45
	d.lp = rem / 9
	d.lc = rem % 9
	if (d.lc + d.lp > 4): return 0
	return 1


void xz_lzma_reset(xz_dec* d):
	int n = XZP_LITERAL + (768 << (d.lc + d.lp))
	int* probs = d.probs
	for i in range(n): probs[i] = 1024
	d.state = 0
	d.rep0 = 0
	d.rep1 = 0
	d.rep2 = 0
	d.rep3 = 0


# Match length minus 2.
int xz_lzma_len(xz_dec* d, int base, int pos_state):
	if (xzr_bit(d, d.probs, base) == 0): return xzr_tree(d, base + 2 + pos_state * 8, 3)
	if (xzr_bit(d, d.probs, base + 1) == 0): return 8 + xzr_tree(d, base + 130 + pos_state * 8, 3)
	return 16 + xzr_tree(d, base + 258, 8)


# Decodes symbols until out_len reaches limit, an end marker (allowed
# only when allow_eopm), or an error. A match running past limit is
# corrupt data. With cap_limit, limit is only the caller's output cap:
# decoding runs on to the end marker and fails with XZ_ERR_TOO_LARGE
# as soon as a symbol would write past it.
void xz_lzma_run(xz_dec* d, int limit, int allow_eopm, int cap_limit):
	int* probs = d.probs
	int pb_mask = (1 << d.pb) - 1
	int lp_mask = (1 << d.lp) - 1
	int lc = d.lc
	uint32 eopm_dist = -1
	while (((cap_limit != 0) || (d.out_len < limit)) && (d.error == 0)):
		xz_grow(d, 300)
		char* out = d.out
		int pos = d.out_len
		int rel = pos - d.dict_start
		int pos_state = rel & pb_mask
		int st = d.state
		if (xzr_bit(d, probs, XZP_IS_MATCH + st * 16 + pos_state) == 0):
			if (pos >= limit):
				xz_fail(d, XZ_ERR_TOO_LARGE)
				return
			int prev = 0
			if (rel > 0): prev = out[pos - 1] & 255
			int base = XZP_LITERAL + 768 * (((rel & lp_mask) << lc) + (prev >> (8 - lc)))
			int sym = 1
			if (st < 7):
				while (sym < 256): sym = (sym << 1) | xzr_bit(d, probs, base + sym)
			else:
				if ((d.rep0 < 0) || (d.rep0 >= rel)):
					xz_fail(d, XZ_ERR_DATA)
					return
				int match_byte = (out[pos - d.rep0 - 1] & 255) << 1
				int offset = 256
				while (sym < 256):
					int match_bit = match_byte & offset
					match_byte = match_byte << 1
					int bit = xzr_bit(d, probs, base + offset + match_bit + sym)
					sym = (sym << 1) | bit
					if (bit != 0): offset = match_bit
					else: offset = offset ^ match_bit
			out[pos] = sym & 255
			d.out_len = pos + 1
			if (st < 4): d.state = 0
			else if (st < 10): d.state = st - 3
			else: d.state = st - 6
			continue
		int length = 0
		if (xzr_bit(d, probs, XZP_IS_REP + st) == 0):
			# plain match
			d.rep3 = d.rep2
			d.rep2 = d.rep1
			d.rep1 = d.rep0
			length = xz_lzma_len(d, XZP_LEN_MATCH, pos_state)
			if (st < 7): d.state = 7
			else: d.state = 10
			int len_state = length
			if (len_state > 3): len_state = 3
			int slot = xzr_tree(d, XZP_DIST_SLOT + len_state * 64, 6)
			uint32 dist = slot
			if (slot >= 4):
				int direct = (slot >> 1) - 1
				dist = (2 | (slot & 1)) << direct
				if (slot < 14):
					dist = dist | xzr_reverse(d, XZP_DIST_SPECIAL + dist - slot - 1, direct)
				else:
					uint32 high = xzr_direct(d, direct - 4)
					dist = dist | (high << 4) | xzr_reverse(d, XZP_ALIGN, 4)
			if (dist == eopm_dist):
				if ((allow_eopm != 0) && (d.error == 0)): d.eopm = 1
				else: xz_fail(d, XZ_ERR_DATA)
				return
			d.rep0 = dist
		else if (xzr_bit(d, probs, XZP_IS_REP0 + st) == 0):
			if (xzr_bit(d, probs, XZP_IS_REP0_LONG + st * 16 + pos_state) == 0):
				# short rep: one byte at rep0
				if (st < 7): d.state = 9
				else: d.state = 11
				if ((d.rep0 < 0) || (d.rep0 >= rel)):
					xz_fail(d, XZ_ERR_DATA)
					return
				if (pos >= limit):
					xz_fail(d, XZ_ERR_TOO_LARGE)
					return
				out[pos] = out[pos - d.rep0 - 1]
				d.out_len = pos + 1
				continue
			length = xz_lzma_len(d, XZP_LEN_REP, pos_state)
			if (st < 7): d.state = 8
			else: d.state = 11
		else:
			int dist_rep = 0
			if (xzr_bit(d, probs, XZP_IS_REP1 + st) == 0):
				dist_rep = d.rep1
			else:
				if (xzr_bit(d, probs, XZP_IS_REP2 + st) == 0):
					dist_rep = d.rep2
				else:
					dist_rep = d.rep3
					d.rep3 = d.rep2
				d.rep2 = d.rep1
			d.rep1 = d.rep0
			d.rep0 = dist_rep
			length = xz_lzma_len(d, XZP_LEN_REP, pos_state)
			if (st < 7): d.state = 8
			else: d.state = 11
		if (d.error != 0): return
		# copy the match: rep0 + 1 bytes back, length + 2 bytes long
		int rep0 = d.rep0
		if ((rep0 < 0) || (rep0 >= rel)):
			xz_fail(d, XZ_ERR_DATA)
			return
		length = length + 2
		if (length > limit - pos):
			if (cap_limit != 0): xz_fail(d, XZ_ERR_TOO_LARGE)
			else: xz_fail(d, XZ_ERR_DATA)
			return
		int src = pos - rep0 - 1
		for k in range(length): out[pos + k] = out[src + k]
		d.out_len = pos + length


# ---- LZMA2 ------------------------------------------------------------

# Decodes LZMA2 chunks starting at p, bounded by end, through the 0x00
# end marker; leaves the position after it in d.vpos.
void xz_lzma2(xz_dec* d, int p, int end):
	int need_dict_reset = 1
	int need_props = 1
	while (d.error == 0):
		if (p >= end):
			xz_fail_bound(d, end)
			return
		int ctl = xz_u8(d, p)
		p = p + 1
		if (ctl == 0):
			d.vpos = p
			return
		if ((ctl >= 224) || (ctl == 1)):
			need_props = 1
			need_dict_reset = 0
			d.dict_start = d.out_len
		else if (need_dict_reset != 0):
			xz_fail(d, XZ_ERR_DATA)
			return
		if (ctl >= 128):
			int hdr = 4
			if (ctl >= 192): hdr = 5
			if (hdr > end - p):
				xz_fail_bound(d, end)
				return
			int unc = ((ctl & 31) << 16) + (xz_u8(d, p) << 8) + xz_u8(d, p + 1) + 1
			int comp = (xz_u8(d, p + 2) << 8) + xz_u8(d, p + 3) + 1
			p = p + 4
			if (ctl >= 192):
				if (xz_lzma_props(d, xz_u8(d, p)) == 0):
					xz_fail(d, XZ_ERR_DATA)
					return
				p = p + 1
				need_props = 0
				xz_lzma_reset(d)
			else if (need_props != 0):
				xz_fail(d, XZ_ERR_DATA)
				return
			else if (ctl >= 160):
				xz_lzma_reset(d)
			if (comp > end - p):
				xz_fail_bound(d, end)
				return
			if (xz_reserve(d, unc) == 0): return
			xzr_init(d, p, p + comp)
			xz_lzma_run(d, d.out_len + unc, 0, 0)
			if (d.error != 0): return
			uint32 code = d.code
			if ((d.rc_pos != p + comp) || (code != 0)):
				xz_fail(d, XZ_ERR_DATA)
				return
			p = p + comp
		else:
			if (ctl > 2):
				xz_fail(d, XZ_ERR_DATA)
				return
			if (2 > end - p):
				xz_fail_bound(d, end)
				return
			int size = (xz_u8(d, p) << 8) + xz_u8(d, p + 1) + 1
			p = p + 2
			if (size > end - p):
				xz_fail_bound(d, end)
				return
			if (xz_reserve(d, size) == 0): return
			mem_copy[char](&d.out[d.out_len], &d.in_data[p], size)
			d.out_len = d.out_len + size
			p = p + size


# ---- .xz container ----------------------------------------------------

# Reads a multibyte integer at p (bounded by end) and returns it, leaving
# the next position in d.vpos. Values of 2^31 and above, over-long and
# non-minimal encodings fail as corrupt data.
int xz_vli(xz_dec* d, int p, int end):
	int value = 0
	int shift = 0
	for i in range(9):
		if (p >= end):
			xz_fail_bound(d, end)
			return 0
		int b = xz_u8(d, p)
		p = p + 1
		int bits = b & 127
		if ((i > 0) && (b == 0)):
			xz_fail(d, XZ_ERR_DATA)
			return 0
		if ((shift > 28) && (bits != 0)):
			xz_fail(d, XZ_ERR_DATA)
			return 0
		if ((shift == 28) && (bits > 7)):
			xz_fail(d, XZ_ERR_DATA)
			return 0
		value = value | (bits << shift)
		shift = shift + 7
		if ((b & 128) == 0):
			d.vpos = p
			return value
	xz_fail(d, XZ_ERR_DATA)
	return 0


void xz_record(xz_dec* d, int unpadded, int uncompressed):
	if (d.record_count * 2 + 2 > d.record_cap):
		int cap = d.record_cap * 2
		if (cap < 16): cap = 16
		int* grown = cast(int*, malloc(cap * __word_size__))
		if (d.records != 0):
			mem_copy[int](grown, d.records, d.record_count * 2)
			free(d.records)
		d.records = grown
		d.record_cap = cap
	d.records[d.record_count * 2] = unpadded
	d.records[d.record_count * 2 + 1] = uncompressed
	d.record_count = d.record_count + 1


# Parses the filter flags of a block header into delta[]/deltas; returns
# the position after them.
int xz_block_filters(xz_dec* d, int q, int hend, int filters, int* delta, int* deltas_out):
	int p = q
	int deltas = 0
	for f in range(filters):
		if (d.error != 0): return p
		int id = xz_vli(d, q, hend)
		q = d.vpos
		int psize = xz_vli(d, q, hend)
		q = d.vpos
		if (d.error != 0): return p
		if (psize > hend - q):
			xz_fail(d, XZ_ERR_DATA)
			return p
		if (f == filters - 1):
			if (id != 33):
				xz_fail(d, XZ_ERR_OPTIONS)
				return p
			if ((psize != 1) || ((xz_u8(d, q) & 192) != 0)):
				xz_fail(d, XZ_ERR_OPTIONS)
				return p
			if (xz_u8(d, q) > 40):
				xz_fail(d, XZ_ERR_OPTIONS)
				return p
		else if ((id == 3) && (psize == 1)):
			delta[deltas] = xz_u8(d, q) + 1
			deltas = deltas + 1
			*deltas_out = deltas
		else:
			xz_fail(d, XZ_ERR_OPTIONS)
			return p
		q = q + psize
	return q


# The rest of a block: header padding, LZMA2 data, filters, block
# padding and check. p is the header start, q the end of the filters.
int xz_block_body(xz_dec* d, int p, int q, int hend, int comp_size, int unc_size, int check_id, int* delta, int deltas):
	int hsize = hend + 4 - p
	while (q < hend):
		if (xz_u8(d, q) != 0):
			xz_fail(d, XZ_ERR_OPTIONS)
			return p
		q = q + 1
	int data_start = p + hsize
	int end = d.in_len
	if (comp_size >= 0):
		if (comp_size > d.in_len - data_start):
			xz_fail(d, XZ_ERR_TRUNCATED)
			return p
		end = data_start + comp_size
	int out_start = d.out_len
	xz_lzma2(d, data_start, end)
	if (d.error != 0): return p
	int comp = d.vpos - data_start
	int produced = d.out_len - out_start
	if ((comp_size >= 0) && (comp != comp_size)):
		xz_fail(d, XZ_ERR_DATA)
		return p
	if ((unc_size >= 0) && (produced != unc_size)):
		xz_fail(d, XZ_ERR_DATA)
		return p
	# undo the filters before LZMA2, last one first
	char* out = d.out
	int fi = deltas - 1
	while (fi >= 0):
		int dist = delta[fi]
		for i in range(out_start + dist, d.out_len):
			out[i] = (out[i] + out[i - dist]) & 255
		fi = fi - 1
	q = d.vpos
	while (((q - data_start) & 3) != 0):
		if (q >= d.in_len):
			xz_fail(d, XZ_ERR_TRUNCATED)
			return p
		if (xz_u8(d, q) != 0):
			xz_fail(d, XZ_ERR_DATA)
			return p
		q = q + 1
	int csize = xz_check_size(check_id)
	if (csize > d.in_len - q):
		xz_fail(d, XZ_ERR_TRUNCATED)
		return p
	if (xz_check_ok(d, check_id, out_start, produced, q) == 0):
		xz_fail(d, XZ_ERR_CHECK)
		return p
	xz_record(d, hsize + comp + csize, produced)
	return q + csize


# Decodes one block whose header starts at p; returns the position after
# its check field.
int xz_block(xz_dec* d, int p, int check_id):
	int hsize = (xz_u8(d, p) + 1) * 4
	if (hsize > d.in_len - p):
		xz_fail(d, XZ_ERR_TRUNCATED)
		return p
	int hend = p + hsize - 4
	if (xz_crc32_ok(d, p, hsize - 4, hend) == 0):
		xz_fail(d, XZ_ERR_DATA)
		return p
	int flags = xz_u8(d, p + 1)
	if ((flags & 60) != 0):
		xz_fail(d, XZ_ERR_OPTIONS)
		return p
	int filters = (flags & 3) + 1
	int q = p + 2
	int comp_size = -1
	int unc_size = -1
	if ((flags & 64) != 0):
		comp_size = xz_vli(d, q, hend)
		q = d.vpos
		if ((d.error == 0) && (comp_size == 0)): xz_fail(d, XZ_ERR_DATA)
	if ((flags & 128) != 0):
		unc_size = xz_vli(d, q, hend)
		q = d.vpos
	int* delta = cast(int*, malloc(4 * __word_size__))
	int deltas = 0
	q = xz_block_filters(d, q, hend, filters, delta, &deltas)
	if (d.error == 0): q = xz_block_body(d, p, q, hend, comp_size, unc_size, check_id, delta, deltas)
	free(delta)
	return q


# The stream header magic FD 37 7A 58 5A 00 ("\xfd7zXZ\0"), byte i.
int xz_magic_byte(int i):
	if (i == 0): return 253
	if (i == 1): return 55
	if (i == 2): return 122
	if (i == 3): return 88
	if (i == 4): return 90
	return 0


# How many leading magic bytes in[p..) matches (at most 6).
int xz_magic_match(xz_dec* d, int p):
	int i = 0
	while ((i < 6) && (p + i < d.in_len)):
		if (xz_u8(d, p + i) != xz_magic_byte(i)): return i
		i = i + 1
	return i


int xz_has_magic(xz_dec* d, int p):
	return xz_magic_match(d, p) == 6


# 1 when in[p..) is a proper prefix of the stream magic (input cut short).
int xz_magic_prefix(xz_dec* d, int p):
	return (d.in_len - p < 6) && (xz_magic_match(d, p) == d.in_len - p)


# Decodes one .xz stream at p; returns the position after its footer.
int xz_stream(xz_dec* d, int p):
	if (xz_has_magic(d, p) == 0):
		if (xz_magic_prefix(d, p)): xz_fail(d, XZ_ERR_TRUNCATED)
		else: xz_fail(d, XZ_ERR_FORMAT)
		return p
	if (d.in_len - p < 12):
		xz_fail(d, XZ_ERR_TRUNCATED)
		return p
	if (xz_crc32_ok(d, p + 6, 2, p + 8) == 0):
		xz_fail(d, XZ_ERR_DATA)
		return p
	int flag0 = xz_u8(d, p + 6)
	int flag1 = xz_u8(d, p + 7)
	if ((flag0 != 0) || ((flag1 & 240) != 0)):
		xz_fail(d, XZ_ERR_OPTIONS)
		return p
	int check_id = flag1
	d.record_count = 0
	int q = p + 12
	while (1):
		if (q >= d.in_len):
			xz_fail(d, XZ_ERR_TRUNCATED)
			return p
		if (xz_u8(d, q) == 0): break
		q = xz_block(d, q, check_id)
		if (d.error != 0): return p
	# index
	int index_start = q
	q = q + 1
	int count = xz_vli(d, q, d.in_len)
	q = d.vpos
	if (d.error != 0): return p
	if (count != d.record_count):
		xz_fail(d, XZ_ERR_DATA)
		return p
	for i in range(count):
		int unpadded = xz_vli(d, q, d.in_len)
		q = d.vpos
		int uncompressed = xz_vli(d, q, d.in_len)
		q = d.vpos
		if (d.error != 0): return p
		if ((unpadded != d.records[i * 2]) || (uncompressed != d.records[i * 2 + 1])):
			xz_fail(d, XZ_ERR_DATA)
			return p
	while (((q - index_start) & 3) != 0):
		if (q >= d.in_len):
			xz_fail(d, XZ_ERR_TRUNCATED)
			return p
		if (xz_u8(d, q) != 0):
			xz_fail(d, XZ_ERR_DATA)
			return p
		q = q + 1
	if (d.in_len - q < 4):
		xz_fail(d, XZ_ERR_TRUNCATED)
		return p
	if (xz_crc32_ok(d, index_start, q - index_start, q) == 0):
		xz_fail(d, XZ_ERR_DATA)
		return p
	q = q + 4
	int index_size = q - index_start
	# footer
	if (d.in_len - q < 12):
		xz_fail(d, XZ_ERR_TRUNCATED)
		return p
	if ((xz_u8(d, q + 10) != 89) || (xz_u8(d, q + 11) != 90)):
		xz_fail(d, XZ_ERR_DATA)
		return p
	if (xz_crc32_ok(d, q + 4, 6, q) == 0):
		xz_fail(d, XZ_ERR_DATA)
		return p
	uint32 backward = xz_le32(d, q + 4)
	uint32 want_backward = index_size / 4 - 1
	if ((backward != want_backward) || (xz_u8(d, q + 8) != flag0) || (xz_u8(d, q + 9) != flag1)):
		xz_fail(d, XZ_ERR_DATA)
		return p
	return q + 12


# ---- LZMA_alone -------------------------------------------------------

# Decodes one .lzma stream at p; returns the position after it. picky is
# liblzma's auto-detection strictness (dictionary sizes of the form 2^n
# or 2^n + 2^(n-1) only).
int xz_alone(xz_dec* d, int p, int picky):
	int n = d.in_len - p
	if (n < 1):
		xz_fail(d, XZ_ERR_TRUNCATED)
		return p
	if (xz_lzma_props(d, xz_u8(d, p)) == 0):
		if (xz_u8(d, p) > 224): xz_fail(d, XZ_ERR_FORMAT)
		else: xz_fail(d, XZ_ERR_OPTIONS)
		return p
	if (n < 5):
		xz_fail(d, XZ_ERR_TRUNCATED)
		return p
	if (picky != 0):
		uint32 dict_size = xz_le32(d, p + 1)
		uint32 all = -1
		if (dict_size != all):
			uint32 x = dict_size - 1
			x = x | (x >> 2)
			x = x | (x >> 3)
			x = x | (x >> 4)
			x = x | (x >> 8)
			x = x | (x >> 16)
			x = x + 1
			if (x != dict_size):
				xz_fail(d, XZ_ERR_FORMAT)
				return p
	if (n < 13):
		xz_fail(d, XZ_ERR_TRUNCATED)
		return p
	int known = 0
	for i in range(8):
		if (xz_u8(d, p + 5 + i) != 255): known = 1
	int size = 0
	if (known != 0):
		if ((xz_u8(d, p + 8) > 127) || (xz_le32(d, p + 9) != 0)):
			if (picky != 0): xz_fail(d, XZ_ERR_FORMAT)
			else: xz_fail(d, XZ_ERR_TOO_LARGE)
			return p
		size = xz_le32(d, p + 5)
	xz_lzma_reset(d)
	d.dict_start = d.out_len
	d.eopm = 0
	xzr_init(d, p + 13, d.in_len)
	if (d.error != 0): return p
	if (known != 0):
		if (xz_reserve(d, size) == 0): return p
		xz_lzma_run(d, d.out_len + size, 1, 0)
	else:
		int limit = 2147483647
		if (d.max_output >= 0): limit = d.max_output
		xz_lzma_run(d, limit, 1, 1)
	if (d.error != 0): return p
	if (d.eopm != 0):
		uint32 code = d.code
		if ((code != 0) || ((known != 0) && (d.out_len - d.dict_start != size))):
			xz_fail(d, XZ_ERR_DATA)
			return p
	return d.rc_pos


# ---- driver -----------------------------------------------------------

void xz_dec_free(xz_dec* d):
	if (d.out != 0): free(d.out)
	free(d.probs)
	if (d.records != 0): free(d.records)
	if (d.crc32_tab != 0): free(d.crc32_tab)
	if (d.crc64_hi != 0): free(d.crc64_hi)
	if (d.crc64_lo != 0): free(d.crc64_lo)
	free(d)


char* xz_run(char* data, int len, int max_output, int mode, int* out_len, int* out_error):
	*out_len = 0
	*out_error = XZ_OK
	if (len < 0): len = 0
	xz_dec* d = new xz_dec
	d.in_data = data
	d.in_len = len
	d.rc_pos = 0
	d.rc_limit = 0
	d.range = 0
	d.code = 0
	d.out_cap = 64
	d.out = cast(char*, malloc(64))
	d.out_len = 0
	d.max_output = max_output
	if (max_output <= 0): d.max_output = -1
	d.dict_start = 0
	d.probs = cast(int*, malloc(XZP_TOTAL * __word_size__))
	d.lc = 0
	d.lp = 0
	d.pb = 0
	d.state = 0
	d.rep0 = 0
	d.rep1 = 0
	d.rep2 = 0
	d.rep3 = 0
	d.eopm = 0
	d.error = 0
	d.vpos = 0
	d.records = 0
	d.record_count = 0
	d.record_cap = 0
	d.crc32_tab = 0
	d.crc64_hi = 0
	d.crc64_lo = 0

	int p = 0
	int streams = 0
	int prev_xz = 0
	while (1):
		if (streams > 0):
			if (p >= len): break
			if (prev_xz != 0):
				# stream padding: zero bytes, a multiple of four in all
				int pad = 0
				while ((p < len) && (xz_u8(d, p) == 0)):
					p = p + 1
					pad = pad + 1
				if ((pad & 3) != 0):
					d.error = XZ_ERR_DATA
					break
				if (p >= len): break
		int mark = d.out_len
		int is_xz = 0
		if (mode == XZ_MODE_XZ): is_xz = 1
		else if ((mode == XZ_MODE_AUTO) && (len > p) && (xz_u8(d, p) == 253)): is_xz = 1
		int next = p
		if (is_xz != 0): next = xz_stream(d, p)
		else: next = xz_alone(d, p, mode == XZ_MODE_AUTO)
		if (d.error != 0):
			# Python keeps the earlier streams and drops trailing data
			# that is not a valid stream -- unless it is only truncated.
			if ((streams == 0) || (d.error == XZ_ERR_TRUNCATED)): break
			d.error = 0
			d.out_len = mark
			break
		streams = streams + 1
		prev_xz = is_xz
		p = next

	if (d.error != 0):
		*out_error = d.error
		xz_dec_free(d)
		return 0
	char* out = d.out
	out[d.out_len] = 0
	*out_len = d.out_len
	d.out = 0
	xz_dec_free(d)
	return out


# One-shot .xz decode (Python lzma.decompress(data, format=FORMAT_XZ)).
char* xz_decompress(char* data, int len, int max_output, int* out_len, int* out_error):
	return xz_run(data, len, max_output, XZ_MODE_XZ, out_len, out_error)


# One-shot legacy .lzma decode (format=FORMAT_ALONE).
char* lzma_alone_decompress(char* data, int len, int max_output, int* out_len, int* out_error):
	return xz_run(data, len, max_output, XZ_MODE_ALONE, out_len, out_error)


# One-shot decode with per-stream format detection (format=FORMAT_AUTO,
# lzma.decompress's default): .xz when a stream starts with 0xFD, else
# a strictly validated .lzma header.
char* lzma_decompress(char* data, int len, int max_output, int* out_len, int* out_error):
	return xz_run(data, len, max_output, XZ_MODE_AUTO, out_len, out_error)
