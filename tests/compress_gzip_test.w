# wbuild: x64
/*
libs/extras/compress/gzip.w tests: round trip through this package's own
gzip_compress/gzip_decompress, decoding streams produced by real python3
gzip.compress() (plain, and with an FNAME flag set -- real gzip(1)/git/
browser output routinely sets FNAME, so parsing and skipping it is part
of the "gateway to interop" conformance bar), determinism of
gzip_compress's own output, and every GZIP_ERR_* error path plus
INFLATE_ERR_* passthrough (see zlib_test's sibling comment; the same
convention applies here).
*/
import lib.testing
import lib.result
import libs.extras.compress.deflate
import libs.extras.compress.inflate
import libs.extras.compress.gzip


void test_gzip_roundtrip():
	char* src = c"round trip through gzip_compress and gzip_decompress"
	int len = strlen(src)
	gzip_result* c = gzip_compress(src, len, DEFLATE_LEVEL_STORED())
	wresult[gzip_result*]* r = gzip_decompress(c.data, c.length, 0)
	assert1(result_is_ok[gzip_result*](r))
	gzip_result* out = result_value[gzip_result*](r)
	result_free[gzip_result*](r)
	assert_equal(len, out.length)
	assert_strings_equal(src, out.data)
	gzip_result_free(out)
	gzip_result_free(c)


# Same round trip through the real LZ77 + Huffman encoder (deflate.w
# stage 2) rather than stage 2a's stored blocks -- pins that FAST/BEST
# flow through gzip_compress/gzip_decompress correctly, including the
# CRC-32/ISIZE trailer over a longer, repetitive payload (a plain
# literal string is too short to exercise LZ77 matches).
void test_gzip_roundtrip_fast_and_best():
	int n = 4096
	char* src = malloc(n)
	int i = 0
	while (i < n):
		src[i] = 'a' + (i % 7)
		i = i + 1
	gzip_result* fast = gzip_compress(src, n, DEFLATE_LEVEL_FAST())
	wresult[gzip_result*]* fr = gzip_decompress(fast.data, fast.length, 0)
	assert1(result_is_ok[gzip_result*](fr))
	gzip_result* fout = result_value[gzip_result*](fr)
	result_free[gzip_result*](fr)
	assert_equal(n, fout.length)
	assert1(fast.length < n)
	int j = 0
	while (j < n):
		assert_equal(src[j] & 255, fout.data[j] & 255)
		j = j + 1
	gzip_result_free(fout)
	gzip_result_free(fast)

	gzip_result* best = gzip_compress(src, n, DEFLATE_LEVEL_BEST())
	wresult[gzip_result*]* br = gzip_decompress(best.data, best.length, 0)
	assert1(result_is_ok[gzip_result*](br))
	gzip_result* bout = result_value[gzip_result*](br)
	result_free[gzip_result*](br)
	assert_equal(n, bout.length)
	assert1(best.length < n)
	j = 0
	while (j < n):
		assert_equal(src[j] & 255, bout.data[j] & 255)
		j = j + 1
	gzip_result_free(bout)
	gzip_result_free(best)
	free(src)


void test_gzip_compress_is_deterministic():
	# Reproducible-build property the design doc calls out explicitly
	# (§5.4): same input + level -> byte-identical output every time
	# (MTIME fixed at 0, no FNAME/FCOMMENT/FEXTRA).
	char* src = c"deterministic gzip output"
	int len = strlen(src)
	gzip_result* a = gzip_compress(src, len, DEFLATE_LEVEL_STORED())
	gzip_result* b = gzip_compress(src, len, DEFLATE_LEVEL_STORED())
	assert_equal(a.length, b.length)
	int i = 0
	while (i < a.length):
		assert_equal(a.data[i] & 255, b.data[i] & 255)
		i = i + 1
	# Magic, method, and a zeroed MTIME are pinned bytes.
	assert_equal(0x1f, a.data[0] & 255)
	assert_equal(0x8b, a.data[1] & 255)
	assert_equal(8, a.data[2] & 255)
	assert_equal(0, a.data[3] & 255)    # FLG: no optional fields
	assert_equal(0, a.data[4] & 255)    # MTIME byte 0
	assert_equal(0, a.data[7] & 255)    # MTIME byte 3
	gzip_result_free(a)
	gzip_result_free(b)


void test_gzip_decompress_real_gzip_output():
	# python3: gzip.compress(b"gzip wrapper round trip test data 67890", 6, mtime=0)
	wresult[gzip_result*]* r = gzip_decompress(c"\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03\x4b\xaf\xca\x2c\x50\x28\x2f\x4a\x2c\x28\x48\x2d\x52\x28\xca\x2f\xcd\x4b\x51\x28\x29\x02\x0a\x95\xa4\x16\x97\x28\xa4\x24\x96\x24\x2a\x98\x99\x5b\x58\x1a\x00\x00\xfb\x36\x52\xdf\x27\x00\x00\x00", 58, 0)
	assert1(result_is_ok[gzip_result*](r))
	gzip_result* out = result_value[gzip_result*](r)
	result_free[gzip_result*](r)
	assert_strings_equal(c"gzip wrapper round trip test data 67890", out.data)
	gzip_result_free(out)


void test_gzip_decompress_with_fname_flag():
	# python3: GzipFile(filename="test.txt", mtime=0).write(b"named gzip member data")
	# FNAME set in the flag byte -- the name field must be parsed and
	# skipped, not mistaken for compressed data.
	wresult[gzip_result*]* r = gzip_decompress(c"\x1f\x8b\x08\x08\x00\x00\x00\x00\x02\xff\x74\x65\x73\x74\x2e\x74\x78\x74\x00\xcb\x4b\xcc\x4d\x4d\x51\x48\xaf\xca\x2c\x50\xc8\x4d\xcd\x4d\x4a\x2d\x52\x48\x49\x2c\x49\x04\x00\xd9\x47\xf1\xb7\x16\x00\x00\x00", 51, 0)
	assert1(result_is_ok[gzip_result*](r))
	gzip_result* out = result_value[gzip_result*](r)
	result_free[gzip_result*](r)
	assert_strings_equal(c"named gzip member data", out.data)
	gzip_result_free(out)


void test_gzip_bad_magic():
	wresult[gzip_result*]* r = gzip_decompress(c"\x1f\x8c\x08\x00\x00\x00\x00\x00\x00\x03\x4b\xaf\xca\x2c\x50\x28\x2f\x4a\x2c\x28\x48\x2d\x52\x28\xca\x2f\xcd\x4b\x51\x28\x29\x02\x0a\x95\xa4\x16\x97\x28\xa4\x24\x96\x24\x2a\x98\x99\x5b\x58\x1a\x00\x00\xfb\x36\x52\xdf\x27\x00\x00\x00", 58, 0)
	assert1(result_is_error[gzip_result*](r))
	assert_equal(GZIP_ERR_BAD_MAGIC(), result_code[gzip_result*](r))
	result_free[gzip_result*](r)


void test_gzip_bad_crc():
	wresult[gzip_result*]* r = gzip_decompress(c"\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03\x4b\xaf\xca\x2c\x50\x28\x2f\x4a\x2c\x28\x48\x2d\x52\x28\xca\x2f\xcd\x4b\x51\x28\x29\x02\x0a\x95\xa4\x16\x97\x28\xa4\x24\x96\x24\x2a\x98\x99\x5b\x58\x1a\x00\x00\x04\x36\x52\xdf\x27\x00\x00\x00", 58, 0)
	assert1(result_is_error[gzip_result*](r))
	assert_equal(GZIP_ERR_BAD_CRC(), result_code[gzip_result*](r))
	result_free[gzip_result*](r)


void test_gzip_bad_size():
	# CRC-32 still matches (the payload itself is untouched) but the
	# ISIZE trailer field has been corrupted -- a distinct failure mode
	# from a CRC mismatch, so it needs its own fixture.
	wresult[gzip_result*]* r = gzip_decompress(c"\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03\x4b\xaf\xca\x2c\x50\x28\x2f\x4a\x2c\x28\x48\x2d\x52\x28\xca\x2f\xcd\x4b\x51\x28\x29\x02\x0a\x95\xa4\x16\x97\x28\xa4\x24\x96\x24\x2a\x98\x99\x5b\x58\x1a\x00\x00\xfb\x36\x52\xdf\xd8\x00\x00\x00", 58, 0)
	assert1(result_is_error[gzip_result*](r))
	assert_equal(GZIP_ERR_BAD_SIZE(), result_code[gzip_result*](r))
	result_free[gzip_result*](r)


void test_gzip_unsupported_method():
	char* d = c"\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03\x4b\xaf\xca\x2c\x50\x28\x2f\x4a\x2c\x28\x48\x2d\x52\x28\xca\x2f\xcd\x4b\x51\x28\x29\x02\x0a\x95\xa4\x16\x97\x28\xa4\x24\x96\x24\x2a\x98\x99\x5b\x58\x1a\x00\x00\xfb\x36\x52\xdf\x27\x00\x00\x00"
	int len = 58
	char* bad = malloc(len)
	int i = 0
	while (i < len):
		bad[i] = d[i]
		i = i + 1
	bad[2] = 9    # CM: not deflate
	wresult[gzip_result*]* r = gzip_decompress(bad, len, 0)
	assert1(result_is_error[gzip_result*](r))
	assert_equal(GZIP_ERR_UNSUPPORTED_METHOD(), result_code[gzip_result*](r))
	result_free[gzip_result*](r)
	free(bad)


void test_gzip_too_short_is_truncated():
	wresult[gzip_result*]* r = gzip_decompress(c"\x1f\x8b\x08", 3, 0)
	assert1(result_is_error[gzip_result*](r))
	assert_equal(GZIP_ERR_TRUNCATED(), result_code[gzip_result*](r))
	result_free[gzip_result*](r)


void test_gzip_truncated_mid_header_region():
	# Full 10-byte fixed header present, but the deflate stream + 8-byte
	# trailer that must follow are missing entirely.
	wresult[gzip_result*]* r = gzip_decompress(c"\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03", 10, 0)
	assert1(result_is_error[gzip_result*](r))
	assert_equal(GZIP_ERR_TRUNCATED(), result_code[gzip_result*](r))
	result_free[gzip_result*](r)


void test_gzip_truncated_stream_passes_through_inflate_error():
	# 20 bytes: past the fixed header (so gzip.w's own "room for an
	# 8-byte trailer" precheck passes and this reaches inflate_ex), but
	# only 10 of the real 40-byte DEFLATE stream are present -- the
	# failure comes from inflate(), so the code is INFLATE_ERR_TRUNCATED
	# (5), not GZIP_ERR_TRUNCATED (205); see gzip.w's header comment on
	# the passthrough convention.
	wresult[gzip_result*]* r = gzip_decompress(c"\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03\x4b\xaf\xca\x2c\x50\x28\x2f\x4a\x2c\x28", 20, 0)
	assert1(result_is_error[gzip_result*](r))
	assert_equal(INFLATE_ERR_TRUNCATED(), result_code[gzip_result*](r))
	result_free[gzip_result*](r)


void test_gzip_max_output_cap():
	wresult[gzip_result*]* r = gzip_decompress(c"\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03\x4b\xaf\xca\x2c\x50\x28\x2f\x4a\x2c\x28\x48\x2d\x52\x28\xca\x2f\xcd\x4b\x51\x28\x29\x02\x0a\x95\xa4\x16\x97\x28\xa4\x24\x96\x24\x2a\x98\x99\x5b\x58\x1a\x00\x00\xfb\x36\x52\xdf\x27\x00\x00\x00", 58, 5)
	assert1(result_is_error[gzip_result*](r))
	assert_equal(INFLATE_ERR_TOO_LARGE(), result_code[gzip_result*](r))
	result_free[gzip_result*](r)


void test_gzip_error_string_covers_every_code_and_falls_through():
	assert1(strlen(gzip_error_string(GZIP_ERR_BAD_MAGIC())) > 0)
	assert1(strlen(gzip_error_string(GZIP_ERR_UNSUPPORTED_METHOD())) > 0)
	assert1(strlen(gzip_error_string(GZIP_ERR_BAD_CRC())) > 0)
	assert1(strlen(gzip_error_string(GZIP_ERR_BAD_SIZE())) > 0)
	assert1(strlen(gzip_error_string(GZIP_ERR_TRUNCATED())) > 0)
	assert_strings_equal(inflate_error_string(INFLATE_ERR_BAD_HUFFMAN()), gzip_error_string(INFLATE_ERR_BAD_HUFFMAN()))
