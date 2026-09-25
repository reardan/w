# wbuild: x64
import lib.testing
import lib.rle


void rle_test_roundtrip(char* pixels, int total, int want_length):
	int length = 0
	char* stream = rle_encode(pixels, total, &length)
	if (want_length >= 0):
		assert_equal(want_length, length)
	char* out = rle_decode(stream, length, malloc(total), total)
	for i in range(total):
		assert_equal(pixels[i] & 255, out[i] & 255)


void test_rle_runs_and_literals():
	# 4 zeros -> one zero-run token; "ab" -> literal; 3 x 255 -> full run.
	rle_test_roundtrip(c"\x00\x00\x00\x00ab\xff\xff\xff", 9, 2 + 4 + 2)
	int length = 0
	char* s = rle_encode(c"\x00\x00\x00\x00ab\xff\xff\xff", 9, &length)
	assert_equal(0, s[0])
	assert_equal(4, s[1])
	assert_equal(2, s[2])
	assert_equal(2, s[3])
	assert_equal('a', s[4])
	assert_equal(1, s[6] & 255)
	assert_equal(3, s[7] & 255)


void test_rle_short_runs_stay_literal():
	# Two-byte 0/255 runs are cheaper inline than as tokens.
	rle_test_roundtrip(c"\x00\x00x\xff\xffy", 6, 8)


void test_rle_long_runs_split_at_255():
	int total = 600
	char* pixels = malloc(total)
	for i in range(total):
		pixels[i] = 0
		if (i >= 300):
			pixels[i] = (i * 7) & 255
	rle_test_roundtrip(pixels, total, -1)


void test_rle_decode_clips_and_pads():
	char* out = malloc(6)
	# A 255-run of 10 into 4 bytes clips; the rest of a 6-byte buffer
	# past a short stream is zero.
	rle_decode(c"\x01\x0a", 2, out, 4)
	assert_equal(255, out[3] & 255)
	out[4] = 9
	out[5] = 9
	rle_decode(c"\x01\x02", 2, out, 6)
	assert_equal(255, out[1] & 255)
	assert_equal(0, out[2])
	assert_equal(0, out[5])
