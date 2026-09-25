# wbuild: x64
# Streaming RPCs and message compression for libs/standard/web/grpc.w
# (issue #436 follow-up). Messages are plain byte strings here (the
# protobuf pairing is covered by grpc_test.w). gzip/deflate come from
# libs/extras/compress through the libs/standard/web/codec.w registry
# (compress_codecs_register).
#
# The end-to-end test forks a W gRPC server on a loopback port and
# drives it over one HTTP/2 connection: server streaming (small, and
# 1.2 MB to exercise flow control), client streaming (1.5 MB), two
# client-streaming calls interleaved on one connection, bidi ping-pong,
# an error status after streamed messages, cancellation mid-stream
# (the server handler observes it), a deadline expiring mid-stream
# (the connection stays usable), compressed unary and streaming calls
# with gzip and deflate, and oversize decompression both ways
# (RESOURCE_EXHAUSTED). A second forked server lacks the client's
# coding: UNIMPLEMENTED plus grpc-accept-encoding. A scripted raw-frame
# server covers the client's handling of an unsupported response
# coding, a compressed flag without grpc-encoding, and corrupt
# compressed data.
import lib.testing
import lib.net
import lib.time
import lib.container
import structures.string
import libs.standard.web.hpack
import libs.standard.web.http2
import libs.standard.web.codec
import libs.standard.web.grpc
import libs.extras.compress.codecs
import libs.standard.web.testing


/* Helpers */

char* gs_msg(char* prefix, int n):
	string_builder* sb = string_new()
	string_append(sb, prefix)
	string_append_int(sb, n)
	char* data = sb.data
	free(sb)
	return data


char* gs_fill(int size, int ch):
	char* buf = malloc(size + 1)
	for i in range(size): buf[i] = ch
	buf[size] = 0
	return buf


# Parses "a,b,c" into three ints.
void gs_parse3(char* s, int* a, int* b, int* c):
	*a = atoi(s)
	while (*s != ','): s = s + 1
	s = s + 1
	*b = atoi(s)
	while (*s != ','): s = s + 1
	s = s + 1
	*c = atoi(s)


/* Server handlers (run in the forked child) */

int gs_stops


# Unary echo; reports how many request messages arrived compressed.
void gs_unary(grpc_call* call, void* user_data):
	string_builder* sb = string_new()
	string_append(sb, c"echo:")
	string_append_bytes(sb, call.request, call.request_len)
	grpc_call_reply(call, sb.data, sb.length)
	string_free(sb)
	char* n = itoa(call.recv_compressed)
	grpc_call_add_trailer(call, c"x-req-compressed", n)
	free(n)


# Server streaming: request "N SIZE" -> N messages of SIZE bytes, the
# k-th filled with 'a' + k % 26.
void gs_count(grpc_call* call, void* user_data):
	char* req = 0
	int len = 0
	if (grpc_call_recv(call, &req, &len) != 1): return
	int n = atoi(req)
	int i = 0
	while ((req[i] != ' ') && (req[i] != 0)): i = i + 1
	int size = atoi(req + i + 1)
	free(req)
	grpc_call_add_header(call, c"x-kind", c"server-streaming")
	for k in range(n):
		char* buf = gs_fill(size, 'a' + (k % 26))
		int rc = grpc_call_send(call, buf, size)
		free(buf)
		if (rc != 0): return
	grpc_call_add_trailer(call, c"x-sent", c"done")


# Client streaming: sums the leading number of every message; replies
# "sum,bytes,count".
void gs_sum(grpc_call* call, void* user_data):
	int sum = 0
	int bytes = 0
	int count = 0
	int rc = 0
	while (1):
		char* m = 0
		int len = 0
		rc = grpc_call_recv(call, &m, &len)
		if (rc != 1): break
		sum = sum + atoi(m)
		bytes = bytes + len
		count = count + 1
		free(m)
	if (rc < 0): return
	string_builder* sb = string_new()
	string_append_int(sb, sum)
	string_append(sb, c",")
	string_append_int(sb, bytes)
	string_append(sb, c",")
	string_append_int(sb, count)
	grpc_call_send(call, sb.data, sb.length)
	string_free(sb)


# Bidi: answers every message with "pong:<msg>" right away.
void gs_echo(grpc_call* call, void* user_data):
	int count = 0
	while (1):
		char* m = 0
		int len = 0
		if (grpc_call_recv(call, &m, &len) != 1): break
		string_builder* sb = string_new()
		string_append(sb, c"pong:")
		string_append_bytes(sb, m, len)
		free(m)
		int rc = grpc_call_send(call, sb.data, sb.length)
		string_free(sb)
		if (rc != 0): return
		count = count + 1
	char* n = itoa(count)
	grpc_call_add_trailer(call, c"x-count", n)
	free(n)


# Two messages, then an error status.
void gs_fail_mid(grpc_call* call, void* user_data):
	char* m = 0
	int len = 0
	if (grpc_call_recv(call, &m, &len) != 1): return
	free(m)
	grpc_call_send(call, c"one", 3)
	grpc_call_send(call, c"two", 3)
	grpc_call_fail(call, grpc_status_aborted, c"stopped")


# Ticks every 20 ms until the client goes away; counts the stops it saw
# (a cancel, or its own deadline).
void gs_ticker(grpc_call* call, void* user_data):
	char* m = 0
	int len = 0
	if (grpc_call_recv(call, &m, &len) != 1): return
	free(m)
	for i in range(500):
		char* t = gs_msg(c"tick ", i)
		int rc = grpc_call_send(call, t, strlen(t))
		free(t)
		if (rc != 0):
			if ((call.cancelled != 0) || (call.status == grpc_status_deadline_exceeded)):
				gs_stops = gs_stops + 1
			return
		sleep_ms(20)


void gs_stats(grpc_call* call, void* user_data):
	char* n = itoa(gs_stops)
	grpc_call_reply(call, n, strlen(n))
	free(n)


# 1 MiB of zeros: tiny once compressed, over the client's cap once not.
void gs_bomb(grpc_call* call, void* user_data):
	char* buf = gs_fill(1048576, 0)
	grpc_call_reply(call, buf, 1048576)
	free(buf)


/* Fixture plumbing */

void gs_server_child(int listener):
	int fd = socket_accept_connection(listener)
	if (fd < 0): exit(70)
	grpc_server* srv = grpc_server_new()
	srv.max_message = 262144
	grpc_server_register(srv, c"/t.S/Unary", gs_unary, 0)
	grpc_server_register_stream(srv, c"/t.S/Count", gs_count, 0)
	grpc_server_register_stream(srv, c"/t.S/Sum", gs_sum, 0)
	grpc_server_register_stream(srv, c"/t.S/Echo", gs_echo, 0)
	grpc_server_register_stream(srv, c"/t.S/FailMid", gs_fail_mid, 0)
	grpc_server_register_stream(srv, c"/t.S/Ticker", gs_ticker, 0)
	grpc_server_register(srv, c"/t.S/Stats", gs_stats, 0)
	grpc_server_register(srv, c"/t.S/Bomb", gs_bomb, 0)
	int err = grpc_server_serve_conn(srv, fd)
	grpc_server_free(srv)
	exit(err)


int gs_fork_server(int* out_port, int* out_listener):
	int listener = net_test_listen(out_port)
	*out_listener = listener
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0): gs_server_child(listener)
	return pid


# Server streaming "N SIZE"; asserts every message and the OK status.
void gs_check_count(grpc_channel* ch, int n, int size):
	grpc_client_stream* cs = grpc_stream_open(ch, c"/t.S/Count", 0, 0)
	char* req = gs_msg(c"", n)
	string_builder* sb = string_new()
	string_append(sb, req)
	string_append(sb, c" ")
	string_append_int(sb, size)
	assert_equal(0, grpc_stream_send(cs, sb.data, sb.length))
	string_free(sb)
	free(req)
	assert_equal(0, grpc_stream_close_send(cs))
	int k = 0
	while (1):
		char* m = 0
		int len = 0
		int rc = grpc_stream_recv(cs, &m, &len)
		if (rc != 1):
			assert_equal(0, rc)
			break
		assert_equal(size, len)
		assert_equal('a' + (k % 26), m[0])
		assert_equal('a' + (k % 26), m[len - 1])
		free(m)
		k = k + 1
	assert_equal(n, k)
	assert_strings_equal(c"server-streaming", grpc_stream_header(cs, c"x-kind"))
	grpc_result* r = grpc_stream_finish(cs)
	assert_equal(grpc_status_ok, r.status)
	if (n == 0):
		# Nothing was sent: a trailers-only response.
		asserts(c"trailers-only expected", r.trailers == 0)
		assert_strings_equal(c"done", grpc_result_header(r, c"x-sent"))
	else: assert_strings_equal(c"done", grpc_result_trailer(r, c"x-sent"))
	grpc_result_free(r)


# Client streaming: count messages of size bytes whose leading number is
# i; returns the finished result (reply in r.response).
grpc_result* gs_sum_call(grpc_channel* ch, int count, int size):
	grpc_client_stream* cs = grpc_stream_open(ch, c"/t.S/Sum", 0, 0)
	for i in range(count):
		char* buf = gs_fill(size, 'x')
		char* num = gs_msg(c"", i)
		int k = 0
		while (num[k] != 0):
			buf[k] = num[k]
			k = k + 1
		assert_equal(0, grpc_stream_send(cs, buf, size))
		free(num)
		free(buf)
	assert_equal(0, grpc_stream_close_send(cs))
	char* m = 0
	int len = 0
	assert_equal(1, grpc_stream_recv(cs, &m, &len))
	assert_equal(0, grpc_stream_recv(cs, &m, &len))
	grpc_result* r = grpc_stream_finish(cs)
	return r


void gs_check_sum_reply(grpc_client_stream* cs, int count, int size):
	char* m = 0
	int len = 0
	assert_equal(1, grpc_stream_recv(cs, &m, &len))
	int sum = 0
	int bytes = 0
	int n = 0
	gs_parse3(m, &sum, &bytes, &n)
	free(m)
	assert_equal(count * (count - 1) / 2, sum)
	assert_equal(count * size, bytes)
	assert_equal(count, n)
	assert_equal(0, grpc_stream_recv(cs, &m, &len))


int gs_stats_call(grpc_channel* ch):
	grpc_result* r = grpc_unary_call(ch, c"/t.S/Stats", c"", 0, 0, 0)
	assert_equal(grpc_status_ok, r.status)
	int n = atoi(r.response)
	grpc_result_free(r)
	return n


# Bidi ping-pong: rounds messages, each answered before the next.
void gs_ping_pong(grpc_channel* ch, int rounds, char* want_encoding):
	grpc_client_stream* cs = grpc_stream_open(ch, c"/t.S/Echo", 0, 0)
	for i in range(rounds):
		char* ping = gs_msg(c"ping ", i)
		assert_equal(0, grpc_stream_send(cs, ping, strlen(ping)))
		char* m = 0
		int len = 0
		assert_equal(1, grpc_stream_recv(cs, &m, &len))
		char* want = gs_msg(c"pong:ping ", i)
		assert_strings_equal(want, m)
		assert_equal(strlen(want), len)
		free(want)
		free(m)
		free(ping)
	if (want_encoding != 0):
		assert_strings_equal(want_encoding, grpc_stream_header(cs, c"grpc-encoding"))
	else: asserts(c"unexpected grpc-encoding", grpc_stream_header(cs, c"grpc-encoding") == 0)
	assert_equal(0, grpc_stream_close_send(cs))
	char* m = 0
	int len = 0
	assert_equal(0, grpc_stream_recv(cs, &m, &len))
	assert_equal(grpc_status_ok, grpc_stream_status(cs))
	grpc_result* r = grpc_stream_finish(cs)
	assert_equal(grpc_status_ok, r.status)
	char* n = itoa(rounds)
	assert_strings_equal(n, grpc_result_trailer(r, c"x-count"))
	free(n)
	grpc_result_free(r)


/* Fake coding for the mismatch test (registered in the client only) */

int gs_fake_encode(char* in, int len, char** out, int* out_len):
	*out = mem_dup(in, len)
	*out_len = len
	return codec_ok


int gs_fake_decode(char* in, int len, int max, char** out, int* out_len):
	*out = mem_dup(in, len)
	*out_len = len
	return codec_ok


/* Wire-free checks */

void test_codec_registry():
	compress_codecs_register()
	compress_codecs_register()
	char* l = codec_accept_list()
	assert_strings_equal(c"gzip,deflate", l)
	free(l)
	assert_equal(1, codec_supported(c"GZIP"))
	assert_equal(1, codec_supported(c"identity"))
	assert_equal(1, codec_supported(0))
	assert_equal(0, codec_supported(c"br"))
	assert_equal(1, codec_list_contains(c"identity, deflate;q=0.5 ,gzip", c"gzip"))
	assert_equal(1, codec_list_contains(c"identity, deflate;q=0.5 ,gzip", c"deflate"))
	assert_equal(0, codec_list_contains(c"gzipx,xgzip", c"gzip"))
	assert_equal(0, codec_list_contains(0, c"gzip"))
	assert_equal(1, codec_list_contains(0, c"identity"))
	char* out = 0
	int out_len = 0
	char* zeros = gs_fill(10000, 0)
	assert_equal(codec_ok, codec_compress(c"gzip", zeros, 10000, &out, &out_len))
	asserts(c"gzip did not compress", out_len < 1000)
	char* back = 0
	int back_len = 0
	assert_equal(codec_err_too_large, codec_decompress(c"gzip", out, out_len, 9999, &back, &back_len))
	asserts(c"no output on failure", back == 0)
	assert_equal(codec_ok, codec_decompress(c"gzip", out, out_len, 10000, &back, &back_len))
	assert_equal(10000, back_len)
	free(back)
	out[out_len - 5] = out[out_len - 5] ^ 1
	assert_equal(codec_err_corrupt, codec_decompress(c"gzip", out, out_len, 0, &back, &back_len))
	free(out)
	assert_equal(codec_ok, codec_compress(c"deflate", zeros, 10000, &out, &out_len))
	assert_equal(codec_ok, codec_decompress(c"Deflate", out, out_len, 0, &back, &back_len))
	assert_equal(10000, back_len)
	free(back)
	free(out)
	assert_equal(codec_err_unsupported, codec_compress(c"br", zeros, 10, &out, &out_len))
	free(zeros)


void test_grpc_take_message():
	compress_codecs_register()
	string_builder* sb = string_new()
	assert_equal(codec_ok, grpc_encode_message(sb, 0, c"plain", 5))
	char* big = gs_fill(5000, 'q')
	assert_equal(codec_ok, grpc_encode_message(sb, c"gzip", big, 5000))
	asserts(c"compressed flag", sb.data[10] == 1)
	# Feed the buffer a byte at a time: 0 until a whole message is in.
	string_builder* buf = string_new()
	char* m = 0
	int len = 0
	int compressed = 0
	int status = 0
	char* why = 0
	int got = 0
	int i = 0
	while (i < sb.length):
		string_append_char(buf, sb.data[i])
		int rc = grpc_take_message(buf, c"gzip", 10000, &m, &len, &compressed, &status, &why)
		asserts(c"take_message failed", rc >= 0)
		if (rc == 1):
			if (got == 0):
				assert_strings_equal(c"plain", m)
				assert_equal(0, compressed)
			else:
				assert_equal(5000, len)
				assert_equal('q', m[4999])
				assert_equal(1, compressed)
			free(m)
			got = got + 1
		i = i + 1
	assert_equal(2, got)
	assert_equal(0, buf.length)
	# Decompressed size over the cap.
	string_clear(buf)
	grpc_encode_message(buf, c"gzip", big, 5000)
	assert_equal(-1, grpc_take_message(buf, c"gzip", 4999, &m, &len, &compressed, &status, &why))
	assert_equal(grpc_status_resource_exhausted, status)
	# Compressed flag with no grpc-encoding, and corrupt data.
	assert_equal(-1, grpc_take_message(buf, 0, 10000, &m, &len, &compressed, &status, &why))
	assert_equal(grpc_status_internal, status)
	buf.data[6] = buf.data[6] ^ 255
	assert_equal(-1, grpc_take_message(buf, c"gzip", 10000, &m, &len, &compressed, &status, &why))
	assert_equal(grpc_status_internal, status)
	# Wire length over the cap fails before the body arrives.
	string_clear(buf)
	string_append_bytes(buf, c"\x00\x00\x01\x00\x00", 5)
	assert_equal(-1, grpc_take_message(buf, 0, 1000, &m, &len, &compressed, &status, &why))
	assert_equal(grpc_status_resource_exhausted, status)
	free(big)
	string_free(buf)
	string_free(sb)


/* End to end */

void test_grpc_streaming_end_to_end():
	compress_codecs_register()
	int port = 0
	int listener = 0
	int pid = gs_fork_server(&port, &listener)
	grpc_channel* ch = grpc_channel_open(c"127.0.0.1", port, 10000)
	asserts(c"channel open failed", ch != 0)

	# Server streaming, small then 1.2 MB (past every window).
	gs_check_count(ch, 5, 10)
	gs_check_count(ch, 40, 30000)
	gs_check_count(ch, 0, 1)

	# Client streaming, 1.5 MB.
	grpc_result* r = gs_sum_call(ch, 50, 30000)
	assert_equal(grpc_status_ok, r.status)
	grpc_result_free(r)

	# Two client-streaming calls interleaved on one connection.
	grpc_client_stream* a = grpc_stream_open(ch, c"/t.S/Sum", 0, 0)
	grpc_client_stream* b = grpc_stream_open(ch, c"/t.S/Sum", 0, 0)
	assert_equal(0, grpc_stream_send(b, c"10", 2))
	assert_equal(0, grpc_stream_send(a, c"1", 1))
	assert_equal(0, grpc_stream_send(b, c"20", 2))
	assert_equal(0, grpc_stream_send(a, c"2", 1))
	assert_equal(0, grpc_stream_close_send(a))
	char* m = 0
	int len = 0
	assert_equal(1, grpc_stream_recv(a, &m, &len))
	assert_strings_equal(c"3,2,2", m)
	free(m)
	assert_equal(0, grpc_stream_send(b, c"30", 2))
	assert_equal(0, grpc_stream_close_send(b))
	assert_equal(1, grpc_stream_recv(b, &m, &len))
	assert_strings_equal(c"60,6,3", m)
	free(m)
	r = grpc_stream_finish(b)
	assert_equal(grpc_status_ok, r.status)
	grpc_result_free(r)
	r = grpc_stream_finish(a)
	assert_equal(grpc_status_ok, r.status)
	grpc_result_free(r)

	# Bidi ping-pong.
	gs_ping_pong(ch, 5, 0)

	# An error status after two streamed messages.
	grpc_client_stream* cs = grpc_stream_open(ch, c"/t.S/FailMid", 0, 0)
	assert_equal(0, grpc_stream_send(cs, c"go", 2))
	assert_equal(1, grpc_stream_recv(cs, &m, &len))
	assert_strings_equal(c"one", m)
	free(m)
	assert_equal(1, grpc_stream_recv(cs, &m, &len))
	assert_strings_equal(c"two", m)
	free(m)
	assert_equal(-1, grpc_stream_recv(cs, &m, &len))
	r = grpc_stream_finish(cs)
	assert_equal(grpc_status_aborted, r.status)
	assert_strings_equal(c"stopped", r.message)
	grpc_result_free(r)

	# Cancellation mid-stream: the server's next send fails and the
	# handler counts it.
	cs = grpc_stream_open(ch, c"/t.S/Ticker", 0, 0)
	assert_equal(0, grpc_stream_send(cs, c"go", 2))
	for i in range(3):
		assert_equal(1, grpc_stream_recv(cs, &m, &len))
		free(m)
	grpc_stream_cancel(cs)
	assert_equal(grpc_status_cancelled, grpc_stream_status(cs))
	assert_equal(-1, grpc_stream_recv(cs, &m, &len))
	assert_equal(-1, grpc_stream_send(cs, c"x", 1))
	r = grpc_stream_finish(cs)
	assert_equal(grpc_status_cancelled, r.status)
	grpc_result_free(r)
	assert_equal(1, gs_stats_call(ch))

	# A deadline expiring mid-stream; the connection stays usable.
	int start = time_monotonic_ms()
	cs = grpc_stream_open(ch, c"/t.S/Ticker", 0, 300)
	assert_equal(0, grpc_stream_send(cs, c"go", 2))
	int ticks = 0
	while (grpc_stream_recv(cs, &m, &len) == 1):
		free(m)
		ticks = ticks + 1
	asserts(c"expected some ticks before the deadline", ticks >= 3)
	int elapsed = time_monotonic_ms() - start
	asserts(c"deadline returned too late", elapsed < 1500)
	r = grpc_stream_finish(cs)
	assert_equal(grpc_status_deadline_exceeded, r.status)
	grpc_result_free(r)
	assert_equal(2, gs_stats_call(ch))

	# Compressed unary (gzip): request flag set, response mirrored.
	assert_equal(0, grpc_channel_set_compression(ch, c"br"))
	assert_equal(1, grpc_channel_set_compression(ch, c"gzip"))
	char* body = gs_fill(20000, 'z')
	r = grpc_unary_call(ch, c"/t.S/Unary", body, 20000, 0, 0)
	assert_equal(grpc_status_ok, r.status)
	assert_equal(20005, r.response_len)
	assert_equal('z', r.response[20004])
	assert_strings_equal(c"gzip", grpc_result_header(r, c"grpc-encoding"))
	assert_strings_equal(c"gzip,deflate", grpc_result_header(r, c"grpc-accept-encoding"))
	assert_strings_equal(c"1", grpc_result_trailer(r, c"x-req-compressed"))
	grpc_result_free(r)
	free(body)

	# Compressed streaming: bidi with gzip, server streaming with deflate.
	gs_ping_pong(ch, 3, c"gzip")
	assert_equal(1, grpc_channel_set_compression(ch, c"deflate"))
	gs_check_count(ch, 10, 30000)
	r = gs_sum_call(ch, 20, 1000)
	assert_equal(grpc_status_ok, r.status)
	grpc_result_free(r)

	# Oversize decompression, request side: 1 MiB of zeros is ~1 KB on
	# the wire but over the server's 256 KiB cap.
	assert_equal(1, grpc_channel_set_compression(ch, c"gzip"))
	body = gs_fill(1048576, 0)
	r = grpc_unary_call(ch, c"/t.S/Unary", body, 1048576, 0, 0)
	assert_equal(grpc_status_resource_exhausted, r.status)
	assert_strings_equal(c"decompressed message larger than the limit", r.message)
	grpc_result_free(r)
	free(body)

	# Oversize decompression, response side (client cap 64 KiB).
	ch.max_message = 65536
	r = grpc_unary_call(ch, c"/t.S/Bomb", c"", 0, 0, 0)
	assert_equal(grpc_status_resource_exhausted, r.status)
	asserts(c"no response on error", r.response == 0)
	grpc_result_free(r)
	ch.max_message = grpc_default_max_message

	# Identity again: nothing compressed, connection still healthy.
	assert_equal(1, grpc_channel_set_compression(ch, c"identity"))
	r = grpc_unary_call(ch, c"/t.S/Unary", c"hi", 2, 0, 0)
	assert_equal(grpc_status_ok, r.status)
	assert_strings_equal(c"echo:hi", r.response)
	assert_strings_equal(c"0", grpc_result_trailer(r, c"x-req-compressed"))
	asserts(c"identity response", grpc_result_header(r, c"grpc-encoding") == 0)
	grpc_result_free(r)

	grpc_channel_close(ch)
	net_test_finish(pid, listener)


# The client compresses with a coding the server does not have.
void test_grpc_encoding_mismatch():
	compress_codecs_register()
	int port = 0
	int listener = 0
	int pid = gs_fork_server(&port, &listener)
	# Registered after the fork: only the client knows "x-test".
	codec_register(c"x-test", gs_fake_encode, gs_fake_decode)
	grpc_channel* ch = grpc_channel_open(c"127.0.0.1", port, 10000)
	asserts(c"channel open failed", ch != 0)
	assert_equal(1, grpc_channel_set_compression(ch, c"x-test"))
	grpc_result* r = grpc_unary_call(ch, c"/t.S/Unary", c"hi", 2, 0, 0)
	assert_equal(grpc_status_unimplemented, r.status)
	assert_strings_equal(c"grpc-encoding x-test is not supported", r.message)
	assert_strings_equal(c"gzip,deflate", grpc_result_header(r, c"grpc-accept-encoding"))
	grpc_result_free(r)
	# Same for a streaming call, even before the first message.
	grpc_client_stream* cs = grpc_stream_open(ch, c"/t.S/Echo", 0, 0)
	char* m = 0
	int len = 0
	assert_equal(-1, grpc_stream_recv(cs, &m, &len))
	r = grpc_stream_finish(cs)
	assert_equal(grpc_status_unimplemented, r.status)
	grpc_result_free(r)
	# The connection survives; identity works.
	assert_equal(1, grpc_channel_set_compression(ch, 0))
	r = grpc_unary_call(ch, c"/t.S/Unary", c"ok", 2, 0, 0)
	assert_equal(grpc_status_ok, r.status)
	assert_strings_equal(c"echo:ok", r.response)
	grpc_result_free(r)
	grpc_channel_close(ch)
	net_test_finish(pid, listener)


/* Scripted server: client-side coding errors */

void gs_raw_wait_headers(int fd, int stream):
	h2_frame f
	while (1):
		if (h2_raw_read_frame(fd, &f) == 0): exit(92)
		int done = (f.type == h2_frame_headers) && (f.stream_id == stream)
		free(f.payload)
		if (done != 0): return


void gs_raw_headers(int fd, hpack_encoder* e, int stream, char* encoding, int end):
	list[hpack_header*] l = hpack_headers_new()
	if (end == 0):
		hpack_headers_add(l, c":status", c"200")
		hpack_headers_add(l, c"content-type", c"application/grpc")
		if (encoding != 0): hpack_headers_add(l, c"grpc-encoding", encoding)
	else: hpack_headers_add(l, c"grpc-status", c"0")
	string_builder* sb = string_new()
	hpack_encode(e, l, sb)
	int flags = h2_flag_end_headers
	if (end != 0): flags = flags | h2_flag_end_stream
	h2_raw_write_frame(fd, h2_frame_headers, flags, stream, sb.data, sb.length)
	string_free(sb)
	hpack_headers_free(l)


# One response: headers (with grpc-encoding), one DATA frame holding a
# message with the compressed flag, OK trailers.
void gs_raw_response(int fd, hpack_encoder* e, int stream, char* encoding, char* payload, int len):
	gs_raw_wait_headers(fd, stream)
	gs_raw_headers(fd, e, stream, encoding, 0)
	string_builder* sb = string_new()
	grpc_frame_message_flag(sb, 1, payload, len)
	h2_raw_write_frame(fd, h2_frame_data, 0, stream, sb.data, sb.length)
	string_free(sb)
	gs_raw_headers(fd, e, stream, 0, 1)


void test_grpc_client_coding_errors():
	compress_codecs_register()
	int port = 0
	int listener = net_test_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		int fd = h2_test_raw_accept(listener, 0, 0)
		hpack_encoder* e = hpack_encoder_new(4096)
		gs_raw_response(fd, e, 1, c"x-bogus", c"abc", 3)
		gs_raw_response(fd, e, 3, 0, c"abc", 3)
		gs_raw_response(fd, e, 5, c"gzip", c"not gzip at all", 15)
		char* scratch = malloc(256)
		while (read(fd, scratch, 256) > 0): scratch[0] = 0
		exit(0)
	grpc_channel* ch = grpc_channel_open(c"127.0.0.1", port, 10000)
	asserts(c"channel open failed", ch != 0)
	grpc_result* r = grpc_unary_call(ch, c"/x.Y/Z", c"", 0, 0, 0)
	assert_equal(grpc_status_internal, r.status)
	assert_strings_equal(c"unsupported grpc-encoding in response", r.message)
	grpc_result_free(r)
	r = grpc_unary_call(ch, c"/x.Y/Z", c"", 0, 0, 0)
	assert_equal(grpc_status_internal, r.status)
	assert_strings_equal(c"compressed message without grpc-encoding", r.message)
	grpc_result_free(r)
	r = grpc_unary_call(ch, c"/x.Y/Z", c"", 0, 0, 0)
	assert_equal(grpc_status_internal, r.status)
	assert_strings_equal(c"corrupt compressed message", r.message)
	grpc_result_free(r)
	grpc_channel_close(ch)
	net_test_finish(pid, listener)
