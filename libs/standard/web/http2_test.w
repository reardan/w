# wbuild: x64
# Tests for libs/standard/web/http2.w (RFC 9113, issue #436). Network
# tests use forked loopback fixtures (the http_client_test.w pattern):
# the parent binds an ephemeral listener, forks, and the child plays the
# server. Two kinds of server child:
#   - the W HTTP/2 server itself (h2_server_new + h2_server_next_request),
#     exercised by the W client: GET/POST, concurrent streams awaited out
#     of order, trailers, a 200 KB body each way (flow control and
#     WINDOW_UPDATE both directions), PING;
#   - scripted raw-frame servers built on h2_raw_read_frame /
#     h2_raw_write_frame, for edge cases a well-behaved peer never
#     produces: CONTINUATION-split headers, padding, a tiny
#     INITIAL_WINDOW_SIZE, receive-window violations, server PING,
#     GOAWAY with streams above last-stream-id, PUSH_PROMISE, oversized
#     frames, RST_STREAM, 1xx informational headers, content-length
#     mismatch.
# A raw client against the W server covers server-side protocol errors.
# Every child reports through its exit status (0 = everything it
# checked was right), which the parent asserts.
import lib.testing
import lib.net
import lib.container
import structures.string
import libs.standard.web.hpack
import libs.standard.web.http2
import libs.standard.web.testing
import lib.bytes
import lib.mem


/* Fixture plumbing */

h2_conn* h2t_connect(int port):
	h2_conn* c = h2_connect(c"127.0.0.1", port, 10000)
	asserts(c"h2_connect failed", c != 0)
	return c


/* Raw-frame server helpers */

# Next frame of the given type, skipping SETTINGS / WINDOW_UPDATE /
# PING ACK traffic unless that is the type asked for. Exits the child
# with code on EOF.
void h2t_expect(int fd, int type, h2_frame* f, int code):
	while (1):
		if (h2_raw_read_frame(fd, f) == 0): exit(code)
		if (f.type == type): return
		int skip = (f.type == h2_frame_settings) || (f.type == h2_frame_window_update) || ((f.type == h2_frame_ping) && ((f.flags & 1) != 0))
		if (skip == 0): exit(code)
		free(f.payload)


# spec: "name|value\n" per field.
list[hpack_header*] h2t_fields(char* spec):
	list[hpack_header*] l = hpack_headers_new()
	int pos = 0
	while (spec[pos] != 0):
		int ns = pos
		while (spec[pos] != '|'): pos = pos + 1
		int ne = pos
		pos = pos + 1
		int vs = pos
		while (spec[pos] != 10): pos = pos + 1
		l.push(hpack_header_new(spec + ns, ne - ns, spec + vs, pos - vs))
		pos = pos + 1
	return l


void h2t_send_headers(int fd, hpack_encoder* e, int stream, char* spec, int flags):
	list[hpack_header*] l = h2t_fields(spec)
	string_builder* sb = string_new()
	hpack_encode(e, l, sb)
	h2_raw_write_frame(fd, h2_frame_headers, flags | h2_flag_end_headers, stream, sb.data, sb.length)
	string_free(sb)
	hpack_headers_free(l)


void h2t_send_data(int fd, int stream, char* text, int flags):
	h2_raw_write_frame(fd, h2_frame_data, flags, stream, text, strlen(text))


char* h2t_setting(int id, int value):
	char* p = malloc(6)
	p[0] = 0
	p[1] = id
	store_be32(p + 2, value)
	return p


/* Wire-free checks */

void test_h2_raw_frame_round_trip():
	int* fds = cast(int*, malloc(2 * __word_size__))
	assert_equal(0, socket_pair(fds))
	assert_equal(0, h2_raw_write_frame(fds[0], h2_frame_ping, 1, 0, c"abcdefgh", 8))
	assert_equal(0, h2_raw_write_frame(fds[0], h2_frame_window_update, 0, 2147483647, c"\x7f\xff\xff\xff", 4))
	h2_frame f
	assert_equal(1, h2_raw_read_frame(fds[1], &f))
	assert_equal(h2_frame_ping, f.type)
	assert_equal(1, f.flags)
	assert_equal(0, f.stream_id)
	assert_equal(8, f.length)
	assert_equal('h', f.payload[7])
	free(f.payload)
	assert_equal(1, h2_raw_read_frame(fds[1], &f))
	assert_equal(2147483647, f.stream_id)
	assert_equal(2147483647, h2_get_u31(f.payload))
	free(f.payload)
	close(fds[0])
	close(fds[1])


void test_h2_server_rejects_bad_preface():
	int* fds = cast(int*, malloc(2 * __word_size__))
	assert_equal(0, socket_pair(fds))
	char* junk = c"GET / HTTP/1.1\x0d\x0aHost: x\x0d\x0a\x0d\x0a"
	h2_fd_write_all(fds[0], junk, strlen(junk))
	asserts(c"bad preface accepted", h2_server_new(fds[1]) == 0)
	close(fds[0])


void test_h2_error_strings():
	assert_strings_equal(c"PROTOCOL_ERROR", h2_error_string(h2_error_protocol))
	assert_strings_equal(c"FLOW_CONTROL_ERROR", h2_error_string(3))
	assert_strings_equal(c"HTTP_1_1_REQUIRED", h2_error_string(13))
	assert_strings_equal(c"UNKNOWN_ERROR", h2_error_string(99))


/* The W server against the W client */

void h2t_w_server_child(int listener):
	int fd = socket_accept_connection(listener)
	if (fd < 0): exit(80)
	h2_conn* c = h2_server_new(fd)
	if (c == 0): exit(81)
	while (1):
		h2_stream* s = h2_server_next_request(c)
		if (s == 0): break
		char* method = h2_stream_header(s, c":method")
		char* path = h2_stream_header(s, c":path")
		list[hpack_header*] extra = hpack_headers_new()
		hpack_headers_add(extra, c"X-Server", c"w")
		if (strcmp(path, c"/trailers") == 0):
			h2_respond_headers(c, s, 200, extra, 0)
			h2_send_data(c, s, c"partial", 7, 0)
			list[hpack_header*] t = hpack_headers_new()
			hpack_headers_add(t, c"x-checksum", c"42")
			h2_send_trailers(c, s, t)
			hpack_headers_free(t)
		else if (strcmp(path, c"/big") == 0):
			h2_respond(c, s, 200, extra, h2_stream_body(s), h2_stream_body_len(s))
		else if (strcmp(path, c"/missing") == 0): h2_respond(c, s, 404, extra, 0, 0)
		else:
			string_builder* sb = string_new()
			string_append(sb, method)
			string_append(sb, c" ")
			string_append(sb, path)
			string_append(sb, c" ")
			string_append_bytes(sb, h2_stream_body(s), h2_stream_body_len(s))
			h2_respond(c, s, 200, extra, sb.data, sb.length)
			string_free(sb)
		hpack_headers_free(extra)
		h2_stream_free(c, s)
	int err = c.error
	h2_close(c)
	exit(err)


void test_h2_w_client_and_server():
	int port = 0
	int listener = net_test_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0): h2t_w_server_child(listener)
	char* auth = net_test_authority(c"127.0.0.1", port)
	h2_conn* c = h2t_connect(port)

	# Plain GET.
	h2_stream* s = h2_request(c, c"GET", c"http", auth, c"/hello", 0, 0, 0)
	asserts(c"GET failed", h2_stream_ok(s))
	assert_equal(200, h2_stream_status(s))
	assert_strings_equal(c"GET /hello ", h2_stream_body(s))
	assert_strings_equal(c"w", h2_stream_header(s, c"x-server"))
	h2_stream_free(c, s)

	# POST with a body, and a header-only 404.
	s = h2_request(c, c"POST", c"http", auth, c"/echo", 0, c"payload", 7)
	asserts(c"POST failed", h2_stream_ok(s))
	assert_strings_equal(c"POST /echo payload", h2_stream_body(s))
	h2_stream_free(c, s)
	s = h2_request(c, c"GET", c"http", auth, c"/missing", 0, 0, 0)
	asserts(c"404 failed", h2_stream_ok(s))
	assert_equal(404, h2_stream_status(s))
	assert_equal(0, h2_stream_body_len(s))
	h2_stream_free(c, s)

	# Three concurrent streams, awaited in reverse order.
	h2_stream* a = h2_request_start(c, c"POST", c"http", auth, c"/a", 0, 0)
	h2_stream* b = h2_request_start(c, c"POST", c"http", auth, c"/b", 0, 0)
	h2_stream* d = h2_request_start(c, c"GET", c"http", auth, c"/d", 0, 1)
	assert_equal(0, h2_send_data(c, b, c"bee", 3, 1))
	assert_equal(0, h2_send_data(c, a, c"ay", 2, 1))
	assert_equal(0, h2_await_end(c, d))
	assert_equal(0, h2_await_end(c, b))
	assert_equal(0, h2_await_end(c, a))
	assert_strings_equal(c"GET /d ", h2_stream_body(d))
	assert_strings_equal(c"POST /b bee", h2_stream_body(b))
	assert_strings_equal(c"POST /a ay", h2_stream_body(a))
	assert_equal(7, a.id)
	h2_stream_free(c, a)
	h2_stream_free(c, b)
	h2_stream_free(c, d)

	# Trailers.
	s = h2_request(c, c"GET", c"http", auth, c"/trailers", 0, 0, 0)
	asserts(c"trailers failed", h2_stream_ok(s))
	assert_strings_equal(c"partial", h2_stream_body(s))
	assert_strings_equal(c"42", h2_stream_trailer(s, c"x-checksum"))
	h2_stream_free(c, s)

	# 200 KB each way: several windows' worth in both directions.
	int big = 204800
	char* body = malloc(big)
	int i = 0
	while (i < big):
		body[i] = 'a' + (i % 26)
		i = i + 1
	s = h2_request(c, c"PUT", c"http", auth, c"/big", 0, body, big)
	asserts(c"big failed", h2_stream_ok(s))
	assert_equal(big, h2_stream_body_len(s))
	char* got = h2_stream_body(s)
	i = 0
	while (i < big):
		assert_equal(body[i], got[i])
		i = i + 7
	assert_equal(body[big - 1], got[big - 1])
	h2_stream_free(c, s)
	free(body)

	assert_equal(0, h2_ping(c))
	assert_equal(0, c.error)
	h2_close(c)
	net_test_finish(pid, listener)


/* Scripted servers */

void test_h2_continuation_and_padding():
	int port = 0
	int listener = net_test_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		int fd = h2_test_raw_accept(listener, 0, 0)
		h2_frame f
		h2t_expect(fd, h2_frame_headers, &f, 10)
		hpack_encoder* e = hpack_encoder_new(4096)
		list[hpack_header*] l = h2t_fields(c":status|200\nx-long|0123456789012345678901234567890123456789\nx-other|value\n")
		string_builder* sb = string_new()
		hpack_encode(e, l, sb)
		# HEADERS (5 bytes), CONTINUATION (10 bytes), CONTINUATION (rest).
		h2_raw_write_frame(fd, h2_frame_headers, 0, 1, sb.data, 5)
		h2_raw_write_frame(fd, h2_frame_continuation, 0, 1, sb.data + 5, 10)
		h2_raw_write_frame(fd, h2_frame_continuation, h2_flag_end_headers, 1, sb.data + 15, sb.length - 15)
		# Padded DATA: pad length 4, "hello", 4 zero bytes.
		h2_raw_write_frame(fd, h2_frame_data, h2_flag_padded, 1, c"\x04hello\x00\x00\x00\x00", 10)
		h2_raw_write_frame(fd, h2_frame_data, h2_flag_end_stream, 1, c" world", 6)
		net_test_drain(fd)
		exit(0)
	h2_conn* c = h2t_connect(port)
	h2_stream* s = h2_request(c, c"GET", c"http", c"x", c"/", 0, 0, 0)
	asserts(c"request failed", h2_stream_ok(s))
	assert_strings_equal(c"0123456789012345678901234567890123456789", h2_stream_header(s, c"x-long"))
	assert_strings_equal(c"value", h2_stream_header(s, c"x-other"))
	assert_strings_equal(c"hello world", h2_stream_body(s))
	h2_stream_free(c, s)
	h2_close(c)
	net_test_finish(pid, listener)


# The server advertises INITIAL_WINDOW_SIZE = 10: the client may send
# only 10 bytes until the server's WINDOW_UPDATE.
void test_h2_send_flow_control():
	int port = 0
	int listener = net_test_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		int fd = h2_test_raw_accept(listener, h2t_setting(h2_settings_initial_window_size, 10), 6)
		h2_frame f
		h2t_expect(fd, h2_frame_headers, &f, 10)
		h2t_expect(fd, h2_frame_data, &f, 11)
		if ((f.length != 10) || ((f.flags & 1) != 0)): exit(12)
		# The client must now be blocked: allow 20 more bytes.
		h2_raw_write_frame(fd, h2_frame_window_update, 0, 1, c"\x00\x00\x00\x14", 4)
		h2t_expect(fd, h2_frame_data, &f, 13)
		if ((f.length != 15) || ((f.flags & 1) == 0)): exit(14)
		hpack_encoder* e = hpack_encoder_new(4096)
		h2t_send_headers(fd, e, 1, c":status|200\n", 0)
		h2t_send_data(fd, 1, c"got 25", h2_flag_end_stream)
		net_test_drain(fd)
		exit(0)
	h2_conn* c = h2t_connect(port)
	# Until the server's SETTINGS arrive the RFC default window applies.
	assert_equal(0, h2_await_settings(c))
	assert_equal(10, c.peer_initial_window)
	h2_stream* s = h2_request(c, c"POST", c"http", c"x", c"/upload", 0, c"0123456789abcdefghijklmno", 25)
	asserts(c"request failed", h2_stream_ok(s))
	assert_strings_equal(c"got 25", h2_stream_body(s))
	assert_equal(5, s.send_window)
	h2_stream_free(c, s)
	h2_close(c)
	net_test_finish(pid, listener)


# The client advertises a 100-byte stream window; a 150-byte DATA frame
# is a stream FLOW_CONTROL_ERROR (RST_STREAM), the connection survives.
void test_h2_receive_window_violation():
	int port = 0
	int listener = net_test_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		int fd = h2_test_raw_accept(listener, 0, 0)
		h2_frame f
		h2t_expect(fd, h2_frame_headers, &f, 10)
		hpack_encoder* e = hpack_encoder_new(4096)
		h2t_send_headers(fd, e, 1, c":status|200\n", 0)
		char* big = malloc(150)
		mem_fill(big, 'z', 150)
		h2_raw_write_frame(fd, h2_frame_data, 0, 1, big, 150)
		h2t_expect(fd, h2_frame_rst_stream, &f, 11)
		if ((f.stream_id != 1) || (h2_get_u31(f.payload) != h2_error_flow_control)): exit(12)
		# Stream 3 still works on the same connection.
		h2t_expect(fd, h2_frame_headers, &f, 13)
		if (f.stream_id != 3): exit(14)
		h2t_send_headers(fd, e, 3, c":status|204\n", h2_flag_end_stream)
		net_test_drain(fd)
		exit(0)
	h2_conn* c = h2_conn_new(socket_tcp_ipv4(), 0)
	asserts(c"connect", socket_connect_ipv4(c.fd, ip4_from_string(c"127.0.0.1"), port) >= 0)
	c.local_initial_window = 100
	h2_client_start(c)
	h2_stream* s = h2_request(c, c"GET", c"http", c"x", c"/", 0, 0, 0)
	assert_equal(0, h2_stream_ok(s))
	assert_equal(h2_error_flow_control, s.reset_code)
	assert_equal(0, s.reset_by_peer)
	h2_stream_free(c, s)
	s = h2_request(c, c"GET", c"http", c"x", c"/again", 0, 0, 0)
	asserts(c"second request failed", h2_stream_ok(s))
	assert_equal(204, h2_stream_status(s))
	h2_stream_free(c, s)
	h2_close(c)
	net_test_finish(pid, listener)


# Server PING mid-exchange: the client must ACK it with the same bytes.
void test_h2_server_ping_is_acked():
	int port = 0
	int listener = net_test_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		int fd = h2_test_raw_accept(listener, 0, 0)
		h2_frame f
		h2t_expect(fd, h2_frame_headers, &f, 10)
		h2_raw_write_frame(fd, h2_frame_ping, 0, 0, c"pingpong", 8)
		while (1):
			h2t_expect(fd, h2_frame_ping, &f, 11)
			if ((f.flags & 1) != 0): break
		if ((f.length != 8) || (f.payload[0] != 'p') || (f.payload[4] != 'p') || (f.payload[7] != 'g')):
			exit(12)
		hpack_encoder* e = hpack_encoder_new(4096)
		h2t_send_headers(fd, e, 1, c":status|200\n", h2_flag_end_stream)
		net_test_drain(fd)
		exit(0)
	h2_conn* c = h2t_connect(port)
	h2_stream* s = h2_request(c, c"GET", c"http", c"x", c"/", 0, 0, 0)
	asserts(c"request failed", h2_stream_ok(s))
	h2_stream_free(c, s)
	h2_close(c)
	net_test_finish(pid, listener)


# GOAWAY(last = 1) with streams 1 and 3 open: 1 completes, 3 is refused
# (retryable), and no new stream can start.
void test_h2_goaway_refuses_later_streams():
	int port = 0
	int listener = net_test_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		int fd = h2_test_raw_accept(listener, 0, 0)
		h2_frame f
		h2t_expect(fd, h2_frame_headers, &f, 10)
		h2t_expect(fd, h2_frame_headers, &f, 11)
		if (f.stream_id != 3): exit(12)
		h2_raw_write_frame(fd, h2_frame_goaway, 0, 0, c"\x00\x00\x00\x01\x00\x00\x00\x00bye", 11)
		hpack_encoder* e = hpack_encoder_new(4096)
		h2t_send_headers(fd, e, 1, c":status|200\n", 0)
		h2t_send_data(fd, 1, c"done", h2_flag_end_stream)
		net_test_drain(fd)
		exit(0)
	h2_conn* c = h2t_connect(port)
	h2_stream* one = h2_request_start(c, c"GET", c"http", c"x", c"/1", 0, 1)
	h2_stream* three = h2_request_start(c, c"GET", c"http", c"x", c"/3", 0, 1)
	assert_equal(0, h2_await_end(c, one))
	assert_strings_equal(c"done", h2_stream_body(one))
	assert_equal(1, c.goaway_received)
	assert_equal(1, c.goaway_last_stream)
	assert_strings_equal(c"bye", c.goaway_debug)
	assert_equal(1, three.refused)
	assert_equal(-1, h2_await_end(c, three))
	asserts(c"stream after GOAWAY", h2_request_start(c, c"GET", c"http", c"x", c"/5", 0, 1) == 0)
	h2_stream_free(c, one)
	h2_stream_free(c, three)
	h2_close(c)
	net_test_finish(pid, listener)


# Scripted server that sends one bad frame after the request HEADERS and
# expects GOAWAY with want_code back.
void h2t_expect_goaway_child(int listener, int kind, int want_code):
	int fd = h2_test_raw_accept(listener, 0, 0)
	h2_frame f
	h2t_expect(fd, h2_frame_headers, &f, 10)
	if (kind == 1):
		# PUSH_PROMISE while push is disabled.
		h2_raw_write_frame(fd, h2_frame_push_promise, h2_flag_end_headers, 1, c"\x00\x00\x00\x02\x82", 5)
	else if (kind == 2):
		# A frame above the 16384-byte SETTINGS_MAX_FRAME_SIZE.
		char* big = malloc(16385)
		mem_fill(big, 0, 16385)
		h2_raw_write_frame(fd, h2_frame_data, 0, 1, big, 16385)
	else if (kind == 3):
		# Response HEADERS without END_HEADERS, then a DATA frame.
		h2_raw_write_frame(fd, h2_frame_headers, 0, 1, c"\x88", 1)
		h2_raw_write_frame(fd, h2_frame_data, 0, 1, c"x", 1)
	else if (kind == 4):
		# A header block that is not valid HPACK (index 0).
		h2_raw_write_frame(fd, h2_frame_headers, h2_flag_end_headers, 1, c"\x80", 1)
	else if (kind == 5):
		# WINDOW_UPDATE on the connection with a zero increment.
		h2_raw_write_frame(fd, h2_frame_window_update, 0, 0, c"\x00\x00\x00\x00", 4)
	h2t_expect(fd, h2_frame_goaway, &f, 20)
	if (h2_get_u31(f.payload + 4) != want_code): exit(21)
	exit(0)


void h2t_run_goaway_case(int kind, int want_code):
	int port = 0
	int listener = net_test_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0): h2t_expect_goaway_child(listener, kind, want_code)
	h2_conn* c = h2t_connect(port)
	h2_stream* s = h2_request(c, c"GET", c"http", c"x", c"/", 0, 0, 0)
	assert_equal(0, h2_stream_ok(s))
	assert_equal(1, c.dead)
	assert_equal(want_code, c.error)
	h2_stream_free(c, s)
	h2_close(c)
	net_test_finish(pid, listener)


void test_h2_push_promise_rejected():
	h2t_run_goaway_case(1, h2_error_protocol)


void test_h2_oversized_frame_rejected():
	h2t_run_goaway_case(2, h2_error_frame_size)


void test_h2_interrupted_continuation_rejected():
	h2t_run_goaway_case(3, h2_error_protocol)


void test_h2_bad_hpack_is_compression_error():
	h2t_run_goaway_case(4, h2_error_compression)


void test_h2_zero_window_update_rejected():
	h2t_run_goaway_case(5, h2_error_protocol)


void test_h2_rst_stream_from_server():
	int port = 0
	int listener = net_test_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		int fd = h2_test_raw_accept(listener, 0, 0)
		h2_frame f
		h2t_expect(fd, h2_frame_headers, &f, 10)
		h2_raw_write_frame(fd, h2_frame_rst_stream, 0, 1, c"\x00\x00\x00\x08", 4)
		net_test_drain(fd)
		exit(0)
	h2_conn* c = h2t_connect(port)
	h2_stream* s = h2_request(c, c"GET", c"http", c"x", c"/", 0, 0, 0)
	assert_equal(0, h2_stream_ok(s))
	assert_equal(h2_error_cancel, s.reset_code)
	assert_equal(1, s.reset_by_peer)
	assert_equal(0, c.dead)
	h2_stream_free(c, s)
	h2_close(c)
	net_test_finish(pid, listener)


# 103 Early Hints before the final response, trailers after, and a
# content-length that does not match the DATA (stream PROTOCOL_ERROR).
void test_h2_informational_trailers_and_content_length():
	int port = 0
	int listener = net_test_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		int fd = h2_test_raw_accept(listener, 0, 0)
		h2_frame f
		hpack_encoder* e = hpack_encoder_new(4096)
		h2t_expect(fd, h2_frame_headers, &f, 10)
		h2t_send_headers(fd, e, 1, c":status|103\nlink|</style.css>\n", 0)
		h2t_send_headers(fd, e, 1, c":status|200\ncontent-length|5\n", 0)
		h2t_send_data(fd, 1, c"12345", 0)
		h2t_send_headers(fd, e, 1, c"grpc-status|0\n", h2_flag_end_stream)
		h2t_expect(fd, h2_frame_headers, &f, 11)
		h2t_send_headers(fd, e, 3, c":status|200\ncontent-length|10\n", 0)
		h2t_send_data(fd, 3, c"short", h2_flag_end_stream)
		h2t_expect(fd, h2_frame_rst_stream, &f, 12)
		if ((f.stream_id != 3) || (h2_get_u31(f.payload) != h2_error_protocol)): exit(13)
		net_test_drain(fd)
		exit(0)
	h2_conn* c = h2t_connect(port)
	h2_stream* s = h2_request(c, c"GET", c"http", c"x", c"/", 0, 0, 0)
	asserts(c"request failed", h2_stream_ok(s))
	assert_equal(200, h2_stream_status(s))
	asserts(c"1xx header leaked", h2_stream_header(s, c"link") == 0)
	assert_strings_equal(c"12345", h2_stream_body(s))
	assert_strings_equal(c"0", h2_stream_trailer(s, c"grpc-status"))
	h2_stream_free(c, s)
	s = h2_request(c, c"GET", c"http", c"x", c"/2", 0, 0, 0)
	assert_equal(0, h2_stream_ok(s))
	assert_equal(h2_error_protocol, s.reset_code)
	h2_stream_free(c, s)
	h2_close(c)
	net_test_finish(pid, listener)


/* Raw client against the W server */

# The W server must answer an even (server-initiated) stream id from
# the client with GOAWAY(PROTOCOL_ERROR).
void test_h2_server_rejects_even_stream():
	int port = 0
	int listener = net_test_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		int sfd = socket_accept_connection(listener)
		h2_conn* sc = h2_server_new(sfd)
		if (sc == 0): exit(30)
		h2_stream* none = h2_server_next_request(sc)
		if (none != 0): exit(31)
		if (sc.error != h2_error_protocol): exit(32)
		h2_close(sc)
		exit(0)
	int fd = socket_tcp_ipv4()
	asserts(c"connect", socket_connect_ipv4(fd, ip4_from_string(c"127.0.0.1"), port) >= 0)
	socket_set_recv_timeout(fd, 10000)
	h2_fd_write_all(fd, h2_preface(), 24)
	h2_raw_write_frame(fd, h2_frame_settings, 0, 0, 0, 0)
	hpack_encoder* e = hpack_encoder_new(4096)
	h2t_send_headers(fd, e, 2, c":method|GET\n:scheme|http\n:path|/\n:authority|x\n", h2_flag_end_stream)
	h2_frame f
	int found = 0
	while (h2_raw_read_frame(fd, &f) != 0):
		if (f.type == h2_frame_goaway):
			assert_equal(h2_error_protocol, h2_get_u31(f.payload + 4))
			found = 1
			break
		free(f.payload)
	assert_equal(1, found)
	close(fd)
	net_test_finish(pid, listener)


# A request missing :path is a stream error (RST_STREAM PROTOCOL_ERROR);
# the next valid request on the connection is served.
void test_h2_server_rejects_malformed_request():
	int port = 0
	int listener = net_test_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0): h2t_w_server_child(listener)
	int fd = socket_tcp_ipv4()
	asserts(c"connect", socket_connect_ipv4(fd, ip4_from_string(c"127.0.0.1"), port) >= 0)
	socket_set_recv_timeout(fd, 10000)
	h2_fd_write_all(fd, h2_preface(), 24)
	h2_raw_write_frame(fd, h2_frame_settings, 0, 0, 0, 0)
	hpack_encoder* e = hpack_encoder_new(4096)
	h2t_send_headers(fd, e, 1, c":method|GET\n:scheme|http\n:authority|x\n", h2_flag_end_stream)
	h2t_send_headers(fd, e, 3, c":method|GET\n:scheme|http\n:path|/ok\n:authority|x\n", h2_flag_end_stream)
	h2_frame f
	int saw_rst = 0
	int saw_ok = 0
	while ((saw_ok == 0) && (h2_raw_read_frame(fd, &f) != 0)):
		if ((f.type == h2_frame_rst_stream) && (f.stream_id == 1)):
			assert_equal(h2_error_protocol, h2_get_u31(f.payload))
			saw_rst = 1
		if ((f.type == h2_frame_data) && (f.stream_id == 3) && ((f.flags & 1) != 0)): saw_ok = 1
		free(f.payload)
	assert_equal(1, saw_rst)
	assert_equal(1, saw_ok)
	h2_raw_write_frame(fd, h2_frame_goaway, 0, 0, c"\x00\x00\x00\x00\x00\x00\x00\x00", 8)
	close(fd)
	net_test_finish(pid, listener)
