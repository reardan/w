# wbuild: x64
# Tests for libs/standard/web/grpc.w (issue #436). Request and response
# messages are real proto3 messages encoded with
# libs/extras/protobuf/message.w (grpc.w itself is serializer-agnostic):
#   message HelloRequest { string name = 1; int32 count = 2; }
#   message HelloReply   { string message = 1; int32 count = 2; }
# The end-to-end test forks a W gRPC server (grpc_server_serve_conn) on
# a loopback port and drives it with the W client over one HTTP/2
# connection: a unary call with metadata, an error status sent after
# response headers, a trailers-only error, an unknown method, deadline
# propagation, a client-side deadline expiry followed by a successful
# call on the same connection, and a non-gRPC request. A scripted
# raw-frame server covers client-side mapping of a non-200 HTTP status,
# a missing grpc-status, and a refused stream.
import lib.testing
import lib.net
import lib.time
import lib.container
import structures.string
import libs.extras.protobuf.message
import libs.standard.web.hpack
import libs.standard.web.http2
import libs.standard.web.grpc
import libs.standard.web.testing
import lib.mem


/* Protobuf message types */

struct gt_hello:
	pb_bytes text
	int32 count


pb_field_desc[2] gt_hello_fields
pb_message_desc gt_hello_desc


void gt_desc_init():
	gt_hello m
	gt_hello_fields[0].number = 1
	gt_hello_fields[0].kind = PB_KIND_STRING
	gt_hello_fields[0].offset = cast(int, &m.text) - cast(int, &m)
	gt_hello_fields[0].aux = 0
	gt_hello_fields[1].number = 2
	gt_hello_fields[1].kind = PB_KIND_INT32()
	gt_hello_fields[1].offset = cast(int, &m.count) - cast(int, &m)
	gt_hello_fields[1].aux = 0
	gt_hello_desc.field_count = 2
	gt_hello_desc.fields = gt_hello_fields
	gt_hello_desc.struct_size = 2 * __word_size__ + 4


char* gt_encode(char* text, int count, int* out_len):
	gt_hello m
	m.text.data = text
	m.text.length = strlen(text)
	m.count = count
	return pb_encode(&gt_hello_desc, cast(char*, &m), out_len)


# Decodes into a zeroed gt_hello; asserts success.
gt_hello* gt_decode(char* data, int len):
	char* buf = malloc(gt_hello_desc.struct_size)
	mem_fill(buf, 0, gt_hello_desc.struct_size)
	assert_equal(0, pb_decode_into(&gt_hello_desc, data, len, buf))
	return cast(gt_hello*, buf)


/* Server handlers */

void gt_say_hello(grpc_call* call, void* user_data):
	gt_hello* req = gt_decode(call.request, call.request_len)
	string_builder* sb = string_new()
	string_append(sb, c"Hello, ")
	string_append_bytes(sb, req.text.data, req.text.length)
	int len = 0
	char* out = gt_encode(sb.data, req.count + 1, &len)
	grpc_call_reply(call, out, len)
	grpc_call_add_header(call, c"x-handler", c"hello")
	grpc_call_add_trailer(call, c"x-trailer", c"t")
	char* echo = grpc_call_metadata(call, c"x-client")
	if (echo != 0):
		grpc_call_add_trailer(call, c"x-client-echo", echo)
	free(out)
	string_free(sb)
	free(req.text.data)
	free(req)


void gt_fail(grpc_call* call, void* user_data):
	call.headers_first = 1
	grpc_call_fail(call, grpc_status_not_found, c"no such user: caf\xc3\xa9 100%")


void gt_deny(grpc_call* call, void* user_data):
	grpc_call_fail(call, grpc_status_permission_denied, c"denied")


# Replies with the timeout the server parsed from grpc-timeout.
void gt_deadline(grpc_call* call, void* user_data):
	int len = 0
	char* out = gt_encode(c"deadline", call.timeout_ms, &len)
	grpc_call_reply(call, out, len)
	free(out)


void gt_slow(grpc_call* call, void* user_data):
	sleep_ms(800)
	int len = 0
	char* out = gt_encode(c"late", 0, &len)
	grpc_call_reply(call, out, len)
	free(out)


/* Fixture plumbing */

void gt_server_child(int listener):
	gt_desc_init()
	int fd = socket_accept_connection(listener)
	if (fd < 0):
		exit(70)
	grpc_server* srv = grpc_server_new()
	grpc_server_register(srv, c"/test.Greeter/SayHello", gt_say_hello, 0)
	grpc_server_register(srv, c"/test.Greeter/Fail", gt_fail, 0)
	grpc_server_register(srv, c"/test.Greeter/Deny", gt_deny, 0)
	grpc_server_register(srv, c"/test.Greeter/Deadline", gt_deadline, 0)
	grpc_server_register(srv, c"/test.Greeter/Slow", gt_slow, 0)
	int err = grpc_server_serve_conn(srv, fd)
	grpc_server_free(srv)
	exit(err)


grpc_result* gt_call_hello(grpc_channel* ch, char* name, int count):
	int len = 0
	char* req = gt_encode(name, count, &len)
	list[hpack_header*] md = hpack_headers_new()
	hpack_headers_add(md, c"X-Client", c"grpc_test")
	grpc_result* r = grpc_unary_call(ch, c"/test.Greeter/SayHello", req, len, md, 0)
	hpack_headers_free(md)
	free(req)
	return r


/* Wire-free checks */

void test_grpc_status_names_and_mapping():
	assert_strings_equal(c"OK", grpc_status_name(grpc_status_ok))
	assert_strings_equal(c"DEADLINE_EXCEEDED", grpc_status_name(4))
	assert_strings_equal(c"UNAUTHENTICATED", grpc_status_name(grpc_status_unauthenticated))
	assert_equal(16, grpc_status_unauthenticated)
	assert_equal(grpc_status_unimplemented, grpc_status_from_http(404))
	assert_equal(grpc_status_unavailable, grpc_status_from_http(503))
	assert_equal(grpc_status_unauthenticated, grpc_status_from_http(401))
	assert_equal(grpc_status_unknown, grpc_status_from_http(415))
	assert_equal(grpc_status_unavailable, grpc_status_from_h2_error(h2_error_refused_stream))
	assert_equal(grpc_status_cancelled, grpc_status_from_h2_error(h2_error_cancel))
	assert_equal(grpc_status_resource_exhausted, grpc_status_from_h2_error(h2_error_enhance_your_calm))
	assert_equal(grpc_status_internal, grpc_status_from_h2_error(h2_error_protocol))
	assert_equal(5, grpc_parse_status(c"5"))
	assert_equal(16, grpc_parse_status(c"16"))
	assert_equal(grpc_status_unknown, grpc_parse_status(c"17"))
	assert_equal(grpc_status_unknown, grpc_parse_status(c"x"))


void test_grpc_percent_encoding():
	char* e = grpc_percent_encode(c"no such user: caf\xc3\xa9 100%\x0a")
	assert_strings_equal(c"no such user: caf%C3%A9 100%25%0A", e)
	char* d = grpc_percent_decode(e)
	assert_strings_equal(c"no such user: caf\xc3\xa9 100%\x0a", d)
	free(e)
	free(d)
	# Malformed sequences pass through literally.
	d = grpc_percent_decode(c"50%zz off %4")
	assert_strings_equal(c"50%zz off %4", d)
	free(d)
	d = grpc_percent_decode(c"%e2%9c%93 ok")
	assert_strings_equal(c"\xe2\x9c\x93 ok", d)
	free(d)


void test_grpc_timeout_header():
	char* t = grpc_timeout_format(1500)
	assert_strings_equal(c"1500m", t)
	free(t)
	t = grpc_timeout_format(100000000)
	assert_strings_equal(c"100000S", t)
	free(t)
	int ms = 0
	assert_equal(1, grpc_timeout_parse(c"1500m", &ms))
	assert_equal(1500, ms)
	assert_equal(1, grpc_timeout_parse(c"2S", &ms))
	assert_equal(2000, ms)
	assert_equal(1, grpc_timeout_parse(c"3M", &ms))
	assert_equal(180000, ms)
	assert_equal(1, grpc_timeout_parse(c"1H", &ms))
	assert_equal(3600000, ms)
	assert_equal(1, grpc_timeout_parse(c"1u", &ms))
	assert_equal(1, ms)
	assert_equal(1, grpc_timeout_parse(c"2500000n", &ms))
	assert_equal(3, ms)
	assert_equal(1, grpc_timeout_parse(c"99999999H", &ms))
	assert_equal(2147483647, ms)
	assert_equal(0, grpc_timeout_parse(c"123456789m", &ms))
	assert_equal(0, grpc_timeout_parse(c"10", &ms))
	assert_equal(0, grpc_timeout_parse(c"m", &ms))
	assert_equal(0, grpc_timeout_parse(c"10x", &ms))
	assert_equal(0, grpc_timeout_parse(c"10mm", &ms))


void test_grpc_message_framing():
	string_builder* sb = string_new()
	grpc_frame_message(sb, c"\x08\x96\x01", 3)
	assert_equal(8, sb.length)
	assert_equal(0, sb.data[0])
	assert_equal(3, sb.data[4])
	char* msg = 0
	int len = 0
	assert_equal(grpc_status_ok, grpc_unframe_message(sb.data, sb.length, 100, &msg, &len))
	assert_equal(3, len)
	assert_equal(150 - 256, msg[1])
	free(msg)
	# Too large for the cap.
	assert_equal(grpc_status_resource_exhausted, grpc_unframe_message(sb.data, sb.length, 2, &msg, &len))
	# Truncated, and trailing bytes (a second message).
	assert_equal(grpc_status_internal, grpc_unframe_message(sb.data, 7, 100, &msg, &len))
	string_append_bytes(sb, c"\x00\x00\x00\x00\x00", 5)
	assert_equal(grpc_status_internal, grpc_unframe_message(sb.data, sb.length, 100, &msg, &len))
	# Compressed flag without negotiated compression.
	sb.data[0] = 1
	assert_equal(grpc_status_unimplemented, grpc_unframe_message(sb.data, 8, 100, &msg, &len))
	assert_equal(grpc_status_internal, grpc_unframe_message(sb.data, 3, 100, &msg, &len))
	string_free(sb)


void test_grpc_protobuf_round_trip():
	gt_desc_init()
	int len = 0
	char* out = gt_encode(c"testing", 150, &len)
	# field 1 "testing", field 2 = 150.
	assert_equal(12, len)
	gt_hello* back = gt_decode(out, len)
	assert_strings_equal(c"testing", back.text.data)
	assert_equal(150, back.count)
	free(back.text.data)
	free(back)
	free(out)


/* End to end */

void test_grpc_unary_end_to_end():
	gt_desc_init()
	int port = 0
	int listener = net_test_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		gt_server_child(listener)
	grpc_channel* ch = grpc_channel_open(c"127.0.0.1", port, 10000)
	asserts(c"channel open failed", ch != 0)

	# Unary success with metadata both ways.
	grpc_result* r = gt_call_hello(ch, c"W", 41)
	assert_equal(grpc_status_ok, r.status)
	assert_equal(200, r.http_status)
	gt_hello* reply = gt_decode(r.response, r.response_len)
	assert_strings_equal(c"Hello, W", reply.text.data)
	assert_equal(42, reply.count)
	free(reply.text.data)
	free(reply)
	assert_strings_equal(c"application/grpc", grpc_result_header(r, c"content-type"))
	assert_strings_equal(c"hello", grpc_result_header(r, c"x-handler"))
	assert_strings_equal(c"0", grpc_result_trailer(r, c"grpc-status"))
	assert_strings_equal(c"t", grpc_result_trailer(r, c"x-trailer"))
	assert_strings_equal(c"grpc_test", grpc_result_trailer(r, c"x-client-echo"))
	grpc_result_free(r)

	# Error status after response headers (headers + trailers frames).
	r = grpc_unary_call(ch, c"/test.Greeter/Fail", 0, 0, 0, 0)
	assert_equal(grpc_status_not_found, r.status)
	assert_strings_equal(c"no such user: caf\xc3\xa9 100%", r.message)
	asserts(c"expected separate trailers", r.trailers != 0)
	assert_strings_equal(c"no such user: caf%C3%A9 100%25", grpc_result_trailer(r, c"grpc-message"))
	asserts(c"no response on error", r.response == 0)
	grpc_result_free(r)

	# Trailers-only error.
	r = grpc_unary_call(ch, c"/test.Greeter/Deny", 0, 0, 0, 0)
	assert_equal(grpc_status_permission_denied, r.status)
	assert_strings_equal(c"denied", r.message)
	asserts(c"trailers-only expected", r.trailers == 0)
	assert_strings_equal(c"7", grpc_result_header(r, c"grpc-status"))
	grpc_result_free(r)

	# Unknown method: UNIMPLEMENTED, trailers-only.
	r = grpc_unary_call(ch, c"/test.Greeter/Nope", 0, 0, 0, 0)
	assert_equal(grpc_status_unimplemented, r.status)
	assert_strings_equal(c"unknown method /test.Greeter/Nope", r.message)
	grpc_result_free(r)

	# grpc-timeout reaches the server.
	r = grpc_unary_call(ch, c"/test.Greeter/Deadline", 0, 0, 0, 5000)
	assert_equal(grpc_status_ok, r.status)
	reply = gt_decode(r.response, r.response_len)
	assert_equal(5000, reply.count)
	free(reply.text.data)
	free(reply)
	grpc_result_free(r)

	# A deadline that expires: DEADLINE_EXCEEDED, connection reusable.
	int start = time_monotonic_ms()
	r = grpc_unary_call(ch, c"/test.Greeter/Slow", 0, 0, 0, 200)
	assert_equal(grpc_status_deadline_exceeded, r.status)
	asserts(c"deadline returned too late", time_monotonic_ms() - start < 700)
	grpc_result_free(r)
	r = gt_call_hello(ch, c"again", 1)
	assert_equal(grpc_status_ok, r.status)
	reply = gt_decode(r.response, r.response_len)
	assert_strings_equal(c"Hello, again", reply.text.data)
	free(reply.text.data)
	free(reply)
	grpc_result_free(r)

	# A non-gRPC request gets HTTP 415 from the gRPC server.
	list[hpack_header*] h = hpack_headers_new()
	hpack_headers_add(h, c"content-type", c"text/plain")
	h2_stream* s = h2_request(ch.conn, c"POST", c"http", ch.authority, c"/test.Greeter/SayHello", h, c"hi", 2)
	asserts(c"415 request failed", h2_stream_ok(s))
	assert_equal(415, h2_stream_status(s))
	h2_stream_free(ch.conn, s)
	hpack_headers_free(h)

	grpc_channel_close(ch)
	net_test_finish(pid, listener)


/* Scripted server: client-side status mapping */

# Reads until a HEADERS frame on the given stream (DATA and control
# frames are skipped).
void gt_raw_wait_headers(int fd, int stream):
	h2_frame f
	while (1):
		if (h2_raw_read_frame(fd, &f) == 0):
			exit(92)
		int done = (f.type == h2_frame_headers) && (f.stream_id == stream)
		free(f.payload)
		if (done != 0):
			return


void gt_raw_send_headers(int fd, hpack_encoder* e, int stream, list[hpack_header*] l, int flags):
	string_builder* sb = string_new()
	hpack_encode(e, l, sb)
	h2_raw_write_frame(fd, h2_frame_headers, flags | h2_flag_end_headers, stream, sb.data, sb.length)
	string_free(sb)


void test_grpc_client_status_mapping():
	int port = 0
	int listener = net_test_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		int fd = h2_test_raw_accept(listener, 0, 0)
		hpack_encoder* e = hpack_encoder_new(4096)
		# Stream 1: HTTP 503 -> UNAVAILABLE.
		gt_raw_wait_headers(fd, 1)
		list[hpack_header*] l = hpack_headers_new()
		hpack_headers_add(l, c":status", c"503")
		gt_raw_send_headers(fd, e, 1, l, h2_flag_end_stream)
		hpack_headers_free(l)
		# Stream 3: 200 + gRPC content-type but no grpc-status.
		gt_raw_wait_headers(fd, 3)
		l = hpack_headers_new()
		hpack_headers_add(l, c":status", c"200")
		hpack_headers_add(l, c"content-type", c"application/grpc")
		gt_raw_send_headers(fd, e, 3, l, h2_flag_end_stream)
		hpack_headers_free(l)
		# Stream 5: refused.
		gt_raw_wait_headers(fd, 5)
		h2_raw_write_frame(fd, h2_frame_rst_stream, 0, 5, c"\x00\x00\x00\x07", 4)
		# Stream 7: wrong content-type.
		gt_raw_wait_headers(fd, 7)
		l = hpack_headers_new()
		hpack_headers_add(l, c":status", c"200")
		hpack_headers_add(l, c"content-type", c"text/html")
		gt_raw_send_headers(fd, e, 7, l, h2_flag_end_stream)
		hpack_headers_free(l)
		char* scratch = malloc(256)
		while (read(fd, scratch, 256) > 0):
			scratch[0] = 0
		exit(0)
	grpc_channel* ch = grpc_channel_open(c"127.0.0.1", port, 10000)
	asserts(c"channel open failed", ch != 0)
	grpc_result* r = grpc_unary_call(ch, c"/x.Y/Z", c"", 0, 0, 0)
	assert_equal(grpc_status_unavailable, r.status)
	assert_equal(503, r.http_status)
	assert_strings_equal(c"HTTP status 503", r.message)
	grpc_result_free(r)
	r = grpc_unary_call(ch, c"/x.Y/Z", c"", 0, 0, 0)
	assert_equal(grpc_status_internal, r.status)
	assert_strings_equal(c"missing grpc-status", r.message)
	grpc_result_free(r)
	r = grpc_unary_call(ch, c"/x.Y/Z", c"", 0, 0, 0)
	assert_equal(grpc_status_unavailable, r.status)
	grpc_result_free(r)
	r = grpc_unary_call(ch, c"/x.Y/Z", c"", 0, 0, 0)
	assert_equal(grpc_status_unknown, r.status)
	grpc_result_free(r)
	grpc_channel_close(ch)
	net_test_finish(pid, listener)
