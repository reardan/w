/*
libs/standard/compression/bzip2.w: a bzip2 decoder (decode only; the
encoder is a follow-up), Python's bz2.decompress / BZ2Decompressor
subset. Chunk P3.3a of docs/projects/stdlib_python_parity.md.

Format (the bzip2 1.0.x stream layout; there is no RFC -- the reference
is libbzip2's decompress.c, which CPython's _bz2module.c wraps):

  stream  = "BZh" + '1'..'9' (block size in 100k units)
            block* + end-of-stream marker + padding to a byte
  block   = 48-bit magic 0x314159265359, 32-bit block CRC, 1 bit
            "randomised", 24-bit origPtr (BWT primary index), a 16+16x16
            bitmap of used byte values, 3-bit group count (2..6), 15-bit
            selector count, MTF-coded unary selectors, delta-coded code
            lengths per group, then Huffman-coded MTF/RUNA/RUNB symbols
            ending in EOB
  end     = 48-bit magic 0x177245385090, 32-bit combined stream CRC

Everything after the 4-byte stream header is a big-endian (MSB-first)
bit stream with no byte alignment between blocks. Decoding a block is:
Huffman -> zero-run (RUNA/RUNB bijective base 2) -> move-to-front ->
inverse BWT -> the initial run-length stage (four equal bytes followed by
a repeat count 0..255), checked against the block CRC; the stream CRC is
the rotate-left-1-then-xor fold of every block CRC.

The CRC is the MSB-first CRC-32 (polynomial 0x04C11DB7, init and final
xor all ones) -- not libs/extras/compress/crc32.w's reflected variant, so
the table lives here. Bit-31 hazards (CLAUDE.md): no literal has bit 31
set; the 32-bit mask is built at runtime, every 32-bit quantity is
masked after a left shift (x64 keeps the high bits otherwise) and every
right shift of a possibly-negative value goes through shr().

API:
  bzip2_decompress(data, length, max_output) -> wresult[bzip2_result*]*
      One shot, Python bz2.decompress semantics: decodes every
      concatenated stream; once at least one stream decoded, trailing
      bytes that are not a valid stream are ignored (as CPython does),
      but a trailing stream that is merely cut short is an error.
      max_output <= 0 means unbounded; otherwise exceeding it is
      BZIP2_ERR_TOO_LARGE (decompression-bomb guard).
  bzip2_decompressor_new(max_output) / _decompress(d, data, len) /
  _eof(d) / _unused_data(d, &len) / _needs_input(d) / _free(d)
      Incremental, one stream, like bz2.BZ2Decompressor: feed input in
      any chunking; each call returns the output of every block that
      became complete. Errors are sticky. Data after the end-of-stream
      marker is kept as unused data (a decompress call after eof is
      BZIP2_ERR_EOF, mirroring CPython's EOFError).

Resumability: the decoder is a small state machine whose units are the
stream header, one block header (bitmap, selectors, code tables), one
Huffman symbol, and the end-of-stream trailer. A unit that runs out of
input rewinds to its own start and waits for more, so a feed never
re-decodes more than one block header; the inverse BWT and output stage
run once the block's EOB symbol arrives.

Memory: the BWT array is one word per position, sized for the stream's
declared block size (up to 900000 entries), allocated once per
decompressor and freed with it. Randomised blocks (a mode no encoder
has produced since bzip2 0.9.5, rejected by Go's compress/bzip2 too)
are BZIP2_ERR_RANDOMIZED.
*/
import lib.memory
import lib.result


const int BZIP2_ERR_BAD_MAGIC = 301
const int BZIP2_ERR_TRUNCATED = 302
const int BZIP2_ERR_BAD_DATA = 303
const int BZIP2_ERR_BAD_BLOCK_CRC = 304
const int BZIP2_ERR_BAD_STREAM_CRC = 305
const int BZIP2_ERR_RANDOMIZED = 306
const int BZIP2_ERR_TOO_LARGE = 307
const int BZIP2_ERR_EOF = 308


char* bzip2_error_string(int code):
	if (code == 0): return c"bzip2: ok"
	if (code == BZIP2_ERR_BAD_MAGIC): return c"bzip2: invalid data stream (bad magic)"
	if (code == BZIP2_ERR_TRUNCATED):
		return c"bzip2: compressed data ended before the end-of-stream marker was reached"
	if (code == BZIP2_ERR_BAD_DATA): return c"bzip2: invalid data stream (malformed block)"
	if (code == BZIP2_ERR_BAD_BLOCK_CRC): return c"bzip2: block CRC mismatch"
	if (code == BZIP2_ERR_BAD_STREAM_CRC): return c"bzip2: stream CRC mismatch"
	if (code == BZIP2_ERR_RANDOMIZED): return c"bzip2: randomised blocks are not supported"
	if (code == BZIP2_ERR_TOO_LARGE): return c"bzip2: output exceeded the caller's max_output cap"
	if (code == BZIP2_ERR_EOF): return c"bzip2: end of stream already reached"
	return c"bzip2: unknown error"


struct bzip2_result:
	char* data
	int length


void bzip2_result_free(bzip2_result* r):
	free(r.data)
	free(r)


# 0xFFFFFFFF without a bit-31 literal (see libs/extras/compress/crc32.w).
int bzip2_mask32():
	int h = 1 << 16
	return h * h - 1


# MSB-first CRC-32 table, polynomial 0x04C11DB7. Each decompressor
# builds its own (2048 steps, noise next to one block) and frees it, so
# there is no process-global cache, no first-use race between threads
# and nothing left live for the leak checker.
int* bzip2_crc_table_new():
	int* table = cast(int*, malloc(256 * __word_size__))
	int poly = 0x04c11db7
	int mask = bzip2_mask32()
	int top = 1 << 31
	for n in range(256):
		int c = n << 24
		for k in range(8):
			if ((c & top) != 0): c = ((c << 1) & mask) ^ poly
			else: c = (c << 1) & mask
		table[n] = c & mask
	return table


# One running block CRC (pre-final-xor register, starts all ones) over
# `count` copies of byte `b`.
int bzip2_crc_run(int* table, int crc, int b, int count):
	int mask = bzip2_mask32()
	for i in range(count):
		crc = ((crc << 8) & mask) ^ table[(shr(crc, 24) ^ b) & 255]
	return crc


const int bz_st_header = 0
const int bz_st_block = 1
const int bz_st_symbols = 2
const int bz_st_done = 3

const int bz_max_groups = 6
const int bz_max_alpha = 258
const int bz_max_code_len = 20
const int bz_max_selectors = 18002
const int bz_group_size = 50


struct bzip2_decompressor:
	# Buffered input not yet consumed; pos/bitoff is the read cursor
	# (bitoff = bits already taken from in_data[pos], MSB first).
	char* in_data
	int in_len
	int in_cap
	int pos
	int bitoff
	int short_input     # set by a read past the end of in_data
	int state
	int error           # sticky BZIP2_ERR_* (0 = none)
	int eof
	int limit           # output cap; -1 = unbounded
	int total_out
	# Output gathered during one decompress call.
	char* out_data
	int out_len
	int out_cap
	# Stream state.
	int block_max       # 100000 * level
	int* tt             # BWT array, block_max words
	int tt_cap
	int combined_crc
	int blocks
	# Current block header.
	int block_crc
	int orig_ptr
	int num_in_use
	int alpha_size
	int n_groups
	int n_selectors     # the ones kept (<= bz_max_selectors)
	int* seq_to_unseq   # 256
	char* selectors     # bz_max_selectors
	int* lengths        # bz_max_groups * bz_max_alpha
	int* counts         # bz_max_groups * (bz_max_code_len + 1)
	int* symbols        # bz_max_groups * bz_max_alpha
	# Symbol decoding state.
	int* mtf            # 256
	int* unzftab        # 256
	int* cftab          # 257
	int* crc_table      # 256
	int nblock
	int run_len         # pending RUNA/RUNB run
	int run_weight
	int group_left      # symbols left in the current 50-symbol group
	int group
	int sel_idx


bzip2_decompressor* bzip2_decompressor_new(int max_output):
	bzip2_decompressor* d = new bzip2_decompressor
	d.in_data = cast(char*, malloc(256))
	d.in_len = 0
	d.in_cap = 256
	d.pos = 0
	d.bitoff = 0
	d.short_input = 0
	d.state = bz_st_header
	d.error = 0
	d.eof = 0
	d.limit = 0 - 1
	if (max_output > 0): d.limit = max_output
	d.total_out = 0
	d.out_data = 0
	d.out_len = 0
	d.out_cap = 0
	d.block_max = 0
	d.tt = 0
	d.tt_cap = 0
	d.combined_crc = 0
	d.blocks = 0
	d.seq_to_unseq = cast(int*, malloc(256 * __word_size__))
	d.selectors = cast(char*, malloc(bz_max_selectors))
	d.lengths = cast(int*, malloc(bz_max_groups * bz_max_alpha * __word_size__))
	d.counts = cast(int*, malloc(bz_max_groups * (bz_max_code_len + 1) * __word_size__))
	d.symbols = cast(int*, malloc(bz_max_groups * bz_max_alpha * __word_size__))
	d.mtf = cast(int*, malloc(256 * __word_size__))
	d.unzftab = cast(int*, malloc(256 * __word_size__))
	d.cftab = cast(int*, malloc(257 * __word_size__))
	d.crc_table = bzip2_crc_table_new()
	d.nblock = 0
	return d


void bzip2_decompressor_free(bzip2_decompressor* d):
	if (d == 0): return
	free(d.in_data)
	if (d.out_data != 0): free(d.out_data)
	if (d.tt != 0): free(d.tt)
	free(d.seq_to_unseq)
	free(d.selectors)
	free(d.lengths)
	free(d.counts)
	free(d.symbols)
	free(d.mtf)
	free(d.unzftab)
	free(d.cftab)
	free(d.crc_table)
	free(d)


int bzip2_decompressor_eof(bzip2_decompressor* d):
	return d.eof


# Python's needs_input: more input is required before more output can be
# produced (false once the stream ended or failed).
int bzip2_decompressor_needs_input(bzip2_decompressor* d):
	if (d.eof || (d.error != 0)): return 0
	return 1


# Bytes after the end-of-stream marker (a pointer into the decompressor's
# own buffer, valid until the next call on it); 0 bytes before eof.
char* bzip2_decompressor_unused_data(bzip2_decompressor* d, int* length):
	if (!d.eof):
		*length = 0
		return d.in_data
	*length = d.in_len - d.pos
	return &d.in_data[d.pos]


# Reads n <= 24 bits MSB first; past the end it sets short_input and
# returns 0 (the caller rewinds its unit).
int bz_bits(bzip2_decompressor* d, int n):
	int v = 0
	while (n > 0):
		if (d.pos >= d.in_len):
			d.short_input = 1
			return 0
		int avail = 8 - d.bitoff
		int take = avail
		if (n < take): take = n
		int b = d.in_data[d.pos] & 255
		v = (v << take) | ((b >> (avail - take)) & ((1 << take) - 1))
		d.bitoff = d.bitoff + take
		n = n - take
		if (d.bitoff == 8):
			d.bitoff = 0
			d.pos = d.pos + 1
	return v


int bz_bit(bzip2_decompressor* d):
	if (d.pos >= d.in_len):
		d.short_input = 1
		return 0
	int v = ((d.in_data[d.pos] & 255) >> (7 - d.bitoff)) & 1
	d.bitoff = d.bitoff + 1
	if (d.bitoff == 8):
		d.bitoff = 0
		d.pos = d.pos + 1
	return v


int bz_bits32(bzip2_decompressor* d):
	int hi = bz_bits(d, 16)
	int lo = bz_bits(d, 16)
	return ((hi << 16) | lo) & bzip2_mask32()


void bz_out_reserve(bzip2_decompressor* d, int extra):
	int need = d.out_len + extra
	if (need <= d.out_cap): return
	int cap = d.out_cap * 2
	if (cap < 4096): cap = 4096
	while (cap < need): cap = cap * 2
	if (d.out_data == 0): d.out_data = cast(char*, malloc(cap))
	else: d.out_data = realloc(d.out_data, d.out_cap, cap)
	d.out_cap = cap


# Stream header "BZh1".."BZh9", checked byte by byte so a short prefix
# of a valid header reads as truncation and anything else as bad magic.
# Returns 1 when parsed, 0 to wait for input (or on error).
int bz_read_stream_header(bzip2_decompressor* d):
	char* magic = c"BZh"
	int i = 0
	while (i < 4):
		if (d.pos + i >= d.in_len): return 0
		int c = d.in_data[d.pos + i] & 255
		if (i < 3):
			if (c != (magic[i] & 255)):
				d.error = BZIP2_ERR_BAD_MAGIC
				return 0
		else if ((c < '1') || (c > '9')):
			d.error = BZIP2_ERR_BAD_MAGIC
			return 0
		i = i + 1
	int need = (d.in_data[d.pos + 3] - '0') * 100000
	d.pos = d.pos + 4
	d.block_max = need
	if (d.tt_cap < need):
		if (d.tt != 0): free(d.tt)
		d.tt = cast(int*, malloc(need * __word_size__))
		d.tt_cap = need
	d.combined_crc = 0
	d.state = bz_st_block
	return 1


# Canonical code tables for group g from its code lengths: counts[len]
# per length and the symbols sorted by (length, symbol) -- bzip2's
# hbAssignCodes order, the same canonical construction as DEFLATE.
void bz_build_table(bzip2_decompressor* d, int g):
	int* len = &d.lengths[g * bz_max_alpha]
	int* cnt = &d.counts[g * (bz_max_code_len + 1)]
	int* sym = &d.symbols[g * bz_max_alpha]
	for l in range(bz_max_code_len + 1): cnt[l] = 0
	for s in range(d.alpha_size): cnt[len[s]] = cnt[len[s]] + 1
	int k = 0
	int l2 = 1
	while (l2 <= bz_max_code_len):
		for s2 in range(d.alpha_size):
			if (len[s2] == l2):
				sym[k] = s2
				k = k + 1
		l2 = l2 + 1


# Parses one block header, or the end-of-stream trailer. Returns 1 when
# a unit was consumed, 0 to wait for input (cursor rewound) or on error.
int bz_read_block_header(bzip2_decompressor* d):
	int save_pos = d.pos
	int save_bit = d.bitoff
	d.short_input = 0
	int m1 = bz_bits(d, 24)
	int m2 = bz_bits(d, 24)
	if (d.short_input):
		d.pos = save_pos
		d.bitoff = save_bit
		return 0
	if ((m1 == 0x177245) && (m2 == 0x385090)):
		int stored = bz_bits32(d)
		if (d.short_input):
			d.pos = save_pos
			d.bitoff = save_bit
			return 0
		if (stored != d.combined_crc):
			d.error = BZIP2_ERR_BAD_STREAM_CRC
			return 0
		if (d.bitoff != 0):
			d.bitoff = 0
			d.pos = d.pos + 1
		d.state = bz_st_done
		d.eof = 1
		return 1
	if ((m1 != 0x314159) || (m2 != 0x265359)):
		d.error = BZIP2_ERR_BAD_DATA
		return 0
	d.block_crc = bz_bits32(d)
	int randomised = bz_bit(d)
	d.orig_ptr = bz_bits(d, 24)
	# Used-byte bitmap: 16 ranges, then 16 bits for each range present.
	int ranges = bz_bits(d, 16)
	d.num_in_use = 0
	for i in range(16):
		if (((ranges >> (15 - i)) & 1) != 0):
			int bits = bz_bits(d, 16)
			for j in range(16):
				if (((bits >> (15 - j)) & 1) != 0):
					d.seq_to_unseq[d.num_in_use] = i * 16 + j
					d.num_in_use = d.num_in_use + 1
	d.n_groups = bz_bits(d, 3)
	int n_sel = bz_bits(d, 15)
	if (d.short_input):
		d.pos = save_pos
		d.bitoff = save_bit
		return 0
	if (randomised):
		d.error = BZIP2_ERR_RANDOMIZED
		return 0
	if ((d.num_in_use == 0) || (d.n_groups < 2) || (d.n_groups > bz_max_groups) || (n_sel < 1)):
		d.error = BZIP2_ERR_BAD_DATA
		return 0
	if (d.orig_ptr > d.block_max):
		d.error = BZIP2_ERR_BAD_DATA
		return 0
	d.alpha_size = d.num_in_use + 2
	# Selectors: unary group index, MTF-coded. Counts above the format's
	# limit are read and dropped, as bzip2 1.0.8 does.
	int* pos_mtf = d.mtf
	for g in range(d.n_groups): pos_mtf[g] = g
	d.n_selectors = 0
	for s in range(n_sel):
		int j2 = 0
		while (bz_bit(d) != 0):
			j2 = j2 + 1
			if (j2 >= d.n_groups):
				d.error = BZIP2_ERR_BAD_DATA
				return 0
		if (d.short_input):
			d.pos = save_pos
			d.bitoff = save_bit
			return 0
		int v = pos_mtf[j2]
		while (j2 > 0):
			pos_mtf[j2] = pos_mtf[j2 - 1]
			j2 = j2 - 1
		pos_mtf[0] = v
		if (s < bz_max_selectors):
			d.selectors[s] = v
			d.n_selectors = d.n_selectors + 1
	# Code lengths: 5-bit start, then per symbol a run of (1, inc/dec)
	# bit pairs closed by a 0 bit; every length must stay in 1..20.
	for t in range(d.n_groups):
		int curr = bz_bits(d, 5)
		int* len = &d.lengths[t * bz_max_alpha]
		for i2 in range(d.alpha_size):
			while (1):
				if (d.short_input):
					d.pos = save_pos
					d.bitoff = save_bit
					return 0
				if ((curr < 1) || (curr > bz_max_code_len)):
					d.error = BZIP2_ERR_BAD_DATA
					return 0
				if (bz_bit(d) == 0): break
				if (bz_bit(d) == 0): curr = curr + 1
				else: curr = curr - 1
			len[i2] = curr
	if (d.short_input):
		d.pos = save_pos
		d.bitoff = save_bit
		return 0
	for t2 in range(d.n_groups): bz_build_table(d, t2)
	# Symbol-decoding state for the block body.
	for i3 in range(256):
		d.mtf[i3] = i3
		d.unzftab[i3] = 0
	d.nblock = 0
	d.run_len = 0
	d.run_weight = 1
	d.group_left = 0
	d.group = 0
	d.sel_idx = 0
	d.state = bz_st_symbols
	return 1


# One Huffman symbol from group g, or -1 when no code matches (or the
# input ran out; the caller checks short_input).
int bz_decode_symbol(bzip2_decompressor* d, int g):
	int* cnt = &d.counts[g * (bz_max_code_len + 1)]
	int* sym = &d.symbols[g * bz_max_alpha]
	int code = 0
	int first = 0
	int index = 0
	int l = 1
	while (l <= bz_max_code_len):
		code = code | bz_bit(d)
		if (d.short_input): return 0 - 1
		int count = cnt[l]
		if (code - count < first):
			int k = index + (code - first)
			if ((k < 0) || (k >= d.alpha_size)): return 0 - 1
			return sym[k]
		index = index + count
		first = (first + count) << 1
		code = code << 1
		l = l + 1
	return 0 - 1


# Appends the pending RUNA/RUNB run of the MTF front byte to tt.
int bz_flush_run(bzip2_decompressor* d):
	if (d.run_len == 0): return 1
	if (d.nblock + d.run_len > d.block_max):
		d.error = BZIP2_ERR_BAD_DATA
		return 0
	int ch = d.seq_to_unseq[d.mtf[0]]
	d.unzftab[ch] = d.unzftab[ch] + d.run_len
	int* tt = d.tt
	for i in range(d.run_len):
		tt[d.nblock] = ch
		d.nblock = d.nblock + 1
	d.run_len = 0
	d.run_weight = 1
	return 1


# Inverse BWT plus the initial run-length stage, checked against the
# block CRC. Returns 1 on success.
int bz_finish_block(bzip2_decompressor* d):
	int nblock = d.nblock
	if ((d.orig_ptr < 0) || (d.orig_ptr >= nblock)):
		d.error = BZIP2_ERR_BAD_DATA
		return 0
	int* tt = d.tt
	int* cftab = d.cftab
	cftab[0] = 0
	for i in range(256): cftab[i + 1] = cftab[i] + d.unzftab[i]
	for i2 in range(nblock):
		int uc = tt[i2] & 255
		tt[cftab[uc]] = tt[cftab[uc]] | (i2 << 8)
		cftab[uc] = cftab[uc] + 1
	int* table = d.crc_table
	int mask = bzip2_mask32()
	int crc = mask
	int t_pos = shr(tt[d.orig_ptr], 8)
	int last = 0 - 1
	int same = 0
	int produced = 0
	int k = 0
	while (k < nblock):
		t_pos = tt[t_pos]
		int ch = t_pos & 255
		t_pos = shr(t_pos, 8)
		int reps = 1
		int value = ch
		if (same == 4):
			# A repeat count for the four equal bytes just emitted.
			reps = ch
			value = last
			same = 0
		else if (ch == last):
			same = same + 1
		else:
			last = ch
			same = 1
		if (reps > 0):
			if ((d.limit >= 0) && (d.total_out + produced + reps > d.limit)):
				d.error = BZIP2_ERR_TOO_LARGE
				return 0
			bz_out_reserve(d, reps)
			char* out = d.out_data
			for r in range(reps): out[d.out_len + r] = value
			d.out_len = d.out_len + reps
			produced = produced + reps
			crc = bzip2_crc_run(table, crc, value, reps)
		k = k + 1
	crc = (crc ^ mask) & mask
	if (crc != d.block_crc):
		d.error = BZIP2_ERR_BAD_BLOCK_CRC
		return 0
	d.total_out = d.total_out + produced
	d.combined_crc = ((((d.combined_crc << 1) & mask) | shr(d.combined_crc, 31)) ^ crc) & mask
	d.blocks = d.blocks + 1
	d.state = bz_st_block
	return 1


# Decodes Huffman symbols until EOB (then finishes the block) or until
# the input runs out mid-symbol. Returns 1 when the block completed.
int bz_read_symbols(bzip2_decompressor* d):
	int eob = d.num_in_use + 1
	int* mtf = d.mtf
	while (1):
		int g = d.group
		if (d.group_left == 0):
			if (d.sel_idx >= d.n_selectors):
				d.error = BZIP2_ERR_BAD_DATA
				return 0
			g = d.selectors[d.sel_idx] & 255
		int save_pos = d.pos
		int save_bit = d.bitoff
		d.short_input = 0
		int s = bz_decode_symbol(d, g)
		if (d.short_input):
			d.pos = save_pos
			d.bitoff = save_bit
			return 0
		if (s < 0):
			d.error = BZIP2_ERR_BAD_DATA
			return 0
		if (d.group_left == 0):
			d.sel_idx = d.sel_idx + 1
			d.group = g
			d.group_left = bz_group_size
		d.group_left = d.group_left - 1
		if (s <= 1):
			# RUNA adds 1 * weight, RUNB 2 * weight (bijective base 2).
			if (d.run_weight >= 2 * 1024 * 1024):
				d.error = BZIP2_ERR_BAD_DATA
				return 0
			d.run_len = d.run_len + (s + 1) * d.run_weight
			d.run_weight = d.run_weight * 2
			if (d.run_len > d.block_max):
				d.error = BZIP2_ERR_BAD_DATA
				return 0
		else:
			if (!bz_flush_run(d)): return 0
			if (s == eob): return bz_finish_block(d)
			if (d.nblock >= d.block_max):
				d.error = BZIP2_ERR_BAD_DATA
				return 0
			int nn = s - 1
			int uc = mtf[nn]
			while (nn > 0):
				mtf[nn] = mtf[nn - 1]
				nn = nn - 1
			mtf[0] = uc
			int ch = d.seq_to_unseq[uc]
			d.unzftab[ch] = d.unzftab[ch] + 1
			d.tt[d.nblock] = ch
			d.nblock = d.nblock + 1
	return 0


# Drops consumed input bytes so the buffer only holds the unread tail.
void bz_compact(bzip2_decompressor* d):
	if (d.pos == 0): return
	int rest = d.in_len - d.pos
	char* buf = d.in_data
	for i in range(rest): buf[i] = buf[d.pos + i]
	d.in_len = rest
	d.pos = 0


void bz_append_input(bzip2_decompressor* d, char* data, int length):
	if (length <= 0): return
	int need = d.in_len + length
	if (need > d.in_cap):
		int cap = d.in_cap * 2
		while (cap < need): cap = cap * 2
		d.in_data = realloc(d.in_data, d.in_cap, cap)
		d.in_cap = cap
	char* buf = d.in_data
	for i in range(length): buf[d.in_len + i] = data[i]
	d.in_len = need


# Runs the state machine as far as the buffered input allows.
void bz_run(bzip2_decompressor* d):
	while ((d.error == 0) && (d.state != bz_st_done)):
		int progressed = 0
		if (d.state == bz_st_header): progressed = bz_read_stream_header(d)
		else if (d.state == bz_st_block): progressed = bz_read_block_header(d)
		else: progressed = bz_read_symbols(d)
		if (!progressed): return


# Feeds `length` more bytes and returns the output of every block that
# completed. The error code is sticky: once a call fails, every later
# call fails with the same code.
wresult[bzip2_result*]* bzip2_decompressor_decompress(bzip2_decompressor* d, char* data, int length):
	if (d.error != 0): return result_new_error[bzip2_result*](d.error)
	if (d.eof): return result_new_error[bzip2_result*](BZIP2_ERR_EOF)
	bz_compact(d)
	bz_append_input(d, data, length)
	d.out_data = 0
	d.out_len = 0
	d.out_cap = 0
	bz_run(d)
	if (d.error != 0):
		if (d.out_data != 0): free(d.out_data)
		d.out_data = 0
		return result_new_error[bzip2_result*](d.error)
	char* out = d.out_data
	if (out == 0): out = cast(char*, malloc(1))
	bzip2_result* r = new bzip2_result(out, d.out_len)
	d.out_data = 0
	d.out_len = 0
	d.out_cap = 0
	return result_new_ok[bzip2_result*](r)


/*
One-shot decode of every concatenated stream (Python bz2.decompress).
On success the result holds all the output; on any failure nothing is
returned but the error code. An empty input decodes to empty output, as
bz2.decompress(b"") does.
*/
wresult[bzip2_result*]* bzip2_decompress(char* data, int length, int max_output):
	if (length < 0): length = 0
	char* out = cast(char*, malloc(1))
	int out_len = 0
	int pos = 0
	int streams = 0
	while (pos < length):
		bzip2_decompressor* d = bzip2_decompressor_new(0)
		if (max_output > 0): d.limit = max_output - out_len
		wresult[bzip2_result*]* res = bzip2_decompressor_decompress(d, &data[pos], length - pos)
		if (result_is_error[bzip2_result*](res)):
			int code = result_code[bzip2_result*](res)
			result_free[bzip2_result*](res)
			bzip2_decompressor_free(d)
			# CPython ignores trailing data that is not a valid stream
			# once one stream decoded; truncation is still an error.
			if ((streams > 0) && (code != BZIP2_ERR_TRUNCATED) && (code != BZIP2_ERR_TOO_LARGE)): break
			free(out)
			return result_new_error[bzip2_result*](code)
		bzip2_result* part = result_value[bzip2_result*](res)
		result_free[bzip2_result*](res)
		if (!d.eof):
			bzip2_result_free(part)
			bzip2_decompressor_free(d)
			free(out)
			return result_new_error[bzip2_result*](BZIP2_ERR_TRUNCATED)
		if (part.length > 0):
			out = realloc(out, out_len + 1, out_len + part.length + 1)
			for i in range(part.length): out[out_len + i] = part.data[i]
			out_len = out_len + part.length
		bzip2_result_free(part)
		int unused = 0
		bzip2_decompressor_unused_data(d, &unused)
		pos = length - unused
		bzip2_decompressor_free(d)
		streams = streams + 1
	out[out_len] = 0
	bzip2_result* r = new bzip2_result(out, out_len)
	return result_new_ok[bzip2_result*](r)
