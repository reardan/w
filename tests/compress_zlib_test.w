# wbuild: x64
/*
libs/extras/compress/zlib.w tests: round trip through this package's own
zlib_compress/zlib_decompress, decoding a stream produced by a real
python3 zlib.compress() (the "gateway to git-format interop" bar --
git's loose-object envelope is exactly this wrapper), and every
ZLIB_ERR_* error path plus INFLATE_ERR_* passthrough for a truncated
inner DEFLATE stream (see zlib.w's header comment for the passthrough
rationale).
*/
import lib.testing
import lib.result
import libs.extras.compress.deflate
import libs.extras.compress.inflate
import libs.extras.compress.zlib


void test_zlib_roundtrip():
	char* src = c"round trip through zlib_compress and zlib_decompress"
	int len = strlen(src)
	zlib_result* c = zlib_compress(src, len, DEFLATE_LEVEL_STORED())
	wresult[zlib_result*]* r = zlib_decompress(c.data, c.length, 0)
	assert1(result_is_ok[zlib_result*](r))
	zlib_result* out = result_value[zlib_result*](r)
	result_free[zlib_result*](r)
	assert_equal(len, out.length)
	assert_strings_equal(src, out.data)
	zlib_result_free(out)
	zlib_result_free(c)


# Same round trip, but through the real LZ77 + Huffman encoder (deflate.w
# stage 2) rather than stage 2a's stored blocks -- the wrapper layer
# shouldn't care which deflate() level produced the payload, but this
# pins that FAST/BEST actually flow through zlib_compress/zlib_decompress
# correctly, including the Adler-32 trailer over a longer, repetitive
# payload (a plain literal string is too short to exercise LZ77 matches).
void test_zlib_roundtrip_fast_and_best():
	int n = 4096
	char* src = malloc(n)
	int i = 0
	while (i < n):
		src[i] = 'a' + (i % 7)
		i = i + 1
	zlib_result* fast = zlib_compress(src, n, DEFLATE_LEVEL_FAST())
	wresult[zlib_result*]* fr = zlib_decompress(fast.data, fast.length, 0)
	assert1(result_is_ok[zlib_result*](fr))
	zlib_result* fout = result_value[zlib_result*](fr)
	result_free[zlib_result*](fr)
	assert_equal(n, fout.length)
	assert1(fast.length < n)
	int j = 0
	while (j < n):
		assert_equal(src[j] & 255, fout.data[j] & 255)
		j = j + 1
	zlib_result_free(fout)
	zlib_result_free(fast)

	zlib_result* best = zlib_compress(src, n, DEFLATE_LEVEL_BEST())
	wresult[zlib_result*]* br = zlib_decompress(best.data, best.length, 0)
	assert1(result_is_ok[zlib_result*](br))
	zlib_result* bout = result_value[zlib_result*](br)
	result_free[zlib_result*](br)
	assert_equal(n, bout.length)
	assert1(best.length < n)
	j = 0
	while (j < n):
		assert_equal(src[j] & 255, bout.data[j] & 255)
		j = j + 1
	zlib_result_free(bout)
	zlib_result_free(best)
	free(src)


void test_zlib_header_is_mod_31():
	char* src = c"anything"
	zlib_result* c = zlib_compress(src, strlen(src), DEFLATE_LEVEL_STORED())
	assert1(c.length >= 2)
	int cmf = c.data[0] & 255
	int flg = c.data[1] & 255
	assert_equal(0, (cmf * 256 + flg) % 31)
	assert_equal(8, cmf & 15)    # CM = deflate
	zlib_result_free(c)


void test_zlib_decompress_real_zlib_output():
	# python3: zlib.compress(b"zlib wrapper round trip test data 12345", 6)
	wresult[zlib_result*]* r = zlib_decompress(c"\x78\x9c\xab\xca\xc9\x4c\x52\x28\x2f\x4a\x2c\x28\x48\x2d\x52\x28\xca\x2f\xcd\x4b\x51\x28\x29\xca\x2c\x50\x28\x49\x2d\x2e\x51\x48\x49\x2c\x49\x54\x30\x34\x32\x36\x31\x05\x00\x27\xdb\x0d\xb3", 47, 0)
	assert1(result_is_ok[zlib_result*](r))
	zlib_result* out = result_value[zlib_result*](r)
	result_free[zlib_result*](r)
	assert_strings_equal(c"zlib wrapper round trip test data 12345", out.data)
	zlib_result_free(out)


void test_zlib_bad_checksum():
	# The same real-zlib stream with the last Adler-32 trailer byte
	# flipped: decompresses fine internally but the checksum fails.
	wresult[zlib_result*]* r = zlib_decompress(c"\x78\x9c\xab\xca\xc9\x4c\x52\x28\x2f\x4a\x2c\x28\x48\x2d\x52\x28\xca\x2f\xcd\x4b\x51\x28\x29\xca\x2c\x50\x28\x49\x2d\x2e\x51\x48\x49\x2c\x49\x54\x30\x34\x32\x36\x31\x05\x00\x27\xdb\x0d\x4c", 47, 0)
	assert1(result_is_error[zlib_result*](r))
	assert_equal(ZLIB_ERR_BAD_CHECKSUM(), result_code[zlib_result*](r))
	result_free[zlib_result*](r)


void test_zlib_unsupported_method():
	# CMF's low nibble (CM) set to 0 instead of 8, FLG adjusted to keep
	# the mod-31 header check passing so BAD_HEADER isn't hit first.
	wresult[zlib_result*]* r = zlib_decompress(c"\x70\x03\xab\xca\xc9\x4c\x52\x28\x2f\x4a\x2c\x28\x48\x2d\x52\x28\xca\x2f\xcd\x4b\x51\x28\x29\xca\x2c\x50\x28\x49\x2d\x2e\x51\x48\x49\x2c\x49\x54\x30\x34\x32\x36\x31\x05\x00\x27\xdb\x0d\xb3", 47, 0)
	assert1(result_is_error[zlib_result*](r))
	assert_equal(ZLIB_ERR_UNSUPPORTED_METHOD(), result_code[zlib_result*](r))
	result_free[zlib_result*](r)


void test_zlib_bad_header():
	# FLG's low bit flipped so (CMF*256+FLG) is no longer a multiple of 31.
	wresult[zlib_result*]* r = zlib_decompress(c"\x78\x9d\xab\xca\xc9\x4c\x52\x28\x2f\x4a\x2c\x28\x48\x2d\x52\x28\xca\x2f\xcd\x4b\x51\x28\x29\xca\x2c\x50\x28\x49\x2d\x2e\x51\x48\x49\x2c\x49\x54\x30\x34\x32\x36\x31\x05\x00\x27\xdb\x0d\xb3", 47, 0)
	assert1(result_is_error[zlib_result*](r))
	assert_equal(ZLIB_ERR_BAD_HEADER(), result_code[zlib_result*](r))
	result_free[zlib_result*](r)


void test_zlib_too_short_is_bad_header():
	wresult[zlib_result*]* r = zlib_decompress(c"\x78", 1, 0)
	assert1(result_is_error[zlib_result*](r))
	assert_equal(ZLIB_ERR_BAD_HEADER(), result_code[zlib_result*](r))
	result_free[zlib_result*](r)


void test_zlib_truncated_stream_passes_through_inflate_error():
	# Valid header, but the DEFLATE stream (and trailer) is cut short --
	# a failure from the wrapped inflate() call, so the code is
	# INFLATE_ERR_TRUNCATED, not a zlib-specific code (see zlib.w's
	# header comment on the passthrough convention).
	wresult[zlib_result*]* r = zlib_decompress(c"\x78\x9c\xab\xca\xc9\x4c\x52\x28\x2f\x4a", 10, 0)
	assert1(result_is_error[zlib_result*](r))
	assert_equal(INFLATE_ERR_TRUNCATED(), result_code[zlib_result*](r))
	result_free[zlib_result*](r)


void test_zlib_max_output_cap():
	deflate_result* d = deflate(c"0123456789", 10, DEFLATE_LEVEL_STORED())
	zlib_result* c = zlib_compress(c"0123456789", 10, DEFLATE_LEVEL_STORED())
	wresult[zlib_result*]* r = zlib_decompress(c.data, c.length, 3)
	assert1(result_is_error[zlib_result*](r))
	assert_equal(INFLATE_ERR_TOO_LARGE(), result_code[zlib_result*](r))
	result_free[zlib_result*](r)
	zlib_result_free(c)
	deflate_result_free(d)


void test_zlib_error_string_covers_every_code_and_falls_through():
	assert1(strlen(zlib_error_string(ZLIB_ERR_BAD_HEADER())) > 0)
	assert1(strlen(zlib_error_string(ZLIB_ERR_UNSUPPORTED_METHOD())) > 0)
	assert1(strlen(zlib_error_string(ZLIB_ERR_BAD_CHECKSUM())) > 0)
	# Falls through to inflate_error_string for a non-zlib-specific code.
	assert_strings_equal(inflate_error_string(INFLATE_ERR_TRUNCATED()), zlib_error_string(INFLATE_ERR_TRUNCATED()))
