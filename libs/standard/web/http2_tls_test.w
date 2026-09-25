# wbuild: x64
# Tests for HTTP/2 over TLS ("h2", RFC 9113 section 3.2) in
# libs/standard/web/http2.w: the W client (h2_connect_tls) against the W
# server (h2_accept_tls) over a forked loopback, with the pure-W TLS 1.3
# stack (libs/standard/net/tls.w) negotiating ALPN "h2" and the checked-in
# synthetic P-256 fixture cert (libs/standard/net/tls_fixtures/). The
# fixture's SAN is test.w.example, so the client passes that as the
# server name and skips chain verification (the CertificateVerify
# signature and Finished MACs are still checked).
#
# Covers: GET/POST, concurrent streams awaited out of order, trailers, a
# 200 KB body each way (flow control over the TLS record stream), PING, a
# connection deadline that expires with no TLS record in flight and leaves
# the connection usable; plus both refusal paths -- a server that does not
# select h2 (client refuses with a clear error) and a client that does not
# offer h2 (server sends no_application_protocol).
import lib.testing
import lib.net
import lib.time
import lib.container
import structures.string
import libs.standard.net.tls
import libs.standard.web.hpack
import libs.standard.web.http2


/* Fixture plumbing */

char* h2s_cert_path():
	return c"libs/standard/net/tls_fixtures/server_p256_cert.pem"


char* h2s_key_path():
	return c"libs/standard/net/tls_fixtures/server_p256_key.pem"


int h2s_listen(int* out_port):
	int listener = socket_tcp_ipv4()
	asserts(c"socket", listener >= 0)
	socket_set_reuseaddr(listener)
	asserts(c"bind", socket_bind_ipv4(listener, ip4_from_string(c"127.0.0.1"), 0) >= 0)
	asserts(c"listen", socket_listen(listener, 8) >= 0)
	sockaddr_in bound
	socket_getsockname_ipv4(listener, &bound)
	*out_port = net_htons(bound.port)
	return listener


char* h2s_authority(int port):
	string_builder* sb = string_new()
	string_append(sb, c"test.w.example:")
	string_append_int(sb, port)
	char* out = sb.data
	free(sb)
	return out


void h2s_finish(int pid, int listener):
	int status = 0
	wait4(pid, &status, 0, 0)
	close(listener)
	if (status != 0):
		print2(c"fixture child status: ")
		println2(itoa(status))
	assert_equal(0, status)


tls_server_config* h2s_server_config():
	tls_server_config* scfg = tls_server_config_new()
	scfg.cert_chain_path = h2s_cert_path()
	scfg.key_path = h2s_key_path()
	return scfg


tls_config* h2s_client_config():
	tls_config* cfg = tls_config_new()
	cfg.insecure_skip_verify = 1
	return cfg


/* The W h2 server over TLS against the W client */

void h2s_server_child(int listener):
	int fd = socket_accept_connection(listener)
	if (fd < 0):
		exit(80)
	socket_set_recv_timeout(fd, 20000)
	socket_set_send_timeout(fd, 20000)
	h2_conn* c = h2_accept_tls(fd, h2s_server_config())
	if (c == 0):
		exit(81)
	if (c.tls == 0):
		exit(82)
	while (1):
		h2_stream* s = h2_server_next_request(c)
		if (s == 0):
			break
		char* method = h2_stream_header(s, c":method")
		char* path = h2_stream_header(s, c":path")
		list[hpack_header*] extra = hpack_headers_new()
		hpack_headers_add(extra, c"X-Transport", c"h2")
		if (strcmp(path, c"/trailers") == 0):
			h2_respond_headers(c, s, 200, extra, 0)
			h2_send_data(c, s, c"partial", 7, 0)
			list[hpack_header*] t = hpack_headers_new()
			hpack_headers_add(t, c"x-checksum", c"42")
			h2_send_trailers(c, s, t)
			hpack_headers_free(t)
		else if (strcmp(path, c"/big") == 0):
			h2_respond(c, s, 200, extra, h2_stream_body(s), h2_stream_body_len(s))
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


void test_h2_tls_client_and_server():
	int port = 0
	int listener = h2s_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		h2s_server_child(listener)
	char* auth = h2s_authority(port)
	tls_config* cfg = h2s_client_config()
	h2_conn* c = h2_connect_tls(c"127.0.0.1", port, 10000, c"test.w.example", cfg)
	asserts(c"h2_connect_tls failed", c != 0)
	asserts(c"connection runs over TLS", c.tls != 0)
	assert_strings_equal(c"h2", tls_alpn_selected(c.tls))

	# Plain GET and a POST with a body.
	h2_stream* s = h2_request(c, c"GET", c"https", auth, c"/hello", 0, 0, 0)
	asserts(c"GET failed", h2_stream_ok(s))
	assert_equal(200, h2_stream_status(s))
	assert_strings_equal(c"GET /hello ", h2_stream_body(s))
	assert_strings_equal(c"h2", h2_stream_header(s, c"x-transport"))
	h2_stream_free(c, s)
	s = h2_request(c, c"POST", c"https", auth, c"/echo", 0, c"payload", 7)
	asserts(c"POST failed", h2_stream_ok(s))
	assert_strings_equal(c"POST /echo payload", h2_stream_body(s))
	h2_stream_free(c, s)

	# Concurrent streams, awaited in reverse order.
	h2_stream* a = h2_request_start(c, c"POST", c"https", auth, c"/a", 0, 0)
	h2_stream* b = h2_request_start(c, c"GET", c"https", auth, c"/b", 0, 1)
	assert_equal(0, h2_send_data(c, a, c"ay", 2, 1))
	assert_equal(0, h2_await_end(c, b))
	assert_equal(0, h2_await_end(c, a))
	assert_strings_equal(c"GET /b ", h2_stream_body(b))
	assert_strings_equal(c"POST /a ay", h2_stream_body(a))
	h2_stream_free(c, a)
	h2_stream_free(c, b)

	# Trailers.
	s = h2_request(c, c"GET", c"https", auth, c"/trailers", 0, 0, 0)
	asserts(c"trailers failed", h2_stream_ok(s))
	assert_strings_equal(c"partial", h2_stream_body(s))
	assert_strings_equal(c"42", h2_stream_trailer(s, c"x-checksum"))
	h2_stream_free(c, s)

	# 200 KB each way: many TLS records and several flow-control windows.
	int big = 204800
	char* body = malloc(big)
	int i = 0
	while (i < big):
		body[i] = 'a' + (i % 26)
		i = i + 1
	s = h2_request(c, c"PUT", c"https", auth, c"/big", 0, body, big)
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

	# A deadline with nothing in flight expires (-2) without breaking the
	# TLS stream; the connection keeps working afterwards.
	h2_set_deadline(c, time_monotonic_ms() + 150)
	assert_equal(0 - 2, h2_pump(c))
	h2_set_deadline(c, 0)
	assert_equal(0, c.dead)
	assert_equal(0, h2_ping(c))
	s = h2_request(c, c"GET", c"https", auth, c"/after-deadline", 0, 0, 0)
	asserts(c"request after deadline failed", h2_stream_ok(s))
	assert_strings_equal(c"GET /after-deadline ", h2_stream_body(s))
	h2_stream_free(c, s)

	assert_equal(0, c.error)
	h2_close(c)
	tls_config_free(cfg)
	h2s_finish(pid, listener)


/* Refusals */

# The server's ALPN list lacks h2 (optional, so its handshake completes
# without ALPN); the h2 client must refuse the session before sending
# the preface. The child then sees close_notify (clean EOF).
void test_h2_tls_client_refuses_server_without_h2():
	int port = 0
	int listener = h2s_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		int fd = socket_accept_connection(listener)
		if (fd < 0):
			exit(80)
		socket_set_recv_timeout(fd, 20000)
		tls_server_config* scfg = h2s_server_config()
		tls_server_config_set_alpn(scfg, c"http/1.1", 0)
		tls_conn* t = tls_accept(fd, scfg)
		if (t == 0):
			exit(81)
		if (tls_alpn_selected(t) != 0):
			exit(82)
		char* buf = malloc(64)
		if (tls_read(t, buf, 64) != 0):
			exit(83)
		tls_close(t)
		close(fd)
		exit(0)
	tls_config* cfg = h2s_client_config()
	h2_conn* c = h2_connect_tls(c"127.0.0.1", port, 10000, c"test.w.example", cfg)
	asserts(c"client must refuse a non-h2 session", c == 0)
	assert_strings_equal(c"http2: server did not negotiate h2 via ALPN", tls_last_error(cfg))
	tls_config_free(cfg)
	h2s_finish(pid, listener)


# A client that offers only http/1.1 gets no_application_protocol from
# h2_accept_tls, which returns 0.
void test_h2_tls_server_requires_h2():
	int port = 0
	int listener = h2s_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		int fd = socket_accept_connection(listener)
		if (fd < 0):
			exit(80)
		socket_set_recv_timeout(fd, 20000)
		tls_server_config* scfg = h2s_server_config()
		h2_conn* c = h2_accept_tls(fd, scfg)
		if (c != 0):
			exit(81)
		if (strcmp(tls_server_last_error(scfg), c"tls: no common ALPN protocol") != 0):
			exit(82)
		exit(0)
	int fd = socket_tcp_ipv4()
	asserts(c"socket", fd >= 0)
	socket_set_recv_timeout(fd, 10000)
	asserts(c"connect", socket_connect_ipv4(fd, ip4_from_string(c"127.0.0.1"), port) >= 0)
	tls_config* cfg = h2s_client_config()
	tls_config_set_alpn(cfg, c"http/1.1")
	tls_conn* t = tls_connect(fd, c"test.w.example", cfg)
	asserts(c"handshake must fail", t == 0)
	close(fd)
	tls_config_free(cfg)
	h2s_finish(pid, listener)
