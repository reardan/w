# wbuild: x64
/*
libs/extras/compress/deflate.w tests. The original stage-2a coverage
below (stored blocks only) is unchanged; the FAST/BEST section further
down covers the LZ77 hash-chain matcher + fixed Huffman path and the
dynamic-Huffman/block-splitting path, per docs/projects/compress.md §3.
Every case is a round trip through inflate.w -- the fully conformant
decoder from stage 1 -- plus a handful of direct compression-ratio
assertions (repetitive data must actually shrink) and byte-level checks
for the stored-block shapes deflate_emit_stored_block is responsible
for.
*/
import lib.testing
import lib.result
import lib.rand
import lib.file
import libs.extras.compress.inflate
import libs.extras.compress.deflate


void dt_roundtrip(char* label, char* data, int len):
	deflate_result* d = deflate(data, len, DEFLATE_LEVEL_STORED())
	wresult[inflate_result*]* r = inflate(d.data, d.length, 0)
	if (result_is_error[inflate_result*](r)):
		print2(label)
		print2(c": inflate of deflate() output failed: ")
		println2(inflate_error_string(result_code[inflate_result*](r)))
		exit(1)
	inflate_result* o = result_value[inflate_result*](r)
	result_free[inflate_result*](r)
	if (o.length != len):
		print2(label)
		println2(c": roundtrip length mismatch")
		exit(1)
	int i = 0
	while (i < len):
		if ((o.data[i] & 255) != (data[i] & 255)):
			print2(label)
			print2(c": roundtrip byte mismatch at offset ")
			println2(itoa(i))
			exit(1)
		i = i + 1
	inflate_result_free(o)
	deflate_result_free(d)


void test_deflate_empty_input_roundtrips():
	dt_roundtrip(c"empty", c"", 0)


void test_deflate_empty_input_is_one_final_block():
	# The empty case still must produce a decodable stream (a decoder
	# expects at least one BFINAL=1 block): BFINAL=1,BTYPE=00,LEN=0.
	deflate_result* d = deflate(c"", 0, DEFLATE_LEVEL_STORED())
	assert_equal(5, d.length)
	assert_equal(1, d.data[0] & 255)
	assert_equal(0, d.data[1] & 255)
	assert_equal(0, d.data[2] & 255)
	assert_equal(255, d.data[3] & 255)
	assert_equal(255, d.data[4] & 255)
	deflate_result_free(d)


void test_deflate_small_input_roundtrips():
	dt_roundtrip(c"small", c"hello, deflate!", 15)


void test_deflate_binary_payload_roundtrips():
	int n = 512
	char* buf = malloc(n)
	int i = 0
	while (i < n):
		buf[i] = i & 255
		i = i + 1
	dt_roundtrip(c"binary 0..511", buf, n)
	free(buf)


void test_deflate_chains_stored_blocks_over_65535_bytes():
	# LEN is a u16, so any single stored block caps at 65535 bytes;
	# deflate() must chain multiple blocks for larger input, each
	# correctly non-final except the last.
	int n = 70000
	char* buf = malloc(n)
	int i = 0
	while (i < n):
		buf[i] = (i * 7 + (i >> 3)) & 255
		i = i + 1
	deflate_result* d = deflate(buf, n, DEFLATE_LEVEL_STORED())
	# Two chained blocks: 65535 bytes then 4465 bytes, 5-byte header each.
	assert_equal(2 * 5 + n, d.length)
	assert_equal(0, d.data[0] & 255)    # first block: BFINAL=0
	int second_header = 5 + 65535
	assert_equal(1, d.data[second_header] & 255)    # second block: BFINAL=1
	dt_roundtrip(c"70000-byte chained", buf, n)
	deflate_result_free(d)
	free(buf)


void test_deflate_negative_length_clamps_to_zero():
	deflate_result* d1 = deflate(c"ignored", -1, DEFLATE_LEVEL_STORED())
	deflate_result* d2 = deflate(c"", 0, DEFLATE_LEVEL_STORED())
	assert_equal(d2.length, d1.length)
	deflate_result_free(d1)
	deflate_result_free(d2)


/*
---- FAST (LZ77 + fixed Huffman) and BEST (LZ77 + dynamic Huffman +
block splitting) ----
*/


void dt_roundtrip_level(char* label, char* data, int len, int level):
	deflate_result* d = deflate(data, len, level)
	wresult[inflate_result*]* r = inflate(d.data, d.length, 0)
	if (result_is_error[inflate_result*](r)):
		print2(label)
		print2(c": inflate of deflate() output failed: ")
		println2(inflate_error_string(result_code[inflate_result*](r)))
		exit(1)
	inflate_result* o = result_value[inflate_result*](r)
	result_free[inflate_result*](r)
	if (o.length != len):
		print2(label)
		print2(c": roundtrip length mismatch got=")
		print2(itoa(o.length))
		print2(c" want=")
		println2(itoa(len))
		exit(1)
	int i = 0
	while (i < len):
		if ((o.data[i] & 255) != (data[i] & 255)):
			print2(label)
			print2(c": roundtrip byte mismatch at offset ")
			println2(itoa(i))
			exit(1)
		i = i + 1
	inflate_result_free(o)
	deflate_result_free(d)


void dt_roundtrip_all_levels(char* label, char* data, int len):
	dt_roundtrip_level(label, data, len, DEFLATE_LEVEL_STORED())
	dt_roundtrip_level(label, data, len, DEFLATE_LEVEL_FAST())
	dt_roundtrip_level(label, data, len, DEFLATE_LEVEL_BEST())


void test_deflate_fast_and_best_roundtrip_empty_and_tiny():
	dt_roundtrip_all_levels(c"empty", c"", 0)
	dt_roundtrip_all_levels(c"tiny-1", c"h", 1)
	dt_roundtrip_all_levels(c"tiny-2", c"hi", 2)
	dt_roundtrip_all_levels(c"small", c"hello, deflate!", 15)


void test_deflate_fast_and_best_roundtrip_binary_payload():
	int n = 512
	char* buf = malloc(n)
	int i = 0
	while (i < n):
		buf[i] = i & 255
		i = i + 1
	dt_roundtrip_all_levels(c"binary 0..511", buf, n)
	free(buf)


# LZ77 + Huffman should shrink a long repeated pattern dramatically --
# a real compression-ratio assertion (docs/projects/compress.md §8), not
# just a round trip.
void test_deflate_fast_and_best_compress_highly_repetitive_data():
	int n = 20000
	char* buf = malloc(n)
	int i = 0
	while (i < n):
		buf[i] = 'a' + (i % 4)
		i = i + 1
	deflate_result* stored = deflate(buf, n, DEFLATE_LEVEL_STORED())
	deflate_result* fast = deflate(buf, n, DEFLATE_LEVEL_FAST())
	deflate_result* best = deflate(buf, n, DEFLATE_LEVEL_BEST())
	asserts(c"fast must shrink highly repetitive data below 1/10th", fast.length < n / 10)
	asserts(c"best must be no larger than fast plus a little header slack", best.length <= fast.length + 16)
	asserts(c"fast must be much smaller than the stored encoding", fast.length < stored.length)
	dt_roundtrip_level(c"repetitive/fast", buf, n, DEFLATE_LEVEL_FAST())
	dt_roundtrip_level(c"repetitive/best", buf, n, DEFLATE_LEVEL_BEST())
	deflate_result_free(stored)
	deflate_result_free(fast)
	deflate_result_free(best)
	free(buf)


# A real PRNG (not the low bits of a weak LCG, which are themselves
# repetitive) so this genuinely exercises the "match finder mostly
# fails" path -- fixed/dynamic Huffman may expand near-uniform byte
# frequencies slightly (unavoidable code-length overhead), but must
# still round-trip exactly.
void test_deflate_fast_and_best_roundtrip_incompressible_random_data():
	int n = 20000
	char* buf = malloc(n)
	rand_state rs
	rand_init(&rs, 1234)
	int i = 0
	while (i < n):
		buf[i] = rand_next31(&rs) & 255
		i = i + 1
	dt_roundtrip_level(c"random/fast", buf, n, DEFLATE_LEVEL_FAST())
	dt_roundtrip_level(c"random/best", buf, n, DEFLATE_LEVEL_BEST())
	free(buf)


void dt_boundary_case(int n, rand_state* rs):
	char* buf = malloc(n)
	int i = 0
	while (i < n):
		# A mix of pseudo-random bytes and a repeating pattern so both
		# literals and back-references straddle the boundary.
		if ((i % 5) == 0):
			buf[i] = rand_next31(rs) & 255
		else:
			buf[i] = (i * 3) & 255
		i = i + 1
	dt_roundtrip_level(c"boundary/fast", buf, n, DEFLATE_LEVEL_FAST())
	dt_roundtrip_level(c"boundary/best", buf, n, DEFLATE_LEVEL_BEST())
	free(buf)


# Sizes crossing the LZ77 window (32768) and the block-splitting
# heuristic's chunk size (also 32768 bytes of input, see deflate.w's
# dfl_block_input_bytes) in both directions, plus the stored-block
# chaining boundary (65535/65536) inherited from the stage-2a coverage
# above.
void test_deflate_fast_and_best_roundtrip_boundary_sizes():
	rand_state rs
	rand_init(&rs, 99)
	dt_boundary_case(32767, &rs)
	dt_boundary_case(32768, &rs)
	dt_boundary_case(32769, &rs)
	dt_boundary_case(65535, &rs)
	dt_boundary_case(65536, &rs)
	dt_boundary_case(65537, &rs)
	dt_boundary_case(100000, &rs)
	dt_boundary_case(131072, &rs)


# A real W source file from the tree (docs/projects/compress.md §8's "a
# large source file" corpus case) -- text-heavy and highly redundant,
# the kind of input this package's motivating consumers (cas.w,
# http_client.w, the build cache) actually compress.
void test_deflate_large_source_file_roundtrips_and_compresses():
	char* text = file_read_text(c"compiler/tokenizer.w")
	asserts(c"missing compiler/tokenizer.w fixture source", cast(int, text) != 0)
	int len = strlen(text)
	asserts(c"compiler/tokenizer.w unexpectedly tiny", len > 4000)
	deflate_result* fast = deflate(text, len, DEFLATE_LEVEL_FAST())
	deflate_result* best = deflate(text, len, DEFLATE_LEVEL_BEST())
	asserts(c"fast must compress real source well below half size", fast.length < len / 2)
	asserts(c"best must compress at least as well as fast on real source", best.length <= fast.length)
	dt_roundtrip_level(c"tokenizer.w/fast", text, len, DEFLATE_LEVEL_FAST())
	dt_roundtrip_level(c"tokenizer.w/best", text, len, DEFLATE_LEVEL_BEST())
	deflate_result_free(fast)
	deflate_result_free(best)


# Anything <= STORED is the stored path; DEFLATE_LEVEL_FAST() (or
# anything below BEST) is fixed Huffman; DEFLATE_LEVEL_BEST() or above
# is dynamic Huffman -- deflate.w's header comment documents this
# dispatch explicitly, so pin it against future refactors.
void test_deflate_level_dispatch_boundaries():
	char* data = c"the quick brown fox jumps over the lazy dog, the quick brown fox"
	int len = strlen(data)
	deflate_result* neg = deflate(data, len, -1)
	deflate_result* stored = deflate(data, len, DEFLATE_LEVEL_STORED())
	assert_equal(stored.length, neg.length)
	deflate_result* fast = deflate(data, len, DEFLATE_LEVEL_FAST())
	deflate_result* best = deflate(data, len, DEFLATE_LEVEL_BEST())
	deflate_result* above_best = deflate(data, len, DEFLATE_LEVEL_BEST() + 5)
	dt_roundtrip_level(c"above-best", data, len, DEFLATE_LEVEL_BEST() + 5)
	asserts(c"fast and stored must differ for compressible input", fast.length != stored.length)
	asserts(c"a level above BEST must still take the dynamic path (same bytes as BEST)", above_best.length == best.length)
	deflate_result_free(neg)
	deflate_result_free(stored)
	deflate_result_free(fast)
	deflate_result_free(best)
	deflate_result_free(above_best)
