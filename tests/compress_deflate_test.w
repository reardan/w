# wbuild: x64
/*
libs/extras/compress/deflate.w tests: stage 2a (stored blocks only,
docs/projects/compress.md §3/§9). deflate() only needs to be
spec-conformant, not small -- every assertion here is a round trip
through inflate.w, plus direct checks of the emitted bytes for the
empty-input and stored-block-chaining shapes deflate_emit_stored_block
is responsible for.
*/
import lib.testing
import lib.result
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
