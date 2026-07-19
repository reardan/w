/*
libs/extras/compress/inflate.w: a fully conformant RFC 1951 DEFLATE
inflater -- stored, fixed-Huffman, and dynamic-Huffman blocks, plus
back-reference copying. Stage 1 of docs/projects/compress.md (§3):
"inflate first," so this must decode any spec-legal DEFLATE stream,
including ones this package's own (initially stored-blocks-only)
deflate.w never produces -- real-world producers (git, gzip(1), zlib,
browsers) use dynamic Huffman routinely, and reading their output is the
entire point of this package (§0's "gateway to git-format interop").

Canonical Huffman decode is the puff.c (Mark Adler, public-domain zlib
contrib) construction/decode shape referenced in the design doc §2.2:
count[] per code length plus a symbols-sorted-by-code array, decoded by
comparing an accumulated bit value against per-length boundaries -- table
lookups over two flat arrays, never an explicit tree (§6.2). construct()
tolerates one specific "incomplete code" case beyond a perfectly complete
assignment: at most one used symbol, of length <= 1 (n == count[0] +
count[1]) -- the shape a real encoder emits for a distance table when a
block contains no back-references at all (HDIST's minimum declared count
is 1, so the placeholder code is unavoidable even when never used).
Every other incomplete or over-subscribed table is INFLATE_ERR_BAD_HUFFMAN.

Bit order (RFC 1951 §3.1.1): ordinary multi-bit fields (LEN, HLIT, extra
bits, ...) are read LSB-first -- the first bit off the stream becomes the
low bit of the value. Huffman codes are packed MSB-first, so a decoder
builds up the accumulated code value as `(code << 1) | next_bit` one bit
at a time, comparing against the per-length symbol-count boundaries.

W-specific hazards (docs/projects/compress.md §6.1, §6.2):
  - Every quantity here (Huffman codes <= 15 bits, lengths <= 258,
    distances <= 32768) fits one masked 32-bit word; no int64/hi-lo pairs
    needed anywhere (contrast lib/sha256.w's 64-bit message length).
  - The lookup tables (length/distance base+extra, the code-length
    alphabet's transmission order) are small and entirely non-negative,
    so no bit-31 literal hazard applies to them -- unlike crc32.w's
    polynomial, they can be written directly, and are parsed here from a
    single decimal string per table (inf_parse_csv) rather than as ~130
    lines of individual index assignments, purely to keep the file
    readable; the values themselves are RFC 1951 §3.2.5's own table.
  - Canonical Huffman tables (count[]/symbol[] arrays) and the codepoint
    tables below are allocated a handful of times per inflate() call
    (once per block, not once per symbol), matching §6.2's allocator
    guidance; the two fixed-Huffman tables (spec-constant, needed by
    every stream with a BTYPE=01 block) are built once and cached for the
    process, like crc32.w's table.
  - Output grows through structures.string.string_builder (amortized
    doubling, binary-safe), detached into a plain char* + int pair with
    the "free the wrapper, not string_free" idiom libs/extras/vcs/cas.w's
    cas_fanout_dir already uses, to hand back inflate_result without an
    extra copy.

Beyond the design doc's API sketch (§5.2): inflate_ex() is the same
inflate() plus a *consumed out-parameter (bytes read from `data`, rounded
up to the next byte boundary if the stream ended mid-byte). inflate()
itself is documented and unchanged; inflate_ex() exists because zlib.w
and gzip.w need to know exactly where the compressed payload ends within
their input buffer to find the trailer (Adler-32/CRC-32 + size) that
follows it -- the doc's two-field {data, length} inflate_result has no
room for that, and adding a field to the documented public struct felt
like a bigger API change than a second, explicitly-internal-use entry
point. inflate() is a two-line wrapper that discards the count.
*/
import lib.memory
import lib.result
import structures.string


int INFLATE_OK():
	return 0


int INFLATE_ERR_BAD_BTYPE():
	return 1


int INFLATE_ERR_BAD_STORED_LEN():
	return 2


int INFLATE_ERR_BAD_HUFFMAN():
	return 3


int INFLATE_ERR_BAD_DISTANCE():
	return 4


int INFLATE_ERR_TRUNCATED():
	return 5


int INFLATE_ERR_TOO_LARGE():
	return 6


char* inflate_error_string(int code):
	if (code == INFLATE_OK()):
		return c"inflate: ok"
	if (code == INFLATE_ERR_BAD_BTYPE()):
		return c"inflate: reserved block type (BTYPE == 11)"
	if (code == INFLATE_ERR_BAD_STORED_LEN()):
		return c"inflate: stored block NLEN is not the one's complement of LEN"
	if (code == INFLATE_ERR_BAD_HUFFMAN()):
		return c"inflate: over-subscribed, incomplete, or invalid Huffman code"
	if (code == INFLATE_ERR_BAD_DISTANCE()):
		return c"inflate: back-reference distance points before the start of output"
	if (code == INFLATE_ERR_TRUNCATED()):
		return c"inflate: input ended mid-block"
	if (code == INFLATE_ERR_TOO_LARGE()):
		return c"inflate: output exceeded the caller's max_output cap"
	return c"inflate: unknown error"


struct inflate_result:
	char* data
	int length


void inflate_result_free(inflate_result* r):
	free(r.data)
	free(r)


# A canonical Huffman table: count[len] for len in 0..15 (count[0] is the
# number of unused/zero-length symbols) and symbol[], the n symbols
# sorted by (length, then symbol number ascending) -- RFC 1951 §3.2.2's
# own construction. Built fresh per block (a handful of allocations per
# inflate() call, never per symbol; docs/projects/compress.md §6.2).
struct whuff:
	int* count
	int* symbol


int wh_maxbits():
	return 15


whuff* wh_new(int n):
	whuff* h = new whuff
	h.count = cast(int*, malloc((wh_maxbits() + 1) * __word_size__))
	h.symbol = cast(int*, malloc(n * __word_size__))
	return h


void wh_free(whuff* h):
	free(h.count)
	free(h.symbol)
	free(h)


# Returns 0 for a complete valid code, a negative value if the lengths
# are over-subscribed (invalid at any code length), or a positive value
# if the code is incomplete (valid only in the single-short-code special
# case the caller checks separately; see wh_build).
int wh_construct(whuff* h, int* lengths, int n):
	int len = 0
	while (len <= wh_maxbits()):
		h.count[len] = 0
		len = len + 1
	int symbol = 0
	while (symbol < n):
		h.count[lengths[symbol]] = h.count[lengths[symbol]] + 1
		symbol = symbol + 1
	if (h.count[0] == n):
		return 0

	int left = 1
	len = 1
	while (len <= wh_maxbits()):
		left = left * 2 - h.count[len]
		if (left < 0):
			return left
		len = len + 1

	int* offs = cast(int*, malloc((wh_maxbits() + 1) * __word_size__))
	offs[1] = 0
	len = 1
	while (len < wh_maxbits()):
		offs[len + 1] = offs[len] + h.count[len]
		len = len + 1
	symbol = 0
	while (symbol < n):
		if (lengths[symbol] != 0):
			offs[lengths[symbol]] = offs[lengths[symbol]] + 1
			h.symbol[offs[lengths[symbol]] - 1] = symbol
		symbol = symbol + 1
	free(offs)
	return left


# The bitstream state shared by every helper below: input position (byte
# + bit-within-byte, LSB first), the growable output buffer, the
# decompression-bomb cap, and a sticky error/status code. Every reader
# and emitter checks/sets `status`; once non-zero, further reads are
# no-ops (so a truncated or malformed stream unwinds cleanly without
# every call site re-checking every intermediate result).
struct winflate_ctx:
	char* in_data
	int in_length
	int byte_pos
	int bit_pos
	string_builder* out
	int max_output
	int status


int inf_get_bit(winflate_ctx* c):
	if (c.status != 0):
		return 0
	if (c.byte_pos >= c.in_length):
		c.status = INFLATE_ERR_TRUNCATED()
		return 0
	int b = shr(c.in_data[c.byte_pos] & 255, c.bit_pos) & 1
	c.bit_pos = c.bit_pos + 1
	if (c.bit_pos == 8):
		c.bit_pos = 0
		c.byte_pos = c.byte_pos + 1
	return b


# Non-Huffman multi-bit field: LSB-first, so the first bit read becomes
# the field's low bit.
int inf_get_bits(winflate_ctx* c, int n):
	int v = 0
	int i = 0
	while (i < n):
		v = v | (inf_get_bit(c) << i)
		i = i + 1
	return v


void inf_align_byte(winflate_ctx* c):
	if (c.status != 0):
		return
	if (c.bit_pos != 0):
		c.bit_pos = 0
		c.byte_pos = c.byte_pos + 1


# puff.c's decode(): accumulate one bit at a time (MSB-first per RFC
# 1951 §3.1.1) and compare against the per-length symbol-count window,
# rather than building an explicit code->symbol map. Returns -1 (with
# c.status left at 0) when the bits read so far match no valid code of
# any length up to wh_maxbits() -- the caller distinguishes "ran out of
# codes" (bad table) from "ran out of input" (c.status already set) by
# checking c.status first.
int wh_decode(winflate_ctx* c, whuff* h):
	int code = 0
	int first = 0
	int index = 0
	int len = 1
	while (len <= wh_maxbits()):
		code = code | inf_get_bit(c)
		if (c.status != 0):
			return -1
		int count = h.count[len]
		if ((code - first) < count):
			return h.symbol[index + (code - first)]
		index = index + count
		first = first + count
		first = first << 1
		code = code << 1
		len = len + 1
	return -1


# Decodes one symbol and folds every failure mode (truncated input, or a
# bit sequence matching no code) into c.status, so call sites only need
# to check c.status once afterwards.
int inf_decode_symbol(winflate_ctx* c, whuff* h):
	int sym = wh_decode(c, h)
	if (c.status != 0):
		return -1
	if (sym < 0):
		c.status = INFLATE_ERR_BAD_HUFFMAN()
		return -1
	return sym


# Validates a just-built table against wh_construct()'s return value,
# applying the single-short-code tolerance described in this file's
# header comment. Sets c.status and returns 0 on any other incomplete or
# over-subscribed table.
int wh_build(winflate_ctx* c, whuff* h, int* lengths, int n):
	if (c.status != 0):
		return 0
	int left = wh_construct(h, lengths, n)
	if (left != 0):
		int single_short_code = n == (h.count[0] + h.count[1])
		if ((left < 0) || (single_short_code == 0)):
			c.status = INFLATE_ERR_BAD_HUFFMAN()
			return 0
	return 1


void inf_emit_byte(winflate_ctx* c, int b):
	if (c.status != 0):
		return
	if ((c.max_output > 0) && (c.out.length >= c.max_output)):
		c.status = INFLATE_ERR_TOO_LARGE()
		return
	string_append_char(c.out, b)


# Copies `length` bytes from `distance` bytes back in the output produced
# so far. Distance can be less than length (the copy overlaps itself --
# e.g. distance 1 means "repeat the last byte"), so this reads and
# appends one byte at a time rather than a bulk copy that would assume
# non-overlapping ranges (docs/projects/compress.md §2.1).
void inf_copy_match(winflate_ctx* c, int length, int distance):
	if (c.status != 0):
		return
	if ((distance <= 0) || (distance > c.out.length)):
		c.status = INFLATE_ERR_BAD_DISTANCE()
		return
	int i = 0
	while (i < length):
		if (c.status != 0):
			return
		int b = c.out.data[c.out.length - distance] & 255
		inf_emit_byte(c, b)
		i = i + 1


/* RFC 1951 §3.2.5 / §3.2.7 constant tables */


# Parses a comma-separated run of non-negative decimal integers into a
# malloc'd array of exactly n entries -- every value here is small and
# non-negative (no bit-31 hazard), so this is just a compact way to spell
# five RFC tables without ~130 lines of individual index assignments.
int* inf_parse_csv(char* s, int n):
	int* out = cast(int*, malloc(n * __word_size__))
	int idx = 0
	int i = 0
	while (idx < n):
		int v = 0
		while ((s[i] >= '0') && (s[i] <= '9')):
			v = v * 10 + (s[i] - '0')
			i = i + 1
		out[idx] = v
		idx = idx + 1
		if (s[i] == ','):
			i = i + 1
	return out


int* inf_length_base_cache
int* inf_length_extra_cache
int* inf_dist_base_cache
int* inf_dist_extra_cache
int* inf_clc_order_cache


void inf_init_tables():
	if (inf_length_base_cache != 0):
		return
	# Length symbols 257-285: base length + extra-bit count (RFC 1951
	# §3.2.5's table, indexed by symbol - 257).
	inf_length_base_cache = inf_parse_csv(c"3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258", 29)
	inf_length_extra_cache = inf_parse_csv(c"0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0", 29)
	# Distance symbols 0-29: base distance + extra-bit count.
	inf_dist_base_cache = inf_parse_csv(c"1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577", 30)
	inf_dist_extra_cache = inf_parse_csv(c"0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13", 30)
	# The code-length alphabet's transmission order (RFC 1951 §3.2.7):
	# dynamic-block headers send HCLEN 3-bit lengths in this symbol order.
	inf_clc_order_cache = inf_parse_csv(c"16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15", 19)


int inf_length_base(int idx):
	inf_init_tables()
	return inf_length_base_cache[idx]


int inf_length_extra(int idx):
	inf_init_tables()
	return inf_length_extra_cache[idx]


int inf_dist_base(int idx):
	inf_init_tables()
	return inf_dist_base_cache[idx]


int inf_dist_extra(int idx):
	inf_init_tables()
	return inf_dist_extra_cache[idx]


int inf_clc_order(int idx):
	inf_init_tables()
	return inf_clc_order_cache[idx]


# Length symbol (257-285) -> full length (base + extra bits, read LSB
# first like every other non-Huffman field).
int inf_read_length(winflate_ctx* c, int sym):
	int idx = sym - 257
	int extra = inf_length_extra(idx)
	int extra_bits = 0
	if (extra > 0):
		extra_bits = inf_get_bits(c, extra)
	return inf_length_base(idx) + extra_bits


# Distance symbol (0-29) -> full distance.
int inf_read_distance(winflate_ctx* c, int dsym):
	int extra = inf_dist_extra(dsym)
	int extra_bits = 0
	if (extra > 0):
		extra_bits = inf_get_bits(c, extra)
	return inf_dist_base(dsym) + extra_bits


/* Block bodies */


# Shared literal/length + distance symbol loop, used by both fixed and
# dynamic Huffman blocks (they differ only in which tables were built).
void inf_huffman_block(winflate_ctx* c, whuff* litlen, whuff* dist):
	while (c.status == 0):
		int sym = inf_decode_symbol(c, litlen)
		if (c.status != 0):
			return
		if (sym < 256):
			inf_emit_byte(c, sym)
		else if (sym == 256):
			return
		else if (sym <= 285):
			int length = inf_read_length(c, sym)
			if (c.status != 0):
				return
			int dsym = inf_decode_symbol(c, dist)
			if (c.status != 0):
				return
			# Distance symbols 30-31 have fixed-table codes assigned (the
			# code space is complete) but no defined meaning -- RFC 1951
			# §3.2.5: "will never actually occur in the compressed data."
			if (dsym > 29):
				c.status = INFLATE_ERR_BAD_HUFFMAN()
				return
			int distance = inf_read_distance(c, dsym)
			if (c.status != 0):
				return
			inf_copy_match(c, length, distance)
		else:
			# Symbols 286-287: assigned fixed-table codes but never used
			# by any valid stream (RFC 1951 §3.2.6).
			c.status = INFLATE_ERR_BAD_HUFFMAN()
			return


void inf_stored_block(winflate_ctx* c):
	inf_align_byte(c)
	if (c.status != 0):
		return
	if (c.byte_pos + 4 > c.in_length):
		c.status = INFLATE_ERR_TRUNCATED()
		return
	int len = (c.in_data[c.byte_pos] & 255) | ((c.in_data[c.byte_pos + 1] & 255) << 8)
	int nlen = (c.in_data[c.byte_pos + 2] & 255) | ((c.in_data[c.byte_pos + 3] & 255) << 8)
	c.byte_pos = c.byte_pos + 4
	if ((len ^ 65535) != nlen):
		c.status = INFLATE_ERR_BAD_STORED_LEN()
		return
	if (c.byte_pos + len > c.in_length):
		c.status = INFLATE_ERR_TRUNCATED()
		return
	if ((c.max_output > 0) && (c.out.length + len > c.max_output)):
		c.status = INFLATE_ERR_TOO_LARGE()
		return
	string_append_bytes(c.out, &c.in_data[c.byte_pos], len)
	c.byte_pos = c.byte_pos + len


whuff* inf_fixed_litlen_cache
whuff* inf_fixed_dist_cache


whuff* inf_fixed_litlen_table():
	if (inf_fixed_litlen_cache == 0):
		int* lengths = cast(int*, malloc(288 * __word_size__))
		int i = 0
		while (i < 144):
			lengths[i] = 8
			i = i + 1
		while (i < 256):
			lengths[i] = 9
			i = i + 1
		while (i < 280):
			lengths[i] = 7
			i = i + 1
		while (i < 288):
			lengths[i] = 8
			i = i + 1
		whuff* h = wh_new(288)
		wh_construct(h, lengths, 288)
		free(lengths)
		inf_fixed_litlen_cache = h
	return inf_fixed_litlen_cache


whuff* inf_fixed_dist_table():
	if (inf_fixed_dist_cache == 0):
		int* lengths = cast(int*, malloc(32 * __word_size__))
		int i = 0
		while (i < 32):
			lengths[i] = 5
			i = i + 1
		whuff* h = wh_new(32)
		wh_construct(h, lengths, 32)
		free(lengths)
		inf_fixed_dist_cache = h
	return inf_fixed_dist_cache


void inf_fixed_block(winflate_ctx* c):
	inf_huffman_block(c, inf_fixed_litlen_table(), inf_fixed_dist_table())


# Reads HLIT/HDIST/HCLEN and the HCLEN 3-bit code-length-alphabet
# lengths, builds that small table, then uses it to decode the `total`
# combined literal/length + distance code lengths (run-length symbols
# 16/17/18 repeat a previous or zero length -- RFC 1951 §3.2.7).
void inf_dynamic_block(winflate_ctx* c):
	int hlit = inf_get_bits(c, 5) + 257
	int hdist = inf_get_bits(c, 5) + 1
	int hclen = inf_get_bits(c, 4) + 4
	if (c.status != 0):
		return

	int* cl_lengths = cast(int*, malloc(19 * __word_size__))
	int i = 0
	while (i < 19):
		cl_lengths[i] = 0
		i = i + 1
	i = 0
	while (i < hclen):
		cl_lengths[inf_clc_order(i)] = inf_get_bits(c, 3)
		i = i + 1
	if (c.status != 0):
		free(cl_lengths)
		return

	whuff* cl_huff = wh_new(19)
	int cl_ok = wh_build(c, cl_huff, cl_lengths, 19)
	free(cl_lengths)
	if (cl_ok == 0):
		wh_free(cl_huff)
		return

	int total = hlit + hdist
	int* lengths = cast(int*, malloc(total * __word_size__))
	i = 0
	int prev = 0
	while (i < total):
		if (c.status != 0):
			break
		int sym = inf_decode_symbol(c, cl_huff)
		if (c.status != 0):
			break
		if (sym < 16):
			lengths[i] = sym
			prev = sym
			i = i + 1
		else if (sym == 16):
			if (i == 0):
				c.status = INFLATE_ERR_BAD_HUFFMAN()
				break
			int rep = inf_get_bits(c, 2) + 3
			if ((c.status != 0) || (i + rep > total)):
				if (c.status == 0):
					c.status = INFLATE_ERR_BAD_HUFFMAN()
				break
			int k = 0
			while (k < rep):
				lengths[i] = prev
				i = i + 1
				k = k + 1
		else if (sym == 17):
			int rep = inf_get_bits(c, 3) + 3
			if ((c.status != 0) || (i + rep > total)):
				if (c.status == 0):
					c.status = INFLATE_ERR_BAD_HUFFMAN()
				break
			int k = 0
			while (k < rep):
				lengths[i] = 0
				i = i + 1
				k = k + 1
			prev = 0
		else:
			int rep = inf_get_bits(c, 7) + 11
			if ((c.status != 0) || (i + rep > total)):
				if (c.status == 0):
					c.status = INFLATE_ERR_BAD_HUFFMAN()
				break
			int k = 0
			while (k < rep):
				lengths[i] = 0
				i = i + 1
				k = k + 1
			prev = 0
	wh_free(cl_huff)
	if (c.status != 0):
		free(lengths)
		return

	whuff* litlen_huff = wh_new(hlit)
	int litlen_ok = wh_build(c, litlen_huff, lengths, hlit)
	whuff* dist_huff = wh_new(hdist)
	int dist_ok = 0
	if (litlen_ok != 0):
		# Pointer arithmetic on a typed pointer is a raw byte offset in
		# this language -- plain `lengths + hlit` would land `hlit` BYTES
		# past `lengths`, not `hlit` ints past it (this is exactly the
		# bug that used to live here, see
		# docs/projects/ai_tooling_next_steps.md). `&lengths[hlit]`
		# indexes instead of adding, so it scales by int's width
		# automatically -- no manual `* __word_size__`.
		dist_ok = wh_build(c, dist_huff, &lengths[hlit], hdist)
	free(lengths)
	if ((litlen_ok != 0) && (dist_ok != 0)):
		inf_huffman_block(c, litlen_huff, dist_huff)
	wh_free(litlen_huff)
	wh_free(dist_huff)


/* Top level */


wresult[inflate_result*]* inflate_ex(char* data, int length, int max_output, int* consumed):
	if (length < 0):
		length = 0
	winflate_ctx* c = new winflate_ctx
	c.in_data = data
	c.in_length = length
	c.byte_pos = 0
	c.bit_pos = 0
	c.out = string_new()
	c.max_output = max_output
	c.status = 0

	int bfinal = 0
	while ((bfinal == 0) && (c.status == 0)):
		bfinal = inf_get_bits(c, 1)
		int btype = inf_get_bits(c, 2)
		if (c.status != 0):
			break
		if (btype == 0):
			inf_stored_block(c)
		else if (btype == 1):
			inf_fixed_block(c)
		else if (btype == 2):
			inf_dynamic_block(c)
		else:
			c.status = INFLATE_ERR_BAD_BTYPE()

	int extra_byte = 0
	if (c.bit_pos != 0):
		extra_byte = 1
	*consumed = c.byte_pos + extra_byte

	int status = c.status
	if (status != 0):
		string_free(c.out)
		free(c)
		return result_new_error[inflate_result*](status)

	inflate_result* r = new inflate_result
	r.data = c.out.data
	r.length = c.out.length
	free(c.out)
	free(c)
	return result_new_ok[inflate_result*](r)


# The documented API (docs/projects/compress.md §5.2): decodes the whole
# DEFLATE stream in `data`, capping decompressed output at `max_output`
# bytes (<= 0 means unbounded -- only appropriate for trusted input whose
# length is already bounded some other way, e.g. by a CAS object's own
# framing). See this file's header comment for inflate_ex(), used by
# zlib.w/gzip.w, which also reports how many input bytes were consumed.
wresult[inflate_result*]* inflate(char* data, int length, int max_output):
	int consumed = 0
	return inflate_ex(data, length, max_output, &consumed)
