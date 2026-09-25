# wbuild: x64
# gRPC over TLS for libs/standard/web/grpc.w: the W client
# (grpc_channel_open_tls) against the W server (grpc_server_serve_conn_tls)
# over a forked loopback, with the pure-W TLS 1.3 stack
# (libs/standard/net/tls.w) negotiating ALPN "h2" and the checked-in
# synthetic P-256 fixture cert (libs/standard/net/tls_fixtures/), as
# libs/standard/web/http2_tls_test.w does. The fixture's SAN is
# test.w.example, so the client passes that as the server name and skips
# chain verification (CertificateVerify and Finished are still checked).
#
# Covers: a unary call (the server sees :scheme https and the
# server_name authority, and its connection runs over TLS), server
# streaming (small, and 1.2 MB across many TLS records and flow-control
# windows), a bidi ping-pong compressed with gzip
# (compress_codecs_register), a cancel mid-stream that the server
# handler observes, h2_conn_has_pending seeing TLS-buffered plaintext,
# and a client that does not offer h2 (grpc_server_serve_conn_tls
# returns PROTOCOL_ERROR).
import lib.testing
import lib.net
import lib.time
import lib.container
import structures.string
import libs.standard.net.tls
import libs.standard.web.hpack
import libs.standard.web.http2
import libs.standard.web.codec
import libs.standard.web.grpc
import libs.extras.compress.codecs
import libs.standard.web.testing


/* Helpers */

char* gt_msg(char* prefix, int n):
	string_builder* sb = string_new()
	string_append(sb, prefix)
	string_append_int(sb, n)
	char* data = sb.data
	free(sb)
	return data


char* gt_fill(int size, int ch):
	char* buf = malloc(size + 1)
	for i in range(size):
		buf[i] = ch
	buf[size] = 0
	return buf


/* Server handlers (run in the forked child) */

int gt_stops


# Unary: "<scheme> <authority> <tls> echo:<request>".
void gt_unary(grpc_call* call, void* user_data):
	string_builder* sb = string_new()
	string_append(sb, grpc_call_metadata(call, c":scheme"))
	string_append(sb, c" ")
	string_append(sb, grpc_call_metadata(call, c":authority"))
	if (call.conn.tls != 0):
		string_append(sb, c" tls echo:")
	else:
		string_append(sb, c" plain echo:")
	string_append_bytes(sb, call.request, call.request_len)
	grpc_call_reply(call, sb.data, sb.length)
	string_free(sb)
	char* n = itoa(call.recv_compressed)
	grpc_call_add_trailer(call, c"x-req-compressed", n)
	free(n)


# Server streaming: request "N SIZE" -> N messages of SIZE bytes, the
# k-th filled with 'a' + k % 26.
void gt_count(grpc_call* call, void* user_data):
	char* req = 0
	int len = 0
	if (grpc_call_recv(call, &req, &len) != 1):
		return
	int n = atoi(req)
	int i = 0
	while ((req[i] != ' ') && (req[i] != 0)):
		i = i + 1
	int size = atoi(req + i + 1)
	free(req)
	for k in range(n):
		char* buf = gt_fill(size, 'a' + (k % 26))
		int rc = grpc_call_send(call, buf, size)
		free(buf)
		if (rc != 0):
			return
	grpc_call_add_trailer(call, c"x-sent", c"done")


# Bidi: answers every message with "pong:<msg>" right away.
void gt_echo(grpc_call* call, void* user_data):
	int count = 0
	while (1):
		char* m = 0
		int len = 0
		if (grpc_call_recv(call, &m, &len) != 1):
			break
		string_builder* sb = string_new()
		string_append(sb, c"pong:")
		string_append_bytes(sb, m, len)
		free(m)
		int rc = grpc_call_send(call, sb.data, sb.length)
		string_free(sb)
		if (rc != 0):
			return
		count = count + 1
	char* n = itoa(count)
	grpc_call_add_trailer(call, c"x-count", n)
	char* c = itoa(call.recv_compressed)
	grpc_call_add_trailer(call, c"x-req-compressed", c)
	free(c)
	free(n)


# Ticks every 20 ms until the client goes away; counts the cancels.
void gt_ticker(grpc_call* call, void* user_data):
	char* m = 0
	int len = 0
	if (grpc_call_recv(call, &m, &len) != 1):
		return
	free(m)
	for i in range(500):
		char* t = gt_msg(c"tick ", i)
		int rc = grpc_call_send(call, t, strlen(t))
		free(t)
		if (rc != 0):
			if (call.cancelled != 0):
				gt_stops = gt_stops + 1
			return
		sleep_ms(20)


void gt_stats(grpc_call* call, void* user_data):
	char* n = itoa(gt_stops)
	grpc_call_reply(call, n, strlen(n))
	free(n)


/* Fixture plumbing */

void gt_server_child(int listener):
	int fd = socket_accept_connection(listener)
	if (fd < 0):
		exit(70)
	socket_set_recv_timeout(fd, 20000)
	socket_set_send_timeout(fd, 20000)
	grpc_server* srv = grpc_server_new()
	grpc_server_register(srv, c"/t.S/Unary", gt_unary, 0)
	grpc_server_register_stream(srv, c"/t.S/Count", gt_count, 0)
	grpc_server_register_stream(srv, c"/t.S/Echo", gt_echo, 0)
	grpc_server_register_stream(srv, c"/t.S/Ticker", gt_ticker, 0)
	grpc_server_register(srv, c"/t.S/Stats", gt_stats, 0)
	int err = grpc_server_serve_conn_tls(srv, fd, web_test_server_config())
	grpc_server_free(srv)
	exit(err)


# Server streaming "N SIZE"; asserts every message and the OK status.
void gt_check_count(grpc_channel* ch, int n, int size):
	grpc_client_stream* cs = grpc_stream_open(ch, c"/t.S/Count", 0, 0)
	char* req = gt_msg(c"", n)
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
	grpc_result* r = grpc_stream_finish(cs)
	assert_equal(grpc_status_ok(), r.status)
	assert_strings_equal(c"done", grpc_result_trailer(r, c"x-sent"))
	grpc_result_free(r)


int gt_stats_call(grpc_channel* ch):
	grpc_result* r = grpc_unary_call(ch, c"/t.S/Stats", c"", 0, 0, 0)
	assert_equal(grpc_status_ok(), r.status)
	int n = atoi(r.response)
	grpc_result_free(r)
	return n


/* End to end */

void test_grpc_tls_end_to_end():
	compress_codecs_register()
	int port = 0
	int listener = net_test_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		gt_server_child(listener)
	tls_config* cfg = web_test_client_config()
	grpc_channel* ch = grpc_channel_open_tls(c"127.0.0.1", port, 10000, c"test.w.example", cfg)
	asserts(c"grpc_channel_open_tls failed", ch != 0)
	asserts(c"channel runs over TLS", ch.conn.tls != 0)
	assert_strings_equal(c"h2", tls_alpn_selected(ch.conn.tls))
	assert_strings_equal(c"https", ch.scheme)

	# Unary.
	grpc_result* r = grpc_unary_call(ch, c"/t.S/Unary", c"hi", 2, 0, 0)
	assert_equal(grpc_status_ok(), r.status)
	char* want = gt_msg(c"https test.w.example:", port)
	string_builder* sb = string_new()
	string_append(sb, want)
	string_append(sb, c" tls echo:hi")
	assert_strings_equal(sb.data, r.response)
	string_free(sb)
	free(want)
	assert_strings_equal(c"0", grpc_result_trailer(r, c"x-req-compressed"))
	grpc_result_free(r)

	# Nothing in flight: no pending input.
	assert_equal(0, h2_conn_has_pending(ch.conn))

	# Server streaming, small then 1.2 MB.
	gt_check_count(ch, 5, 10)
	gt_check_count(ch, 40, 30000)

	# Bidi ping-pong with gzip both ways.
	assert_equal(1, grpc_channel_set_compression(ch, c"gzip"))
	grpc_client_stream* cs = grpc_stream_open(ch, c"/t.S/Echo", 0, 0)
	char* m = 0
	int len = 0
	int i = 0
	while (i < 5):
		char* ping = gt_fill(4000 + i, 'p')
		assert_equal(0, grpc_stream_send(cs, ping, 4000 + i))
		assert_equal(1, grpc_stream_recv(cs, &m, &len))
		assert_equal(4005 + i, len)
		assert_equal('g', m[3])
		assert_equal(':', m[4])
		assert_equal('p', m[5])
		assert_equal('p', m[len - 1])
		free(m)
		free(ping)
		i = i + 1
	assert_strings_equal(c"gzip", grpc_stream_header(cs, c"grpc-encoding"))
	assert_equal(0, grpc_stream_close_send(cs))
	assert_equal(0, grpc_stream_recv(cs, &m, &len))
	r = grpc_stream_finish(cs)
	assert_equal(grpc_status_ok(), r.status)
	assert_strings_equal(c"5", grpc_result_trailer(r, c"x-count"))
	assert_strings_equal(c"5", grpc_result_trailer(r, c"x-req-compressed"))
	grpc_result_free(r)
	assert_equal(1, grpc_channel_set_compression(ch, 0))

	# Cancel mid-stream: the server's next send fails and the handler
	# counts it.
	cs = grpc_stream_open(ch, c"/t.S/Ticker", 0, 0)
	assert_equal(0, grpc_stream_send(cs, c"go", 2))
	i = 0
	while (i < 3):
		assert_equal(1, grpc_stream_recv(cs, &m, &len))
		free(m)
		i = i + 1
	grpc_stream_cancel(cs)
	assert_equal(grpc_status_cancelled(), grpc_stream_status(cs))
	assert_equal(-1, grpc_stream_recv(cs, &m, &len))
	r = grpc_stream_finish(cs)
	assert_equal(grpc_status_cancelled(), r.status)
	grpc_result_free(r)
	assert_equal(1, gt_stats_call(ch))

	# TLS-buffered plaintext: plant unconsumed plaintext in the tls_conn
	# (as the tail of a record h2_conn_read did not take whole would be)
	# and check the probe sees it although the socket has nothing to
	# read -- the case grpc_pump_ready missed when it polled the fd.
	tls_conn* t = ch.conn.tls
	assert_equal(0, h2_conn_has_pending(ch.conn))
	char* saved_buf = t.app_buf
	int saved_len = t.app_len
	int saved_pos = t.app_pos
	char* fake = malloc(4)
	t.app_buf = fake
	t.app_len = 4
	t.app_pos = 1
	assert_equal(1, h2_conn_has_pending(ch.conn))
	t.app_pos = 4
	assert_equal(0, h2_conn_has_pending(ch.conn))
	t.app_buf = saved_buf
	t.app_len = saved_len
	t.app_pos = saved_pos
	free(fake)

	# The connection is still healthy.
	r = grpc_unary_call(ch, c"/t.S/Unary", c"bye", 3, 0, 0)
	assert_equal(grpc_status_ok(), r.status)
	grpc_result_free(r)

	grpc_channel_close(ch)
	tls_config_free(cfg)
	net_test_finish(pid, listener)


# A client that offers only http/1.1: the TLS handshake fails and
# grpc_server_serve_conn_tls reports PROTOCOL_ERROR.
void test_grpc_tls_server_requires_h2():
	int port = 0
	int listener = net_test_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		int sfd = socket_accept_connection(listener)
		if (sfd < 0):
			exit(80)
		socket_set_recv_timeout(sfd, 20000)
		grpc_server* srv = grpc_server_new()
		int err = grpc_server_serve_conn_tls(srv, sfd, web_test_server_config())
		grpc_server_free(srv)
		if (err != h2_error_protocol()):
			exit(81)
		exit(0)
	int fd = socket_tcp_ipv4()
	asserts(c"socket", fd >= 0)
	socket_set_recv_timeout(fd, 10000)
	asserts(c"connect", socket_connect_ipv4(fd, ip4_from_string(c"127.0.0.1"), port) >= 0)
	tls_config* cfg = web_test_client_config()
	tls_config_set_alpn(cfg, c"http/1.1")
	tls_conn* t = tls_connect(fd, c"test.w.example", cfg)
	asserts(c"handshake must fail", t == 0)
	close(fd)
	tls_config_free(cfg)
	net_test_finish(pid, listener)
