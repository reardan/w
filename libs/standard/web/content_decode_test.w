# wbuild: x64
import lib.testing
import libs.standard.web.content_decode
import libs.extras.compress.codecs
import libs.standard.net.testing


void test_content_chunks_and_completion():
	compress_codecs_register()
	gzip_result* compressed = gzip_compress(c"hello hello hello", 17, DEFLATE_LEVEL_FAST())
	content_decoder* d = content_decoder_new(c"gzip", compressed.length, 17)
	for i in range(compressed.length):
		assert_equal(content_decode_more, content_decoder_feed(d, compressed.data + i, 1))
		assert_equal(0, d.output_length)
	assert_equal(content_decode_done, content_decoder_finish(d))
	assert_equal(17, d.output_length)
	assert_bytes_equal(c"hello hello hello", d.output, 17)
	assert_equal(content_decode_done, content_decoder_finish(d))
	assert_equal(content_decode_state_error, content_decoder_feed(d, c"x", 1))
	content_decoder_free(d)
	gzip_result_free(compressed)


void test_content_limits_and_errors():
	compress_codecs_register()
	gzip_result* compressed = gzip_compress(c"hello hello hello", 17, DEFLATE_LEVEL_FAST())
	content_decoder* d = content_decoder_new(c"gzip", compressed.length - 1, 17)
	assert_equal(content_decode_input_limit, content_decoder_feed(d, compressed.data, compressed.length))
	assert_equal(content_decode_input_limit, content_decoder_finish(d))
	content_decoder_free(d)
	d = content_decoder_new(c"gzip", compressed.length, 5)
	content_decoder_feed(d, compressed.data, compressed.length)
	assert_equal(content_decode_output_limit, content_decoder_finish(d))
	assert_equal(0, d.output_length)
	content_decoder_free(d)
	for i in range(compressed.length):
		d = content_decoder_new(c"gzip", compressed.length, 17)
		content_decoder_feed(d, compressed.data, i)
		assert_equal(content_decode_corrupt, content_decoder_finish(d))
		content_decoder_free(d)
	gzip_result_free(compressed)
	d = content_decoder_new(c"br", 100, 100)
	assert_equal(content_decode_unsupported, d.status)
	content_decoder_free(d)
	d = content_decoder_new(c"identity", 0, 100)
	assert_equal(content_decode_state_error, d.status)
	content_decoder_free(d)
	d = content_decoder_new(c"identity", 10, 3)
	assert_equal(content_decode_more, content_decoder_feed(d, c"abc", 3))
	assert_equal(content_decode_output_limit, content_decoder_feed(d, c"d", 1))
	content_decoder_free(d)


void test_content_deflate_and_identity_binary():
	compress_codecs_register()
	char* raw = c"a\x00b"
	zlib_result* z = zlib_compress(raw, 3, DEFLATE_LEVEL_FAST())
	content_decoder* d = content_decoder_new(c"deflate", z.length, 3)
	assert_equal(content_decode_more, content_decoder_feed(d, z.data, z.length))
	assert_equal(content_decode_done, content_decoder_finish(d))
	assert_equal(3, d.output_length)
	assert_bytes_equal(raw, d.output, 3)
	content_decoder_free(d)
	zlib_result_free(z)
	d = content_decoder_new(0, 3, 3)
	content_decoder_feed(d, raw, 3)
	assert_equal(content_decode_done, content_decoder_finish(d))
	assert_equal(3, d.output_length)
	assert_bytes_equal(raw, d.output, 3)
	content_decoder_free(d)


void test_content_http_integration():
	compress_codecs_register()
	gzip_result* compressed = gzip_compress(c"browser", 7, DEFLATE_LEVEL_FAST())
	int port = 0
	int listener = net_test_listen(&port)
	int pid = fork()
	asserts(c"fork", pid >= 0)
	if (pid == 0):
		int fd = socket_accept_connection(listener)
		net_test_read_head(fd)
		string_builder* head = string_from(c"HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: ")
		string_append_int(head, compressed.length)
		string_append(head, c"\r\n\r\n")
		net_test_send_text(fd, head.data)
		net_test_send_all(fd, compressed.data, compressed.length)
		string_free(head)
		close(fd)
		exit(0)
	char* url = net_test_url(c"http", port, c"/")
	http_req* req = http_req_new(c"GET", url)
	req.total_timeout_ms = 3000
	http_stream* stream = http_open(req)
	content_decoder* d = http_content_collect(stream, 1000, 1000)
	assert_equal(content_decode_done, d.status)
	assert_equal(7, d.output_length)
	assert_bytes_equal(c"browser", d.output, 7)
	content_decoder_free(d)
	http_stream_close(stream)
	http_req_free(req)
	free(url)
	gzip_result_free(compressed)
	net_test_finish(pid, listener)


void test_content_gzip_members_validate_before_exposing_output():
	compress_codecs_register()
	gzip_result* first = gzip_compress(c"abc", 3, DEFLATE_LEVEL_FAST())
	gzip_result* second = gzip_compress(c"\x00de", 3, DEFLATE_LEVEL_FAST())
	string_builder* joined = string_new()
	string_append_bytes(joined, first.data, first.length)
	string_append_bytes(joined, second.data, second.length)
	content_decoder* d = content_decoder_new(c"gzip", joined.length, 6)
	for i in range(joined.length):
		assert_equal(content_decode_more, content_decoder_feed(d, joined.data + i, 1))
	assert_equal(content_decode_done, content_decoder_finish(d))
	assert_equal(6, d.output_length)
	assert_bytes_equal(c"abc\x00de", d.output, 6)
	content_decoder_free(d)
	# EOF within the second member invalidates the entire result. EOF at
	# the first member boundary is itself a complete, valid gzip stream.
	for length in range(first.length + 1, joined.length):
		d = content_decoder_new(c"gzip", joined.length, 6)
		content_decoder_feed(d, joined.data, length)
		assert_equal(content_decode_corrupt, content_decoder_finish(d))
		assert_equal(0, d.output_length)
		assert1(d.output == 0)
		content_decoder_free(d)
	for cap in range(1, 6):
		d = content_decoder_new(c"gzip", joined.length, cap)
		content_decoder_feed(d, joined.data, joined.length)
		assert_equal(content_decode_output_limit, content_decoder_finish(d))
		assert1(d.output == 0)
		content_decoder_free(d)
	# A corrupt second member must not leave the first member visible.
	joined.data[joined.length - 8] = joined.data[joined.length - 8] ^ 1
	d = content_decoder_new(c"gzip", joined.length, 6)
	content_decoder_feed(d, joined.data, joined.length)
	assert_equal(content_decode_corrupt, content_decoder_finish(d))
	assert1(d.output == 0)
	content_decoder_free(d)
	joined.data[joined.length - 8] = joined.data[joined.length - 8] ^ 1
	# Arbitrary bytes, even zero padding, are not additional gzip members.
	string_append_char(joined, 0)
	d = content_decoder_new(c"gzip", joined.length, 6)
	content_decoder_feed(d, joined.data, joined.length)
	assert_equal(content_decode_corrupt, content_decoder_finish(d))
	assert1(d.output == 0)
	content_decoder_free(d)
	string_free(joined)
	gzip_result_free(first)
	gzip_result_free(second)


void test_content_deflate_rejects_trailing_input():
	compress_codecs_register()
	zlib_result* z = zlib_compress(c"abc", 3, DEFLATE_LEVEL_FAST())
	string_builder* joined = string_new()
	string_append_bytes(joined, z.data, z.length)
	string_append_bytes(joined, z.data, z.length)
	content_decoder* d = content_decoder_new(c"deflate", joined.length, 6)
	content_decoder_feed(d, joined.data, joined.length)
	assert_equal(content_decode_corrupt, content_decoder_finish(d))
	assert_equal(0, d.output_length)
	assert1(d.output == 0)
	content_decoder_free(d)
	d = content_decoder_new(c"deflate", joined.length, 6)
	content_decoder_feed(d, joined.data, z.length + 1)
	assert_equal(content_decode_corrupt, content_decoder_finish(d))
	assert1(d.output == 0)
	content_decoder_free(d)
	string_free(joined)
	zlib_result_free(z)
