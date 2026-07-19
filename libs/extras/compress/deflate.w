/*
libs/extras/compress/deflate.w: docs/projects/compress.md's DEFLATE
compressor (RFC 1951 encode side), covering all three level tiers the
API sketch (§5.3) already reserved symbols for:

  - DEFLATE_LEVEL_STORED (0): BTYPE=00 blocks, no compression -- stage
    2a, unchanged from the first cut of this file (see
    deflate_emit_stored_block below).
  - DEFLATE_LEVEL_FAST (1): a hash-chain LZ77 matcher (with lazy
    matching, i.e. deferring a match by one byte when the next position
    yields a strictly longer one -- zlib's default strategy, §6's design
    doc language) feeding RFC 1951's fixed/static Huffman codes -- no
    per-block header to transmit, so the whole input is one block.
  - DEFLATE_LEVEL_BEST (2): the same LZ77 tokenizer (run with a longer
    hash-chain search) but emitted as dynamic-Huffman blocks: each
    block's own literal/length and distance code tables are built from
    that block's actual symbol frequencies (canonical Huffman via the
    standard two-queue merge, §2.2), then length-limited to the format's
    15-bit cap with the widely-used "enforce max code size" fixup
    (fold any overflow into the max-length bucket, then trade one
    max-length code for two one-longer codes until the Kraft sum matches
    2^15 exactly -- the same technique miniz's tdefl_huffman_enforce_
    max_code_size and zlib's gen_bitlen both implement, just operating
    directly on the length histogram instead of walking the original
    tree). The code-length alphabet itself (RLE symbols 16/17/18, RFC
    1951 §3.2.7) is Huffman-coded the same way. Blocks are split on a
    simple size heuristic (every ~32KiB of *input* the tokenizer has
    consumed starts a new block) so a large, heterogeneous input still
    gets locally-adapted tables instead of one compromise table for the
    whole stream -- docs/projects/compress.md doesn't mandate a specific
    policy, just "a block-splitting heuristic" (§9's PR-C framing), and
    this one is simple, deterministic, and cheap.

Both compressive levels share one LZ77 tokenizer (docs/projects/
compress.md §6.2's flat hash-chain design: one `head` array indexed by a
3-byte hash, one `prev` array indexed by input position -- exactly two
allocations regardless of input size or match count, never a
map[int,list[int]]) and reuse inflate.w's length/distance base+extra
tables (inf_length_base/inf_length_extra/inf_dist_base/inf_dist_extra)
rather than duplicating those 29/30-entry RFC 1951 §3.2.5 tables here.

Level dispatch: `level <= DEFLATE_LEVEL_STORED()` keeps the original
stored-blocks-only path; `DEFLATE_LEVEL_FAST()` (or anything below BEST)
runs the fixed-Huffman path; anything >= `DEFLATE_LEVEL_BEST()` runs the
dynamic-Huffman/block-splitting path -- so future higher levels default
to "best" rather than silently clamping to fast.

W-specific hazards (docs/projects/compress.md §6.1): every quantity in
this file -- LZ77 distances (<=32768), lengths (<=258), Huffman code
values and lengths (<=15 bits, 7 for the code-length alphabet), symbol
frequencies, and bit-accumulator state -- fits comfortably inside a
positive 32-bit word with no literal anywhere near bit 31, so none of
crc32.w's runtime-mask-building machinery is needed here; plain `<<`
is used for left shifts (never large enough to touch the sign bit) and
the `shr` intrinsic for right shifts, matching this file's original
stored-block code.
*/
import lib.memory
import structures.string
import libs.extras.compress.inflate


int DEFLATE_LEVEL_STORED():
	return 0


int DEFLATE_LEVEL_FAST():
	return 1


int DEFLATE_LEVEL_BEST():
	return 2


struct deflate_result:
	char* data
	int length


void deflate_result_free(deflate_result* r):
	free(r.data)
	free(r)


# Appends one BTYPE=00 block covering `len` bytes at data+offset.
void deflate_emit_stored_block(string_builder* out, char* data, int offset, int len, int is_final):
	string_append_char(out, is_final & 1)
	string_append_char(out, len & 255)
	string_append_char(out, shr(len, 8) & 255)
	int nlen = (len ^ 65535) & 65535
	string_append_char(out, nlen & 255)
	string_append_char(out, shr(nlen, 8) & 255)
	string_append_bytes(out, data + offset, len)


/* ---- LZ77: hash-chain match finder with lazy matching ---- */


int dfl_min_match():
	return 3


int dfl_max_match():
	return 258


int dfl_max_dist():
	return 32768


int dfl_hash_size():
	return 32768


int dfl_hash_mask():
	return 32767


int dfl_hash_shift():
	return 5


# Chain-search depth caps: FAST spends less effort per position (still
# finds long matches almost immediately on repetitive input thanks to
# the "stop once max_len is reached" early exit below), BEST searches
# deeper for a better ratio. Both are plain effort/time knobs, not
# correctness parameters -- any positive value produces a valid stream.
int dfl_max_chain_fast():
	return 32


int dfl_max_chain_best():
	return 256


# Block-splitting heuristic for DEFLATE_LEVEL_BEST (see this file's
# header comment): start a new dynamic-Huffman block roughly every this
# many bytes of *input* the tokenizer has consumed.
int dfl_block_input_bytes():
	return 32768


# The LZ77 token stream for a whole input buffer: parallel arrays sized
# to `length` (an input can produce at most `length` tokens, one per
# byte, in the all-literals worst case), never one allocation per token.
# dist[i] == 0 marks a literal (len[i] is the byte value, 0..255);
# dist[i] > 0 marks a back-reference (len[i] is the match length,
# 3..258, dist[i] the distance, 1..32768).
struct dfl_tokens:
	int* len
	int* dist
	int count


int dfl_hash3(char* data, int pos):
	int h = data[pos] & 255
	h = ((h << dfl_hash_shift()) ^ (data[pos + 1] & 255)) & dfl_hash_mask()
	h = ((h << dfl_hash_shift()) ^ (data[pos + 2] & 255)) & dfl_hash_mask()
	return h


# Inserts position `pos` into the hash chain and returns the chain's
# previous head (the candidate to start a match search from, or -1 if
# none) -- callers must only call this when a full 3-byte key exists,
# i.e. pos + dfl_min_match() <= length.
int dfl_insert(char* data, int length, int* head, int* prev, int pos):
	int h = dfl_hash3(data, pos)
	int old = head[h]
	prev[pos] = old
	head[h] = pos
	return old


# Walks the hash chain starting at `hash_head`, comparing byte-by-byte
# against `pos`, tracking the longest match found within `max_chain`
# candidates. Distances beyond dfl_max_dist() end the search (chain
# positions only get farther away from `pos` as the walk continues, so
# once one candidate exceeds the window, every later one will too).
void dfl_find_match(char* data, int length, int* prev, int pos, int hash_head, int max_chain, int* out_len, int* out_dist):
	*out_len = 0
	*out_dist = 0
	int max_len = length - pos
	if (max_len > dfl_max_match()):
		max_len = dfl_max_match()
	if (max_len < dfl_min_match()):
		return
	int best_len = dfl_min_match() - 1
	int best_dist = 0
	int cand = hash_head
	int chain = max_chain
	while ((cand >= 0) && (chain > 0)):
		int dist = pos - cand
		if (dist > dfl_max_dist()):
			break
		int mlen = 0
		while ((mlen < max_len) && ((data[cand + mlen] & 255) == (data[pos + mlen] & 255))):
			mlen = mlen + 1
		if (mlen > best_len):
			best_len = mlen
			best_dist = dist
			if (mlen >= max_len):
				break
		cand = prev[cand]
		chain = chain - 1
	if (best_len >= dfl_min_match()):
		*out_len = best_len
		*out_dist = best_dist


# Tokenizes the whole buffer with one-position lazy matching: the match
# found at the current position is compared against the match found one
# position later before being committed, emitting a literal instead and
# deferring to the later match whenever it is strictly longer (RFC
# 1951 doesn't mandate this -- it's zlib's own default strategy, called
# out explicitly in docs/projects/compress.md's stage-3 description).
dfl_tokens* dfl_tokenize(char* data, int length, int max_chain):
	dfl_tokens* t = new dfl_tokens
	if (length <= 0):
		t.len = cast(int*, 0)
		t.dist = cast(int*, 0)
		t.count = 0
		return t
	t.len = cast(int*, malloc(length * __word_size__))
	t.dist = cast(int*, malloc(length * __word_size__))
	t.count = 0

	int* head = cast(int*, malloc(dfl_hash_size() * __word_size__))
	int i = 0
	while (i < dfl_hash_size()):
		head[i] = -1
		i = i + 1
	int* prev = cast(int*, malloc(length * __word_size__))

	int strstart = 0
	int match_available = 0
	int prev_length = dfl_min_match() - 1
	int prev_dist = 0
	while (strstart < length):
		int cur_len = 0
		int cur_dist = 0
		if (strstart + dfl_min_match() <= length):
			int hash_head = dfl_insert(data, length, head, prev, strstart)
			dfl_find_match(data, length, prev, strstart, hash_head, max_chain, &cur_len, &cur_dist)
		if ((prev_length >= dfl_min_match()) && (cur_len <= prev_length)):
			# Commit the deferred match found one position back (at
			# strstart-1, length prev_length, distance prev_dist).
			t.len[t.count] = prev_length
			t.dist[t.count] = prev_dist
			t.count = t.count + 1
			int match_end = (strstart - 1) + prev_length
			int k = strstart + 1
			while (k < match_end):
				if (k + dfl_min_match() <= length):
					dfl_insert(data, length, head, prev, k)
				k = k + 1
			strstart = match_end
			match_available = 0
			prev_length = dfl_min_match() - 1
			prev_dist = 0
		else if (match_available):
			t.len[t.count] = data[strstart - 1] & 255
			t.dist[t.count] = 0
			t.count = t.count + 1
			strstart = strstart + 1
			prev_length = cur_len
			prev_dist = cur_dist
		else:
			match_available = 1
			strstart = strstart + 1
			prev_length = cur_len
			prev_dist = cur_dist
	if (match_available):
		t.len[t.count] = data[strstart - 1] & 255
		t.dist[t.count] = 0
		t.count = t.count + 1

	free(head)
	free(prev)
	return t


/* ---- Length/distance symbol lookup (inverse of inflate.w's tables) ---- */


# Length 3..258 -> literal/length symbol 257..285 plus extra bits, by
# scanning inflate.w's length-base table (RFC 1951 §3.2.5) from the top
# down for the largest base <= len; reused rather than duplicated (this
# file's header comment).
void dfl_length_symbol(int len, int* out_sym, int* out_extra_bits, int* out_extra_val):
	int idx = 28
	while ((idx > 0) && (inf_length_base(idx) > len)):
		idx = idx - 1
	*out_sym = 257 + idx
	*out_extra_bits = inf_length_extra(idx)
	*out_extra_val = len - inf_length_base(idx)


# Distance 1..32768 -> distance symbol 0..29 plus extra bits.
void dfl_dist_symbol(int dist, int* out_sym, int* out_extra_bits, int* out_extra_val):
	int idx = 29
	while ((idx > 0) && (inf_dist_base(idx) > dist)):
		idx = idx - 1
	*out_sym = idx
	*out_extra_bits = inf_dist_extra(idx)
	*out_extra_val = dist - inf_dist_base(idx)


/* ---- Canonical Huffman construction (encode side) ---- */


# Builds DEFLATE-legal canonical code lengths (each <= max_bits) for an
# alphabet of `n` symbols from their frequencies. Unused symbols (freq
# 0) get length 0. Two special cases match RFC 1951's own tolerance
# (also implemented on the decode side by inflate.w's wh_build): zero
# used symbols yields all-zero lengths, and exactly one used symbol
# gets length 1 (the "single short code" placeholder a real decoder
# already accepts, e.g. an all-literal block's otherwise-empty distance
# table) rather than needing a second dummy leaf to make a real tree.
#
# Construction: sort the used symbols ascending by (frequency, symbol
# index) then run the standard "two sorted queues" Huffman merge (a
# queue of leaves and a queue of internal nodes, both already sorted,
# so the next-smallest node is always one of the two queue fronts) to
# get a per-symbol tree depth. If the deepest leaf exceeds max_bits,
# fold the histogram of depths using the widely-used "enforce max code
# size" fixup (zlib's gen_bitlen / miniz's tdefl_huffman_enforce_max_
# code_size both implement this exact technique): dump every
# overflowing depth's count into the max_bits bucket, then repeatedly
# trade one max_bits-length code for two one-longer codes (pulled from
# the shortest available shorter length) until the Kraft sum
# (sum(count[len] << (max_bits-len))) again equals 2^max_bits exactly.
# Final lengths are reassigned by that (possibly adjusted) histogram in
# the same ascending-frequency symbol order used to build the tree --
# independent of the original per-leaf depths, which only mattered for
# producing the initial histogram.
int* dfl_build_lengths(int* freq, int n, int max_bits):
	int* length = cast(int*, malloc(n * __word_size__))
	int i = 0
	while (i < n):
		length[i] = 0
		i = i + 1
	int* used = cast(int*, malloc(n * __word_size__))
	int nused = 0
	i = 0
	while (i < n):
		if (freq[i] > 0):
			used[nused] = i
			nused = nused + 1
		i = i + 1
	if (nused == 0):
		free(used)
		return length
	if (nused == 1):
		length[used[0]] = 1
		free(used)
		return length

	# Insertion sort `used` ascending by (freq, symbol index): nused is
	# at most 288, so O(nused^2) is negligible and this keeps the whole
	# construction free of any hash-table/heap machinery.
	i = 1
	while (i < nused):
		int key = used[i]
		int keyfreq = freq[key]
		int j = i - 1
		while ((j >= 0) && ((freq[used[j]] > keyfreq) || ((freq[used[j]] == keyfreq) && (used[j] > key)))):
			used[j + 1] = used[j]
			j = j - 1
		used[j + 1] = key
		i = i + 1

	int total_nodes = 2 * nused - 1
	int* node_freq = cast(int*, malloc(total_nodes * __word_size__))
	int* node_parent = cast(int*, malloc(total_nodes * __word_size__))
	i = 0
	while (i < nused):
		node_freq[i] = freq[used[i]]
		node_parent[i] = -1
		i = i + 1
	int i1 = 0
	int i2 = nused
	int next_internal = nused
	int made = 0
	while (made < nused - 1):
		int a = 0
		if (i2 >= next_internal):
			a = i1
			i1 = i1 + 1
		else if (i1 >= nused):
			a = i2
			i2 = i2 + 1
		else if (node_freq[i1] <= node_freq[i2]):
			a = i1
			i1 = i1 + 1
		else:
			a = i2
			i2 = i2 + 1
		int b = 0
		if (i2 >= next_internal):
			b = i1
			i1 = i1 + 1
		else if (i1 >= nused):
			b = i2
			i2 = i2 + 1
		else if (node_freq[i1] <= node_freq[i2]):
			b = i1
			i1 = i1 + 1
		else:
			b = i2
			i2 = i2 + 1
		int newi = next_internal
		node_freq[newi] = node_freq[a] + node_freq[b]
		node_parent[newi] = -1
		node_parent[a] = newi
		node_parent[b] = newi
		next_internal = next_internal + 1
		made = made + 1

	int* depth = cast(int*, malloc(total_nodes * __word_size__))
	depth[total_nodes - 1] = 0
	int k = total_nodes - 2
	while (k >= 0):
		depth[k] = depth[node_parent[k]] + 1
		k = k - 1

	# Sized to cover whichever is larger: the tree's own maximum possible
	# depth (total_nodes+2, generous headroom) or max_bits+2 -- the
	# length-limiting logic below always indexes up to max_bits (and
	# max_bits+1 while redistributing), even when the unconstrained tree
	# never gets that deep (a small alphabet like the 19-symbol
	# code-length table can have max_bits=7 while total_nodes is tiny).
	int hist_size = total_nodes + 2
	if (hist_size < max_bits + 2):
		hist_size = max_bits + 2
	int* bl_count = cast(int*, malloc(hist_size * __word_size__))
	i = 0
	while (i < hist_size):
		bl_count[i] = 0
		i = i + 1
	int maxdepth = 0
	i = 0
	while (i < nused):
		int d = depth[i]
		if (d > maxdepth):
			maxdepth = d
		bl_count[d] = bl_count[d] + 1
		i = i + 1
	free(node_freq)
	free(node_parent)
	free(depth)

	if (maxdepth > max_bits):
		int len = max_bits + 1
		while (len <= maxdepth):
			bl_count[max_bits] = bl_count[max_bits] + bl_count[len]
			bl_count[len] = 0
			len = len + 1
		maxdepth = max_bits

	int total = 0
	int len = max_bits
	while (len >= 1):
		total = total + (bl_count[len] << (max_bits - len))
		len = len - 1
	int target = 1 << max_bits
	int guard = 0
	while ((total != target) && (guard < hist_size * 4 + 16)):
		bl_count[max_bits] = bl_count[max_bits] - 1
		len = max_bits - 1
		while ((len > 0) && (bl_count[len] == 0)):
			len = len - 1
		bl_count[len] = bl_count[len] - 1
		bl_count[len + 1] = bl_count[len + 1] + 2
		total = total - 1
		guard = guard + 1

	int idx = 0
	len = max_bits
	while (len >= 1):
		int cnt = bl_count[len]
		while (cnt > 0):
			length[used[idx]] = len
			idx = idx + 1
			cnt = cnt - 1
		len = len - 1

	free(bl_count)
	free(used)
	return length


# RFC 1951 §3.2.2's canonical-code construction pseudocode, verbatim:
# count codes per length, derive each length's starting code value, then
# assign consecutive values to symbols in index order within a length.
int* dfl_build_codes(int* lengths, int n, int max_bits):
	int* bl_count = cast(int*, malloc((max_bits + 1) * __word_size__))
	int i = 0
	while (i <= max_bits):
		bl_count[i] = 0
		i = i + 1
	i = 0
	while (i < n):
		if (lengths[i] > 0):
			bl_count[lengths[i]] = bl_count[lengths[i]] + 1
		i = i + 1
	int* next_code = cast(int*, malloc((max_bits + 1) * __word_size__))
	i = 0
	while (i <= max_bits):
		next_code[i] = 0
		i = i + 1
	int code = 0
	bl_count[0] = 0
	int len = 1
	while (len <= max_bits):
		code = (code + bl_count[len - 1]) << 1
		next_code[len] = code
		len = len + 1
	int* codes = cast(int*, malloc(n * __word_size__))
	i = 0
	while (i < n):
		codes[i] = 0
		if (lengths[i] != 0):
			codes[i] = next_code[lengths[i]]
			next_code[lengths[i]] = next_code[lengths[i]] + 1
		i = i + 1
	free(bl_count)
	free(next_code)
	return codes


/* ---- Fixed (static) Huffman tables, cached for the process ---- */


int* dfl_fixed_litlen_lengths_cache
int* dfl_fixed_litlen_codes_cache
int* dfl_fixed_dist_lengths_cache
int* dfl_fixed_dist_codes_cache


void dfl_init_fixed_tables():
	if (dfl_fixed_litlen_lengths_cache != 0):
		return
	int* ll = cast(int*, malloc(288 * __word_size__))
	int i = 0
	while (i < 144):
		ll[i] = 8
		i = i + 1
	while (i < 256):
		ll[i] = 9
		i = i + 1
	while (i < 280):
		ll[i] = 7
		i = i + 1
	while (i < 288):
		ll[i] = 8
		i = i + 1
	int* d = cast(int*, malloc(32 * __word_size__))
	i = 0
	while (i < 32):
		d[i] = 5
		i = i + 1
	dfl_fixed_litlen_lengths_cache = ll
	dfl_fixed_dist_lengths_cache = d
	dfl_fixed_litlen_codes_cache = dfl_build_codes(ll, 288, 15)
	dfl_fixed_dist_codes_cache = dfl_build_codes(d, 32, 15)


int* dfl_fixed_litlen_lengths():
	dfl_init_fixed_tables()
	return dfl_fixed_litlen_lengths_cache


int* dfl_fixed_litlen_codes():
	dfl_init_fixed_tables()
	return dfl_fixed_litlen_codes_cache


int* dfl_fixed_dist_lengths():
	dfl_init_fixed_tables()
	return dfl_fixed_dist_lengths_cache


int* dfl_fixed_dist_codes():
	dfl_init_fixed_tables()
	return dfl_fixed_dist_codes_cache


/* ---- Bit writer (mirrors inflate.w's bit reader, in reverse) ---- */


# Ordinary multi-bit fields (LEN, HLIT/HDIST/HCLEN, extra bits, ...) are
# written LSB-first (dfl_put_bits); Huffman codes are packed MSB-first
# of the code's own bits (dfl_put_huffman) -- RFC 1951 §3.1.1/§3.2.2,
# matching inflate.w's wh_decode which accumulates `(code << 1) | bit`
# treating the first bit read as the code's high bit.
struct dfl_bits:
	string_builder* out
	int cur_byte
	int cur_nbits


dfl_bits* dfl_bits_new():
	dfl_bits* w = new dfl_bits
	w.out = string_new()
	w.cur_byte = 0
	w.cur_nbits = 0
	return w


void dfl_put_bit(dfl_bits* w, int bit):
	w.cur_byte = w.cur_byte | ((bit & 1) << w.cur_nbits)
	w.cur_nbits = w.cur_nbits + 1
	if (w.cur_nbits == 8):
		string_append_char(w.out, w.cur_byte & 255)
		w.cur_byte = 0
		w.cur_nbits = 0


void dfl_put_bits(dfl_bits* w, int value, int nbits):
	int i = 0
	while (i < nbits):
		dfl_put_bit(w, shr(value, i) & 1)
		i = i + 1


void dfl_put_huffman(dfl_bits* w, int code, int length):
	int i = length - 1
	while (i >= 0):
		dfl_put_bit(w, shr(code, i) & 1)
		i = i - 1


# Pads the current byte with zero bits so the stream ends (or a stored
# block begins) on a byte boundary; a no-op if already aligned.
void dfl_align_byte(dfl_bits* w):
	if (w.cur_nbits != 0):
		string_append_char(w.out, w.cur_byte & 255)
		w.cur_byte = 0
		w.cur_nbits = 0


/* ---- Shared literal/length + distance body emitter ---- */


# Emits tokens [start,end) of `t` using the given litlen/dist code
# tables, then the block's EOB symbol (256) -- used by both the fixed
# (BTYPE=01) and dynamic (BTYPE=10) paths, which differ only in which
# tables were built.
void dfl_emit_body(dfl_bits* w, dfl_tokens* t, int start, int end, int* ll_codes, int* ll_lengths, int* d_codes, int* d_lengths):
	int i = start
	while (i < end):
		int len = t.len[i]
		int dist = t.dist[i]
		if (dist == 0):
			dfl_put_huffman(w, ll_codes[len], ll_lengths[len])
		else:
			int sym = 0
			int eb = 0
			int ev = 0
			dfl_length_symbol(len, &sym, &eb, &ev)
			dfl_put_huffman(w, ll_codes[sym], ll_lengths[sym])
			if (eb > 0):
				dfl_put_bits(w, ev, eb)
			int dsym = 0
			int deb = 0
			int dev = 0
			dfl_dist_symbol(dist, &dsym, &deb, &dev)
			dfl_put_huffman(w, d_codes[dsym], d_lengths[dsym])
			if (deb > 0):
				dfl_put_bits(w, dev, deb)
		i = i + 1
	dfl_put_huffman(w, ll_codes[256], ll_lengths[256])


# One BTYPE=01 block covering the whole token stream -- fixed Huffman
# codes are spec-constant, so there's no benefit to splitting into
# multiple blocks (unlike the dynamic path, no per-block header cost
# varies with block count).
void deflate_emit_fixed_block(dfl_bits* w, dfl_tokens* t, int is_last):
	dfl_put_bits(w, is_last & 1, 1)
	dfl_put_bits(w, 1, 2)
	dfl_emit_body(w, t, 0, t.count, dfl_fixed_litlen_codes(), dfl_fixed_litlen_lengths(), dfl_fixed_dist_codes(), dfl_fixed_dist_lengths())


/* ---- Dynamic Huffman blocks ---- */


# Literal/length (288) and distance (30) symbol frequencies over tokens
# [start,end), plus the one EOB symbol every block ends with.
void dfl_count_freqs(dfl_tokens* t, int start, int end, int* freq_ll, int* freq_d):
	int i = 0
	while (i < 288):
		freq_ll[i] = 0
		i = i + 1
	i = 0
	while (i < 30):
		freq_d[i] = 0
		i = i + 1
	i = start
	while (i < end):
		int len = t.len[i]
		int dist = t.dist[i]
		if (dist == 0):
			freq_ll[len] = freq_ll[len] + 1
		else:
			int sym = 0
			int eb = 0
			int ev = 0
			dfl_length_symbol(len, &sym, &eb, &ev)
			freq_ll[sym] = freq_ll[sym] + 1
			int dsym = 0
			int deb = 0
			int dev = 0
			dfl_dist_symbol(dist, &dsym, &deb, &dev)
			freq_d[dsym] = freq_d[dsym] + 1
		i = i + 1
	freq_ll[256] = freq_ll[256] + 1


# The code-length-alphabet (0-18) token stream for one combined
# litlen+dist length array (RFC 1951 §3.2.7): symbols 0-15 are literal
# code lengths, 16/17/18 are run-length repeats. Scanned as ONE
# continuous sequence across the litlen/dist boundary (inflate.w's
# decoder -- and real zlib's, per its inflate.c CODELENS state -- both
# treat HLIT+HDIST code lengths as one flat array with a single running
# "previous length," so a run is free to cross the boundary; this
# encoder takes advantage of that rather than resetting between the two
# tables the way zlib's own encoder conservatively does).
struct dfl_cltoks:
	int* sym
	int* extra_val
	int* extra_bits
	int count


dfl_cltoks* dfl_build_cl_tokens(int* lengths, int total):
	int* sym = cast(int*, malloc(total * __word_size__))
	int* extra_val = cast(int*, malloc(total * __word_size__))
	int* extra_bits = cast(int*, malloc(total * __word_size__))
	int count = 0
	int i = 0
	while (i < total):
		int curlen = lengths[i]
		int runlen = 1
		while ((i + runlen < total) && (lengths[i + runlen] == curlen)):
			runlen = runlen + 1
		if (curlen == 0):
			int remaining = runlen
			while (remaining > 0):
				if (remaining < 3):
					sym[count] = 0
					extra_val[count] = 0
					extra_bits[count] = 0
					count = count + 1
					remaining = remaining - 1
				else:
					int chunk = remaining
					if (chunk > 138):
						chunk = 138
					if (chunk >= 11):
						sym[count] = 18
						extra_val[count] = chunk - 11
						extra_bits[count] = 7
					else:
						sym[count] = 17
						extra_val[count] = chunk - 3
						extra_bits[count] = 3
					count = count + 1
					remaining = remaining - chunk
		else:
			sym[count] = curlen
			extra_val[count] = 0
			extra_bits[count] = 0
			count = count + 1
			int remaining = runlen - 1
			while (remaining > 0):
				if (remaining < 3):
					sym[count] = curlen
					extra_val[count] = 0
					extra_bits[count] = 0
					count = count + 1
					remaining = remaining - 1
				else:
					int chunk = remaining
					if (chunk > 6):
						chunk = 6
					sym[count] = 16
					extra_val[count] = chunk - 3
					extra_bits[count] = 2
					count = count + 1
					remaining = remaining - chunk
		i = i + runlen
	dfl_cltoks* t = new dfl_cltoks
	t.sym = sym
	t.extra_val = extra_val
	t.extra_bits = extra_bits
	t.count = count
	return t


# Builds and emits one dynamic-Huffman block (header + body) covering
# tokens [start,end) of `t`. Forces a placeholder length-1 code at
# distance symbol 0 when the block used no back-references at all (the
# "single short code" case inflate.w's wh_build already tolerates,
# needed because HDIST's declared count can never be zero -- RFC 1951
# §3.2.7) and clamps HLIT/HDIST down to the smallest count that still
# covers every nonzero-length symbol (always at least 257/1
# respectively, since EOB is always present and HDIST's minimum
# declared count is 1).
void dfl_emit_dynamic_block(dfl_bits* w, dfl_tokens* t, int start, int end, int is_last):
	int* freq_ll = cast(int*, malloc(288 * __word_size__))
	int* freq_d = cast(int*, malloc(30 * __word_size__))
	dfl_count_freqs(t, start, end, freq_ll, freq_d)
	int total_d = 0
	int i = 0
	while (i < 30):
		total_d = total_d + freq_d[i]
		i = i + 1
	if (total_d == 0):
		freq_d[0] = 1

	int* ll_lengths = dfl_build_lengths(freq_ll, 288, 15)
	int* d_lengths = dfl_build_lengths(freq_d, 30, 15)
	int* ll_codes = dfl_build_codes(ll_lengths, 288, 15)
	int* d_codes = dfl_build_codes(d_lengths, 30, 15)

	int hlit = 257
	int idx = 287
	while ((idx >= 257) && (ll_lengths[idx] == 0)):
		idx = idx - 1
	if (idx >= 257):
		hlit = idx + 1
	idx = 29
	while ((idx > 0) && (d_lengths[idx] == 0)):
		idx = idx - 1
	int hdist = idx + 1

	int total = hlit + hdist
	int* combined = cast(int*, malloc(total * __word_size__))
	i = 0
	while (i < hlit):
		combined[i] = ll_lengths[i]
		i = i + 1
	i = 0
	while (i < hdist):
		combined[hlit + i] = d_lengths[i]
		i = i + 1

	dfl_cltoks* cl = dfl_build_cl_tokens(combined, total)
	int* cl_freq = cast(int*, malloc(19 * __word_size__))
	i = 0
	while (i < 19):
		cl_freq[i] = 0
		i = i + 1
	i = 0
	while (i < cl.count):
		cl_freq[cl.sym[i]] = cl_freq[cl.sym[i]] + 1
		i = i + 1
	int* cl_lengths = dfl_build_lengths(cl_freq, 19, 7)
	int* cl_codes = dfl_build_codes(cl_lengths, 19, 7)

	int hclen_idx = 18
	while ((hclen_idx > 3) && (cl_lengths[inf_clc_order(hclen_idx)] == 0)):
		hclen_idx = hclen_idx - 1
	int hclen = hclen_idx + 1

	dfl_put_bits(w, is_last & 1, 1)
	dfl_put_bits(w, 2, 2)
	dfl_put_bits(w, hlit - 257, 5)
	dfl_put_bits(w, hdist - 1, 5)
	dfl_put_bits(w, hclen - 4, 4)
	i = 0
	while (i < hclen):
		dfl_put_bits(w, cl_lengths[inf_clc_order(i)], 3)
		i = i + 1
	i = 0
	while (i < cl.count):
		int sym = cl.sym[i]
		dfl_put_huffman(w, cl_codes[sym], cl_lengths[sym])
		if (cl.extra_bits[i] > 0):
			dfl_put_bits(w, cl.extra_val[i], cl.extra_bits[i])
		i = i + 1

	dfl_emit_body(w, t, start, end, ll_codes, ll_lengths, d_codes, d_lengths)

	free(freq_ll)
	free(freq_d)
	free(ll_lengths)
	free(d_lengths)
	free(ll_codes)
	free(d_codes)
	free(combined)
	free(cl.sym)
	free(cl.extra_val)
	free(cl.extra_bits)
	free(cl)
	free(cl_freq)
	free(cl_lengths)
	free(cl_codes)


/* ---- Top level ---- */


# Encodes `length` bytes at `data` as a DEFLATE stream, according to
# `level` (DEFLATE_LEVEL_STORED/FAST/BEST). A negative length is
# treated as zero, matching libs/standard/crypto/base64.w's convention;
# encoding trusted, caller-owned bytes cannot otherwise fail (docs/
# projects/compress.md §5.5), so this returns a plain value, never a
# wresult[T]*.
deflate_result* deflate(char* data, int length, int level):
	if (length < 0):
		length = 0
	if (level <= DEFLATE_LEVEL_STORED()):
		string_builder* out = string_new()
		int max_chunk = 65535
		if (length == 0):
			# A decoder must see at least one BFINAL=1 block, so the
			# empty input still produces one (empty) stored block.
			deflate_emit_stored_block(out, data, 0, 0, 1)
		int pos = 0
		while (pos < length):
			int remaining = length - pos
			int chunk = remaining
			if (chunk > max_chunk):
				chunk = max_chunk
			int is_final = 0
			if (pos + chunk == length):
				is_final = 1
			deflate_emit_stored_block(out, data, pos, chunk, is_final)
			pos = pos + chunk
		char* out_data = out.data
		int out_length = out.length
		free(out)
		deflate_result* r = new deflate_result
		r.data = out_data
		r.length = out_length
		return r

	int max_chain = dfl_max_chain_fast()
	if (level >= DEFLATE_LEVEL_BEST()):
		max_chain = dfl_max_chain_best()
	dfl_tokens* t = dfl_tokenize(data, length, max_chain)
	dfl_bits* w = dfl_bits_new()

	if (level >= DEFLATE_LEVEL_BEST()):
		if (t.count == 0):
			dfl_emit_dynamic_block(w, t, 0, 0, 1)
		else:
			int pos = 0
			while (pos < t.count):
				int block_start = pos
				int consumed = 0
				while ((pos < t.count) && (consumed < dfl_block_input_bytes())):
					if (t.dist[pos] == 0):
						consumed = consumed + 1
					else:
						consumed = consumed + t.len[pos]
					pos = pos + 1
				int is_last = 0
				if (pos >= t.count):
					is_last = 1
				dfl_emit_dynamic_block(w, t, block_start, pos, is_last)
	else:
		deflate_emit_fixed_block(w, t, 1)

	dfl_align_byte(w)
	char* out_data = w.out.data
	int out_length = w.out.length
	free(w.out)
	free(w)
	free(t.len)
	free(t.dist)
	free(t)
	deflate_result* r = new deflate_result
	r.data = out_data
	r.length = out_length
	return r
