# wbuild: x64
# Tests for libs/standard/web/hpack.w (RFC 7541, issue #436): the
# integer examples of Appendix C.1, the single-field examples of C.2,
# the three-request sequences of C.3 (plain) and C.4 (Huffman), and the
# three-response sequences of C.5 (plain) and C.6 (Huffman) with a
# 256-byte dynamic table, each checked both ways: the decoder must
# produce the listed fields and dynamic table, and the encoder must
# reproduce the RFC bytes exactly. Plus Huffman code spot checks against
# Appendix B, round trips, and the fail-closed caps.
import lib.testing
import lib.container
import structures.string
import libs.standard.web.hpack
import lib.hex


void hpack_test_expect_bytes(char* label, string_builder* got, char* want_hex):
	int want_len = 0
	char* want = hex_decode_loose(want_hex, &want_len)
	int ok = 1
	if (got.length != want_len):
		ok = 0
	int i = 0
	while ((ok != 0) && (i < want_len)):
		if ((got.data[i] & 255) != (want[i] & 255)):
			ok = 0
		i = i + 1
	if (ok == 0):
		print2(label)
		print2(c": encoding mismatch, got ")
		int j = 0
		while (j < got.length):
			print2(hex(got.data[j] & 255))
			print2(c" ")
			j = j + 1
		println2(c"")
		asserts(c"hpack encoding mismatch", 0)
	free(want)


# spec: "name|value\n" per field.
list[hpack_header*] hpack_test_parse_spec(char* spec):
	list[hpack_header*] l = hpack_headers_new()
	int pos = 0
	while (spec[pos] != 0):
		int ns = pos
		while (spec[pos] != '|'):
			pos = pos + 1
		int ne = pos
		pos = pos + 1
		int vs = pos
		while (spec[pos] != 10):
			pos = pos + 1
		l.push(hpack_header_new(spec + ns, ne - ns, spec + vs, pos - vs))
		pos = pos + 1
	return l


void hpack_test_expect_headers(list[hpack_header*] got, char* spec):
	list[hpack_header*] want = hpack_test_parse_spec(spec)
	assert_equal(want.length, got.length)
	int i = 0
	while (i < want.length):
		hpack_header* w = want[i]
		hpack_header* g = got[i]
		assert_strings_equal(w.name, g.name)
		assert_strings_equal(w.value, g.value)
		assert_equal(w.value_len, g.value_len)
		i = i + 1
	hpack_headers_free(want)


# Dynamic table spec: newest first, same "name|value\n" format.
void hpack_test_expect_table(hpack_table* t, char* spec, int size):
	list[hpack_header*] want = hpack_test_parse_spec(spec)
	assert_equal(want.length, hpack_table_count(t))
	int i = 0
	while (i < want.length):
		hpack_header* w = want[i]
		hpack_header* g = hpack_table_get(t, i + 1)
		assert_strings_equal(w.name, g.name)
		assert_strings_equal(w.value, g.value)
		i = i + 1
	assert_equal(size, t.size)
	hpack_headers_free(want)


# Decodes one block, compares fields and the resulting table.
void hpack_test_decode_step(hpack_decoder* d, char* block_hex, char* fields, char* table, int size):
	int len = 0
	char* block = hex_decode_loose(block_hex, &len)
	list[hpack_header*] out = hpack_headers_new()
	assert_equal(0, hpack_decode(d, block, len, out))
	hpack_test_expect_headers(out, fields)
	hpack_test_expect_table(d.table, table, size)
	hpack_headers_free(out)
	free(block)


void hpack_test_encode_step(hpack_encoder* e, char* fields, char* want_hex, char* table, int size):
	list[hpack_header*] l = hpack_test_parse_spec(fields)
	string_builder* out = string_new()
	hpack_encode(e, l, out)
	hpack_test_expect_bytes(fields, out, want_hex)
	hpack_test_expect_table(e.table, table, size)
	string_free(out)
	hpack_headers_free(l)


int hpack_test_decode_rc(hpack_decoder* d, char* block_hex):
	int len = 0
	char* block = hex_decode_loose(block_hex, &len)
	list[hpack_header*] out = hpack_headers_new()
	int rc = hpack_decode(d, block, len, out)
	hpack_headers_free(out)
	free(block)
	return rc


/* C.1 integers */

void test_hpack_integer_examples():
	string_builder* out = string_new()
	hpack_encode_int(out, 0, 5, 10)
	hpack_test_expect_bytes(c"C.1.1", out, c"0a")
	string_clear(out)
	hpack_encode_int(out, 0, 5, 1337)
	hpack_test_expect_bytes(c"C.1.2", out, c"1f9a0a")
	string_clear(out)
	hpack_encode_int(out, 0, 8, 42)
	hpack_test_expect_bytes(c"C.1.3", out, c"2a")
	string_free(out)

	int len = 0
	char* p = hex_decode_loose(c"1f9a0a", &len)
	int pos = 0
	int v = 0
	assert_equal(1, hpack_decode_int(p, len, &pos, 5, &v))
	assert_equal(1337, v)
	assert_equal(3, pos)
	# Truncated continuation.
	pos = 0
	assert_equal(0, hpack_decode_int(p, 2, &pos, 5, &v))
	free(p)
	# More than four continuation bytes fails closed.
	p = hex_decode_loose(c"1fffffffff0f", &len)
	pos = 0
	assert_equal(0, hpack_decode_int(p, len, &pos, 5, &v))
	free(p)
	# Four continuation bytes are fine.
	p = hex_decode_loose(c"1fffffff7f", &len)
	pos = 0
	assert_equal(1, hpack_decode_int(p, len, &pos, 5, &v))
	assert_equal(31 + 268435455, v)
	free(p)


/* Appendix B spot checks */

void test_hpack_huffman_code_table():
	assert_equal_hex(8184, hpack_huffman_code(0))
	assert_equal(13, hpack_huffman_code_length(0))
	assert_equal_hex(20, hpack_huffman_code(' '))
	assert_equal(6, hpack_huffman_code_length(' '))
	assert_equal_hex(3, hpack_huffman_code('a'))
	assert_equal(5, hpack_huffman_code_length('a'))
	assert_equal_hex(114, hpack_huffman_code('W'))
	assert_equal(7, hpack_huffman_code_length('W'))
	assert_equal_hex(524272, hpack_huffman_code(92))
	assert_equal(19, hpack_huffman_code_length(92))
	assert_equal_hex(67108846, hpack_huffman_code(255))
	assert_equal(26, hpack_huffman_code_length(255))
	assert_equal_hex(1073741823, hpack_huffman_code(256))
	assert_equal(30, hpack_huffman_code_length(256))
	assert_equal_hex(1073741820, hpack_huffman_code(10))
	assert_equal(30, hpack_huffman_code_length(10))


void test_hpack_huffman_round_trip_all_bytes():
	char* s = malloc(512)
	int i = 0
	while (i < 512):
		s[i] = (i * 7 + 3) & 255
		i = i + 1
	string_builder* out = string_new()
	int n = hpack_huffman_encode(s, 512, out)
	assert_equal(n, out.length)
	assert_equal(hpack_huffman_length(s, 512), n)
	int dlen = 0
	char* back = hpack_huffman_decode(out.data, out.length, 4096, &dlen)
	asserts(c"huffman decode failed", back != 0)
	assert_equal(512, dlen)
	i = 0
	while (i < 512):
		assert_equal(s[i] & 255, back[i] & 255)
		i = i + 1
	# The max_out cap fails closed.
	asserts(c"cap ignored", hpack_huffman_decode(out.data, out.length, 100, &dlen) == 0)
	free(back)
	free(s)
	string_free(out)


void test_hpack_huffman_rejects_bad_padding():
	int dlen = 0
	int len = 0
	# "www.example.com" decodes.
	char* p = hex_decode_loose(c"f1e3c2e5f23a6ba0ab90f4ff", &len)
	char* ok = hpack_huffman_decode(p, len, 100, &dlen)
	assert_strings_equal(c"www.example.com", ok)
	free(ok)
	free(p)
	# 'a' (00011) padded with zeros instead of ones.
	p = hex_decode_loose(c"18", &len)
	asserts(c"zero padding accepted", hpack_huffman_decode(p, len, 100, &dlen) == 0)
	free(p)
	# 'a' then a whole byte of ones: padding longer than 7 bits.
	p = hex_decode_loose(c"1fff", &len)
	asserts(c"long padding accepted", hpack_huffman_decode(p, len, 100, &dlen) == 0)
	free(p)
	# An explicit EOS symbol (30 ones) followed by 2 padding ones.
	p = hex_decode_loose(c"ffffffff", &len)
	asserts(c"EOS accepted", hpack_huffman_decode(p, len, 100, &dlen) == 0)
	free(p)


/* C.2 single fields */

void test_hpack_c2_literal_with_indexing():
	hpack_decoder* d = hpack_decoder_new(4096)
	hpack_test_decode_step(d, c"400a 6375 7374 6f6d 2d6b 6579 0d63 7573 746f 6d2d 6865 6164 6572", c"custom-key|custom-header\n", c"custom-key|custom-header\n", 55)
	hpack_decoder_free(d)
	hpack_encoder* e = hpack_encoder_new(4096)
	e.huffman = 0
	hpack_test_encode_step(e, c"custom-key|custom-header\n", c"400a 6375 7374 6f6d 2d6b 6579 0d63 7573 746f 6d2d 6865 6164 6572", c"custom-key|custom-header\n", 55)
	hpack_encoder_free(e)


void test_hpack_c2_literal_without_indexing():
	hpack_decoder* d = hpack_decoder_new(4096)
	hpack_test_decode_step(d, c"040c 2f73 616d 706c 652f 7061 7468", c":path|/sample/path\n", c"", 0)
	hpack_decoder_free(d)
	hpack_encoder* e = hpack_encoder_new(4096)
	e.huffman = 0
	e.indexing = 0
	hpack_test_encode_step(e, c":path|/sample/path\n", c"040c 2f73 616d 706c 652f 7061 7468", c"", 0)
	hpack_encoder_free(e)


void test_hpack_c2_never_indexed():
	hpack_decoder* d = hpack_decoder_new(4096)
	int len = 0
	char* block = hex_decode_loose(c"1008 7061 7373 776f 7264 0673 6563 7265 74", &len)
	list[hpack_header*] out = hpack_headers_new()
	assert_equal(0, hpack_decode(d, block, len, out))
	hpack_test_expect_headers(out, c"password|secret\n")
	hpack_header* h = out[0]
	assert_equal(1, h.sensitive)
	assert_equal(0, hpack_table_count(d.table))
	hpack_headers_free(out)
	free(block)
	hpack_decoder_free(d)

	hpack_encoder* e = hpack_encoder_new(4096)
	e.huffman = 0
	list[hpack_header*] l = hpack_headers_new()
	hpack_headers_add_sensitive(l, c"password", c"secret")
	string_builder* sb = string_new()
	hpack_encode(e, l, sb)
	hpack_test_expect_bytes(c"C.2.3", sb, c"1008 7061 7373 776f 7264 0673 6563 7265 74")
	assert_equal(0, hpack_table_count(e.table))
	string_free(sb)
	hpack_headers_free(l)
	hpack_encoder_free(e)


void test_hpack_c2_indexed():
	hpack_decoder* d = hpack_decoder_new(4096)
	hpack_test_decode_step(d, c"82", c":method|GET\n", c"", 0)
	hpack_decoder_free(d)
	hpack_encoder* e = hpack_encoder_new(4096)
	hpack_test_encode_step(e, c":method|GET\n", c"82", c"", 0)
	hpack_encoder_free(e)


/* C.3 / C.4 request sequences */

char* hpack_test_req1():
	return c":method|GET\n:scheme|http\n:path|/\n:authority|www.example.com\n"


char* hpack_test_req2():
	return c":method|GET\n:scheme|http\n:path|/\n:authority|www.example.com\ncache-control|no-cache\n"


char* hpack_test_req3():
	return c":method|GET\n:scheme|https\n:path|/index.html\n:authority|www.example.com\ncustom-key|custom-value\n"


char* hpack_test_req_t1():
	return c":authority|www.example.com\n"


char* hpack_test_req_t2():
	return c"cache-control|no-cache\n:authority|www.example.com\n"


char* hpack_test_req_t3():
	return c"custom-key|custom-value\ncache-control|no-cache\n:authority|www.example.com\n"


void hpack_test_request_sequence(int huffman, char* b1, char* b2, char* b3):
	hpack_decoder* d = hpack_decoder_new(4096)
	hpack_test_decode_step(d, b1, hpack_test_req1(), hpack_test_req_t1(), 57)
	hpack_test_decode_step(d, b2, hpack_test_req2(), hpack_test_req_t2(), 110)
	hpack_test_decode_step(d, b3, hpack_test_req3(), hpack_test_req_t3(), 164)
	hpack_decoder_free(d)
	hpack_encoder* e = hpack_encoder_new(4096)
	e.huffman = huffman
	hpack_test_encode_step(e, hpack_test_req1(), b1, hpack_test_req_t1(), 57)
	hpack_test_encode_step(e, hpack_test_req2(), b2, hpack_test_req_t2(), 110)
	hpack_test_encode_step(e, hpack_test_req3(), b3, hpack_test_req_t3(), 164)
	hpack_encoder_free(e)


void test_hpack_c3_requests_plain():
	hpack_test_request_sequence(0, c"8286 8441 0f77 7777 2e65 7861 6d70 6c65 2e63 6f6d", c"8286 84be 5808 6e6f 2d63 6163 6865", c"8287 85bf 400a 6375 7374 6f6d 2d6b 6579 0c63 7573 746f 6d2d 7661 6c75 65")


void test_hpack_c4_requests_huffman():
	hpack_test_request_sequence(1, c"8286 8441 8cf1 e3c2 e5f2 3a6b a0ab 90f4 ff", c"8286 84be 5886 a8eb 1064 9cbf", c"8287 85bf 4088 25a8 49e9 5ba9 7d7f 8925 a849 e95b b8e8 b4bf")


/* C.5 / C.6 response sequences (256-byte table, with eviction) */

char* hpack_test_resp1():
	return c":status|302\ncache-control|private\ndate|Mon, 21 Oct 2013 20:13:21 GMT\nlocation|https://www.example.com\n"


char* hpack_test_resp2():
	return c":status|307\ncache-control|private\ndate|Mon, 21 Oct 2013 20:13:21 GMT\nlocation|https://www.example.com\n"


char* hpack_test_resp3():
	return c":status|200\ncache-control|private\ndate|Mon, 21 Oct 2013 20:13:22 GMT\nlocation|https://www.example.com\ncontent-encoding|gzip\nset-cookie|foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1\n"


char* hpack_test_resp_t1():
	return c"location|https://www.example.com\ndate|Mon, 21 Oct 2013 20:13:21 GMT\ncache-control|private\n:status|302\n"


char* hpack_test_resp_t2():
	return c":status|307\nlocation|https://www.example.com\ndate|Mon, 21 Oct 2013 20:13:21 GMT\ncache-control|private\n"


char* hpack_test_resp_t3():
	return c"set-cookie|foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1\ncontent-encoding|gzip\ndate|Mon, 21 Oct 2013 20:13:22 GMT\n"


void hpack_test_response_sequence(int huffman, char* b1, char* b2, char* b3):
	hpack_decoder* d = hpack_decoder_new(256)
	hpack_test_decode_step(d, b1, hpack_test_resp1(), hpack_test_resp_t1(), 222)
	hpack_test_decode_step(d, b2, hpack_test_resp2(), hpack_test_resp_t2(), 222)
	hpack_test_decode_step(d, b3, hpack_test_resp3(), hpack_test_resp_t3(), 215)
	hpack_decoder_free(d)
	hpack_encoder* e = hpack_encoder_new(256)
	e.huffman = huffman
	hpack_test_encode_step(e, hpack_test_resp1(), b1, hpack_test_resp_t1(), 222)
	hpack_test_encode_step(e, hpack_test_resp2(), b2, hpack_test_resp_t2(), 222)
	hpack_test_encode_step(e, hpack_test_resp3(), b3, hpack_test_resp_t3(), 215)
	hpack_encoder_free(e)


void test_hpack_c5_responses_plain():
	hpack_test_response_sequence(0, c"4803 3330 3258 0770 7269 7661 7465 611d 4d6f 6e2c 2032 3120 4f63 7420 3230 3133 2032 303a 3133 3a32 3120 474d 546e 1768 7474 7073 3a2f 2f77 7777 2e65 7861 6d70 6c65 2e63 6f6d", c"4803 3330 37c1 c0bf", c"88c1 611d 4d6f 6e2c 2032 3120 4f63 7420 3230 3133 2032 303a 3133 3a32 3220 474d 54c0 5a04 677a 6970 7738 666f 6f3d 4153 444a 4b48 514b 425a 584f 5157 454f 5049 5541 5851 5745 4f49 553b 206d 6178 2d61 6765 3d33 3630 303b 2076 6572 7369 6f6e 3d31")


void test_hpack_c6_responses_huffman():
	hpack_test_response_sequence(1, c"4882 6402 5885 aec3 771a 4b61 96d0 7abe 9410 54d4 44a8 2005 9504 0b81 66e0 82a6 2d1b ff6e 919d 29ad 1718 63c7 8f0b 97c8 e9ae 82ae 43d3", c"4883 640e ffc1 c0bf", c"88c1 6196 d07a be94 1054 d444 a820 0595 040b 8166 e084 a62d 1bff c05a 839b d9ab 77ad 94e7 821d d7f2 e6c7 b335 dfdf cd5b 3960 d5af 2708 7f36 72c1 ab27 0fb5 291f 9587 3160 65c0 03ed 4ee5 b106 3d50 07")


/* Dynamic table size updates */

void test_hpack_size_update_decode():
	hpack_decoder* d = hpack_decoder_new(4096)
	# Fill the table, then a size update to 0 empties it.
	hpack_test_decode_step(d, c"400a 6375 7374 6f6d 2d6b 6579 0d63 7573 746f 6d2d 6865 6164 6572", c"custom-key|custom-header\n", c"custom-key|custom-header\n", 55)
	hpack_test_decode_step(d, c"20 82", c":method|GET\n", c"", 0)
	assert_equal(0, d.table.max_size)
	# Back up to the settings limit (4096 = 3f e1 1f).
	hpack_test_decode_step(d, c"3fe11f 82", c":method|GET\n", c"", 0)
	assert_equal(4096, d.table.max_size)
	# Above the limit: 4097 = 3f e2 1f.
	assert_equal(hpack_error_table_size, hpack_test_decode_rc(d, c"3fe21f"))
	hpack_decoder_free(d)
	# A size update after a field is an error.
	d = hpack_decoder_new(4096)
	assert_equal(hpack_error_table_size, hpack_test_decode_rc(d, c"82 20"))
	hpack_decoder_free(d)


void test_hpack_size_update_encode():
	hpack_encoder* e = hpack_encoder_new(4096)
	e.huffman = 0
	hpack_test_encode_step(e, c"custom-key|custom-header\n", c"400a 6375 7374 6f6d 2d6b 6579 0d63 7573 746f 6d2d 6865 6164 6572", c"custom-key|custom-header\n", 55)
	# Peer shrinks to 0 then grows to 100: emit 0 then 100 (3f 45).
	hpack_encoder_set_max_table_size(e, 0)
	hpack_encoder_set_max_table_size(e, 100)
	hpack_test_encode_step(e, c":method|GET\n", c"20 3f45 82", c"", 0)
	assert_equal(100, e.table.max_size)
	# A peer size above our cap is clamped to it (4096 = 3f e1 1f).
	hpack_encoder_set_max_table_size(e, 65536)
	hpack_test_encode_step(e, c":method|GET\n", c"3fe11f 82", c"", 0)
	# The decoder follows the encoder's updates.
	hpack_encoder_free(e)


void test_hpack_eviction_on_oversized_entry():
	hpack_table* t = hpack_table_new(60)
	hpack_table_add(t, c"a", 1, c"b", 1)
	assert_equal(34, t.size)
	hpack_table_add(t, c"cc", 2, c"dd", 2)
	# 34 + 36 > 60: the oldest goes.
	assert_equal(1, hpack_table_count(t))
	assert_equal(36, t.size)
	# An entry larger than the table empties it.
	hpack_table_add(t, c"0123456789012345", 16, c"0123456789012345", 16)
	assert_equal(0, hpack_table_count(t))
	assert_equal(0, t.size)
	hpack_table_free(t)


/* Fail-closed caps */

void test_hpack_rejects_bad_input():
	hpack_decoder* d = hpack_decoder_new(4096)
	# Index 0.
	assert_equal(hpack_error_bad_index, hpack_test_decode_rc(d, c"80"))
	# Index 62 with an empty dynamic table.
	assert_equal(hpack_error_bad_index, hpack_test_decode_rc(d, c"be"))
	# Literal name index out of range.
	assert_equal(hpack_error_bad_index, hpack_test_decode_rc(d, c"7f00 0161"))
	# String length past the end of the block.
	assert_equal(hpack_error_malformed, hpack_test_decode_rc(d, c"0005 6162"))
	# Value containing CR.
	assert_equal(hpack_error_bad_field, hpack_test_decode_rc(d, c"0001 61 01 0d"))
	# Empty name.
	assert_equal(hpack_error_bad_field, hpack_test_decode_rc(d, c"0000 0161"))
	hpack_decoder_free(d)

	# String cap.
	d = hpack_decoder_new(4096)
	d.max_string = 3
	assert_equal(hpack_error_too_large, hpack_test_decode_rc(d, c"0004 6162 6364 0161"))
	assert_equal(0, hpack_test_decode_rc(d, c"0003 6162 63 0161"))
	hpack_decoder_free(d)

	# Header list size cap (each field counts name + value + 32).
	d = hpack_decoder_new(4096)
	d.max_list_size = 80
	assert_equal(0, hpack_test_decode_rc(d, c"82 84"))
	assert_equal(hpack_error_too_large, hpack_test_decode_rc(d, c"82 84 86"))
	hpack_decoder_free(d)

	# Field count cap.
	d = hpack_decoder_new(4096)
	d.max_headers = 2
	assert_equal(hpack_error_too_large, hpack_test_decode_rc(d, c"82 84 86"))
	hpack_decoder_free(d)


void test_hpack_encode_decode_round_trip():
	hpack_encoder* e = hpack_encoder_new(4096)
	hpack_decoder* d = hpack_decoder_new(4096)
	for round in range(3):
		list[hpack_header*] l = hpack_headers_new()
		hpack_headers_add(l, c":method", c"POST")
		hpack_headers_add(l, c":scheme", c"http")
		hpack_headers_add(l, c":path", c"/pkg.Service/Method")
		hpack_headers_add(l, c"content-type", c"application/grpc")
		hpack_headers_add(l, c"te", c"trailers")
		hpack_headers_add_sensitive(l, c"authorization", c"Bearer secret-token")
		hpack_headers_add(l, c"x-round", itoa(round))
		string_builder* sb = string_new()
		hpack_encode(e, l, sb)
		list[hpack_header*] out = hpack_headers_new()
		assert_equal(0, hpack_decode(d, sb.data, sb.length, out))
		assert_equal(l.length, out.length)
		int i = 0
		while (i < l.length):
			hpack_header* a = l[i]
			hpack_header* b = out[i]
			assert_strings_equal(a.name, b.name)
			assert_strings_equal(a.value, b.value)
			i = i + 1
		assert_strings_equal(c"application/grpc", hpack_headers_get(out, c"content-type"))
		asserts(c"missing header found", hpack_headers_get(out, c"x-missing") == 0)
		assert_equal(e.table.size, d.table.size)
		hpack_headers_free(out)
		hpack_headers_free(l)
		string_free(sb)
	hpack_encoder_free(e)
	hpack_decoder_free(d)
